//
//  IB3DeviceSpoof_v12.m
//  无尽之剑3 全屏 Tweak（底层 OpenGL 渲染版）
//
//  三层打击：
//  1. UIScreen 欺骗（上层 API）
//  2. CAEAGLLayer 尺寸欺骗（渲染层大小）
//  3. glViewport / glScissor 欺骗（渲染视口）
//  4. EAGLContext renderbufferStorage（最终分辨率）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "fishhook.h"
#import <objc/runtime.h>

// ========== 配置：iPhone 13 Pro ==========

#define SPOOFED_DEVICE_MODEL "iPhone14,2"
#define SPOOFED_WIDTH_PT    393.0
#define SPOOFED_HEIGHT_PT   852.0
#define SPOOFED_SCALE       3.0

#define CONSTRUCTOR_PRIORITY 101

// ==========================

// ---- C 函数原始指针 ----
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_uname)(struct utsname *);

// OpenGL 原始函数
static void (*orig_glViewport)(GLint x, GLint y, GLsizei width, GLsizei height);
static void (*orig_glScissor)(GLint x, GLint y, GLsizei width, GLsizei height);
static void (*orig_glRenderbufferStorage)(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);

// ---- ObjC 原始 IMP ----
static IMP orig_uid_model = NULL;
static IMP orig_screen_bounds = NULL;
static IMP orig_screen_nativeBounds = NULL;
static IMP orig_screen_scale = NULL;
static IMP orig_screen_nativeScale = NULL;
static IMP orig_screenMode_size = NULL;

// CAEAGLLayer
static IMP orig_eagllayer_bounds = NULL;
static IMP orig_eagllayer_drawableProperties = NULL;

// EAGLContext
static IMP orig_eaglctx_renderbufferStorage = NULL;

// ---- 统计 ----
static int g_viewport_calls = 0;
static int g_renderbuffer_calls = 0;
static int g_last_vp_w = 0;
static int g_last_vp_h = 0;
static int g_last_rb_w = 0;
static int g_last_rb_h = 0;

// ========== 工具：方向感知尺寸 ==========

static CGSize spoofed_pt_size() {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return CGSizeMake(SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT);
    UIInterfaceOrientation o = app.statusBarOrientation;
    if (UIInterfaceOrientationIsLandscape(o)) {
        return CGSizeMake(SPOOFED_HEIGHT_PT, SPOOFED_WIDTH_PT);
    }
    return CGSizeMake(SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT);
}

static CGSize spoofed_px_size() {
    CGSize pt = spoofed_pt_size();
    return CGSizeMake(pt.width * SPOOFED_SCALE, pt.height * SPOOFED_SCALE);
}

// ========== sysctlbyname / sysctl / uname ==========

int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (!name) return ret;
    if (strcmp(name, "hw.machine") == 0 ||
        strcmp(name, "hw.model") == 0 ||
        strcmp(name, "hw.target") == 0) {
        if (oldp && oldlenp) {
            size_t n = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= n) { strlcpy((char*)oldp, SPOOFED_DEVICE_MODEL, *oldlenp); *oldlenp = n; ret = 0; }
        } else if (oldlenp) { *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1; ret = 0; }
    }
    return ret;
}

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (namelen >= 2 && name[0] == CTL_HW && (name[1] == HW_MACHINE || name[1] == 2)) {
        if (oldp && oldlenp) {
            size_t n = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= n) { strlcpy((char*)oldp, SPOOFED_DEVICE_MODEL, *oldlenp); *oldlenp = n; ret = 0; }
        } else if (oldlenp) { *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1; ret = 0; }
    }
    return ret;
}

int replaced_uname(struct utsname *name) {
    int ret = orig_uname(name);
    if (ret == 0 && name) strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
    return ret;
}

// ========== UIDevice model ==========

id replaced_uid_model(id self, SEL _cmd) {
    return [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
}

// ========== UIScreen 系列 ==========

CGRect replaced_screen_bounds(id self, SEL _cmd) {
    CGRect (*f)(id, SEL) = (void*)orig_screen_bounds;
    if (f) (void)f(self, _cmd);
    CGSize s = spoofed_pt_size();
    return CGRectMake(0, 0, s.width, s.height);
}

CGRect replaced_screen_nativeBounds(id self, SEL _cmd) {
    CGRect (*f)(id, SEL) = (void*)orig_screen_nativeBounds;
    if (f) (void)f(self, _cmd);
    CGSize s = spoofed_px_size();
    return CGRectMake(0, 0, s.width, s.height);
}

CGFloat replaced_screen_scale(id self, SEL _cmd) {
    return SPOOFED_SCALE;
}

CGFloat replaced_screen_nativeScale(id self, SEL _cmd) {
    return SPOOFED_SCALE;
}

CGSize replaced_screenMode_size(id self, SEL _cmd) {
    CGSize (*f)(id, SEL) = (void*)orig_screenMode_size;
    if (f) (void)f(self, _cmd);
    return spoofed_px_size();
}

// ========== CAEAGLLayer bounds ==========
// 关键：layer 的 bounds 决定了 renderbuffer 的像素大小

CGRect replaced_eagllayer_bounds(id self, SEL _cmd) {
    CGRect (*f)(id, SEL) = (void*)orig_eagllayer_bounds;
    if (!f) return CGRectZero;
    CGRect real = f(self, _cmd);
    
    // 返回欺骗的尺寸（点坐标）
    CGSize s = spoofed_pt_size();
    return CGRectMake(0, 0, s.width, s.height);
}

// ========== CAEAGLLayer drawableProperties ==========
// 也可以通过 drawableProperties 控制大小，但主要靠 bounds

NSDictionary *replaced_drawableProperties(id self, SEL _cmd) {
    NSDictionary *(*f)(id, SEL) = (void*)orig_eagllayer_drawableProperties;
    NSDictionary *real = f ? f(self, _cmd) : nil;
    return real; // 暂时不改这个，先靠 bounds
}

// ========== EAGLContext renderbufferStorage:fromDrawable: ==========
// 最关键的函数：从 layer 创建 renderbuffer，决定最终分辨率

BOOL replaced_renderbufferStorage(id self, SEL _cmd, GLenum target, id drawable) {
    BOOL (*f)(id, SEL, GLenum, id) = (void*)orig_eaglctx_renderbufferStorage;
    
    // 先调用原始方法
    BOOL result = f ? f(self, _cmd, target, drawable) : NO;
    
    // 记录调用
    g_renderbuffer_calls++;
    
    // 调用完后，我们再手动重新设置 renderbuffer storage 为更大的尺寸
    // 等等，这样做不对——renderbufferStorage 是从 drawable (CAEAGLLayer) 创建的
    // 如果 layer 的 bounds 已经被我们欺骗了，这里创建的就是大尺寸
    // 所以关键还是 CAEAGLLayer 的 bounds
    
    return result;
}

// ========== glViewport ==========

void replaced_glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    g_viewport_calls++;
    g_last_vp_w = width;
    g_last_vp_h = height;
    
    // 获取目标像素尺寸
    CGSize px = spoofed_px_size();
    
    // 如果传入的尺寸比目标小，就替换成目标尺寸
    if (width > 0 && height > 0 && width < px.width && height < px.height) {
        // 判断方向
        if (width > height) {
            // 横屏
            GLsizei new_w = (GLsizei)px.width;
            GLsizei new_h = (GLsizei)px.height;
            orig_glViewport(x, y, new_w, new_h);
            return;
        } else {
            // 竖屏
            GLsizei new_w = (GLsizei)px.height;
            GLsizei new_h = (GLsizei)px.width;
            // 不对，竖屏应该 width < height，所以直接用 px 的竖屏
            // 但 px 已经根据方向调整了吗？spoofed_px_size 是根据方向的
            // 这里直接用 px 的值
            orig_glViewport(x, y, (GLsizei)px.width, (GLsizei)px.height);
            return;
        }
    }
    
    // 否则原样调用
    orig_glViewport(x, y, width, height);
}

// ========== glScissor ==========

void replaced_glScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    CGSize px = spoofed_px_size();
    
    if (width > 0 && height > 0 && width < px.width && height < px.height) {
        orig_glScissor(x, y, (GLsizei)px.width, (GLsizei)px.height);
        return;
    }
    
    orig_glScissor(x, y, width, height);
}

// ========== glRenderbufferStorage ==========

void replaced_glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) {
    g_renderbuffer_calls++;
    g_last_rb_w = width;
    g_last_rb_h = height;
    
    CGSize px = spoofed_px_size();
    
    // 如果创建的 renderbuffer 比目标小，就用大的
    if (width > 0 && height > 0 && width < px.width && height < px.height) {
        orig_glRenderbufferStorage(target, internalformat, (GLsizei)px.width, (GLsizei)px.height);
        return;
    }
    
    orig_glRenderbufferStorage(target, internalformat, width, height);
}

// ========== 诊断弹窗 ==========

static void showDiagnostic() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *s = [UIScreen mainScreen];
        CGRect b = s.bounds;
        CGRect nb = CGRectZero;
        if ([s respondsToSelector:@selector(nativeBounds)]) nb = s.nativeBounds;
        CGSize ms = s.currentMode.size;
        
        char machine[256];
        size_t len = sizeof(machine);
        sysctlbyname("hw.machine", machine, &len, NULL, 0);
        
        NSString *msg = [NSString stringWithFormat:
            @"IB3DeviceSpoof v12\n"
            @"（底层 OpenGL 渲染版）\n\n"
            @"设备: %s\n"
            @"hw.machine: %s\n\n"
            @"UIScreen bounds: %.0f x %.0f\n"
            @"nativeBounds: %.0f x %.0f\n"
            @"currentMode: %.0f x %.0f\n\n"
            @"glViewport 调用: %d 次\n"
            @"  最后一次: %d x %d\n\n"
            @"glRenderbufferStorage: %d 次\n"
            @"  最后一次: %d x %d\n\n"
            @"目标尺寸: %.0f x %.0f pt (%.0fx)",
            SPOOFED_DEVICE_MODEL, machine,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            ms.width, ms.height,
            g_viewport_calls, g_last_vp_w, g_last_vp_h,
            g_renderbuffer_calls, g_last_rb_w, g_last_rb_h,
            SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT, SPOOFED_SCALE];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tweak v12"
                             message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"复制"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = msg;
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if (!win) win = [[UIApplication sharedApplication].windows firstObject];
        UIViewController *vc = win.rootViewController;
        if (vc) [vc presentViewController:alert animated:YES completion:nil];
    });
}

// ========== 初始化 ==========

__attribute__((constructor(CONSTRUCTOR_PRIORITY)))
static void ib3_spoof_init() {
    // ---- C 函数 hook ----
    struct rebinding rebindings[] = {
        { "sysctlbyname", replaced_sysctlbyname, (void **)&orig_sysctlbyname },
        { "sysctl", replaced_sysctl, (void **)&orig_sysctl },
        { "uname", replaced_uname, (void **)&orig_uname },
        { "glViewport", replaced_glViewport, (void **)&orig_glViewport },
        { "glScissor", replaced_glScissor, (void **)&orig_glScissor },
        { "glRenderbufferStorage", replaced_glRenderbufferStorage, (void **)&orig_glRenderbufferStorage },
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(rebindings[0]));
    
    fprintf(stderr, "[IB3 v12] C hooks ready (including OpenGL)\n");
    
    // ---- ObjC swizzle ----
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            int ok = 0, total = 0;
            
            // UIDevice
            total++;
            Class c = objc_getClass("UIDevice");
            if (c) {
                Method m = class_getInstanceMethod(c, @selector(model));
                if (m) { orig_uid_model = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_uid_model); ok++; }
            }
            
            // UIScreen
            Class sc = objc_getClass("UIScreen");
            
            total++;
            if (sc) {
                Method m = class_getInstanceMethod(sc, @selector(bounds));
                if (m) { orig_screen_bounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_bounds); ok++; }
            }
            
            total++;
            if (sc && [sc instancesRespondToSelector:@selector(nativeBounds)]) {
                Method m = class_getInstanceMethod(sc, @selector(nativeBounds));
                if (m) { orig_screen_nativeBounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_nativeBounds); ok++; }
            }
            
            total++;
            if (sc) {
                Method m = class_getInstanceMethod(sc, @selector(scale));
                if (m) { orig_screen_scale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_scale); ok++; }
            }
            
            total++;
            if (sc && [sc instancesRespondToSelector:@selector(nativeScale)]) {
                Method m = class_getInstanceMethod(sc, @selector(nativeScale));
                if (m) { orig_screen_nativeScale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_nativeScale); ok++; }
            }
            
            // UIScreenMode
            total++;
            Class smc = objc_getClass("UIScreenMode");
            if (smc) {
                Method m = class_getInstanceMethod(smc, @selector(size));
                if (m) { orig_screenMode_size = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screenMode_size); ok++; }
            }
            
            // CAEAGLLayer bounds
            total++;
            Class eagl = objc_getClass("CAEAGLLayer");
            if (eagl) {
                Method m = class_getInstanceMethod(eagl, @selector(bounds));
                if (m) { orig_eagllayer_bounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_eagllayer_bounds); ok++; }
            }
            
            // EAGLContext renderbufferStorage:fromDrawable:
            total++;
            Class ectx = objc_getClass("EAGLContext");
            if (ectx) {
                SEL rsSel = @selector(renderbufferStorage:fromDrawable:);
                Method m = class_getInstanceMethod(ectx, rsSel);
                if (m) { orig_eaglctx_renderbufferStorage = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_renderbufferStorage); ok++; }
            }
            
            NSLog(@"[IB3 v12] ObjC swizzle: %d/%d OK", ok, total);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnostic();
            });
        }
    });
}
