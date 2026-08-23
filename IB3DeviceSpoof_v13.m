//
//  IB3DeviceSpoof_v13.m
//  诊断增强版：记录所有关键调用，找出 UE3 从哪里拿的分辨率
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

// ========== 配置 ==========

#define SPOOFED_DEVICE_MODEL "iPhone14,2"
#define SPOOFED_WIDTH_PT    393.0
#define SPOOFED_HEIGHT_PT   852.0
#define SPOOFED_SCALE       3.0

#define CONSTRUCTOR_PRIORITY 101
#define MAX_LOG 100

// ==========================

// ---- 日志记录 ----
typedef struct {
    char func[64];
    int w, h;
} GLCallLog;

static GLCallLog g_gl_log[MAX_LOG];
static int g_gl_log_count = 0;

static void add_gl_log(const char *func, int w, int h) {
    if (g_gl_log_count < MAX_LOG) {
        strncpy(g_gl_log[g_gl_log_count].func, func, 63);
        g_gl_log[g_gl_log_count].w = w;
        g_gl_log[g_gl_log_count].h = h;
        g_gl_log_count++;
    }
}

// ---- C 函数原始指针 ----
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_uname)(struct utsname *);

static void (*orig_glViewport)(GLint x, GLint y, GLsizei width, GLsizei height);
static void (*orig_glScissor)(GLint x, GLint y, GLsizei width, GLsizei height);
static void (*orig_glRenderbufferStorage)(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);
static void (*orig_glBindRenderbuffer)(GLenum target, GLuint renderbuffer);
static void (*orig_glFramebufferRenderbuffer)(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);

// ---- ObjC 原始 IMP ----
static IMP orig_uid_model = NULL;
static IMP orig_screen_bounds = NULL;
static IMP orig_screen_nativeBounds = NULL;
static IMP orig_screen_scale = NULL;
static IMP orig_screen_nativeScale = NULL;
static IMP orig_screenMode_size = NULL;
static IMP orig_eagllayer_bounds = NULL;
static IMP orig_eagllayer_setBounds = NULL;
static IMP orig_eaglctx_renderbufferStorage = NULL;
static IMP orig_eaglview_layoutSubviews = NULL;

// ========== 工具 ==========

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

// ========== CAEAGLLayer bounds (getter) ==========

CGRect replaced_eagllayer_bounds(id self, SEL _cmd) {
    CGRect (*f)(id, SEL) = (void*)orig_eagllayer_bounds;
    if (!f) return CGRectZero;
    CGRect real = f(self, _cmd);
    
    add_gl_log("CAEAGLLayer.bounds(get)", (int)real.size.width, (int)real.size.height);
    
    // 返回欺骗的尺寸
    CGSize s = spoofed_pt_size();
    return CGRectMake(0, 0, s.width, s.height);
}

// ========== CAEAGLLayer setBounds ==========

void replaced_eagllayer_setBounds(id self, SEL _cmd, CGRect bounds) {
    void (*f)(id, SEL, CGRect) = (void*)orig_eagllayer_setBounds;
    
    add_gl_log("CAEAGLLayer.setBounds", (int)bounds.size.width, (int)bounds.size.height);
    
    if (f) {
        CGSize s = spoofed_pt_size();
        f(self, _cmd, CGRectMake(0, 0, s.width, s.height));
    }
}

// ========== EAGLContext renderbufferStorage:fromDrawable: ==========

BOOL replaced_renderbufferStorage(id self, SEL _cmd, GLenum target, id drawable) {
    BOOL (*f)(id, SEL, GLenum, id) = (void*)orig_eaglctx_renderbufferStorage;
    
    add_gl_log("renderbufferStorage.fromDrawable", 0, 0);
    
    // 先修改 drawable 的 bounds
    if ([drawable isKindOfClass:[CALayer class]]) {
        CALayer *layer = (CALayer *)drawable;
        CGSize s = spoofed_pt_size();
        layer.bounds = CGRectMake(0, 0, s.width, s.height);
        add_gl_log("layer.bounds_set", (int)s.width, (int)s.height);
    }
    
    BOOL result = f ? f(self, _cmd, target, drawable) : NO;
    return result;
}

// ========== glViewport（记录 + 替换）==========

void replaced_glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    add_gl_log("glViewport", width, height);
    
    CGSize px = spoofed_px_size();
    
    // 只替换比目标小的 viewport
    // 并且不是那种特别小的（UI 元素之类的）
    if (width > 200 && height > 200 && width < px.width * 0.9) {
        orig_glViewport(x, y, (GLsizei)px.width, (GLsizei)px.height);
        return;
    }
    
    orig_glViewport(x, y, width, height);
}

// ========== glScissor ==========

void replaced_glScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    CGSize px = spoofed_px_size();
    
    if (width > 200 && height > 200 && width < px.width * 0.9) {
        orig_glScissor(x, y, (GLsizei)px.width, (GLsizei)px.height);
        return;
    }
    
    orig_glScissor(x, y, width, height);
}

// ========== glRenderbufferStorage ==========

void replaced_glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) {
    add_gl_log("glRenderbufferStorage", width, height);
    
    CGSize px = spoofed_px_size();
    
    if (width > 200 && height > 200 && width < px.width * 0.9) {
        orig_glRenderbufferStorage(target, internalformat, (GLsizei)px.width, (GLsizei)px.height);
        return;
    }
    
    orig_glRenderbufferStorage(target, internalformat, width, height);
}

// ========== glBindRenderbuffer（记录）==========

void replaced_glBindRenderbuffer(GLenum target, GLuint renderbuffer) {
    // 只记录，不修改
    orig_glBindRenderbuffer(target, renderbuffer);
}

// ========== 诊断弹窗 ==========

static void showDiagnostic() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *s = [UIScreen mainScreen];
        CGRect b = s.bounds;
        CGRect nb = CGRectZero;
        if ([s respondsToSelector:@selector(nativeBounds)]) nb = s.nativeBounds;
        
        char machine[256];
        size_t len = sizeof(machine);
        sysctlbyname("hw.machine", machine, &len, NULL, 0);
        
        NSMutableString *logStr = [NSMutableString string];
        int showCount = g_gl_log_count > 15 ? 15 : g_gl_log_count;
        for (int i = 0; i < showCount; i++) {
            [logStr appendFormat:@"  %d. %s: %d x %d\n",
                i+1, g_gl_log[i].func, g_gl_log[i].w, g_gl_log[i].h];
        }
        if (g_gl_log_count > 15) {
            [logStr appendFormat:@"  ... (共 %d 次)", g_gl_log_count];
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"IB3DeviceSpoof v13 诊断\n"
            @"（画面偏移版详细日志）\n\n"
            @"设备: %s\n"
            @"hw.machine: %s\n\n"
            @"UIScreen bounds: %.0f x %.0f\n"
            @"nativeBounds: %.0f x %.0f\n\n"
            @"GL/渲染调用记录 (前%d次/共%d次):\n%@\n"
            @"目标: %.0f x %.0f pt (%.0fx scale)",
            SPOOFED_DEVICE_MODEL, machine,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            showCount, g_gl_log_count, logStr,
            SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT, SPOOFED_SCALE];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tweak v13"
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
    
    fprintf(stderr, "[IB3 v13] C hooks ready\n");
    
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
            
            // CAEAGLLayer bounds getter
            total++;
            Class eagl = objc_getClass("CAEAGLLayer");
            if (eagl) {
                Method m = class_getInstanceMethod(eagl, @selector(bounds));
                if (m) { orig_eagllayer_bounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_eagllayer_bounds); ok++; }
            }
            
            // CAEAGLLayer setBounds
            total++;
            if (eagl) {
                Method m = class_getInstanceMethod(eagl, @selector(setBounds:));
                if (m) { orig_eagllayer_setBounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_eagllayer_setBounds); ok++; }
            }
            
            // EAGLContext renderbufferStorage:fromDrawable:
            total++;
            Class ectx = objc_getClass("EAGLContext");
            if (ectx) {
                SEL rsSel = @selector(renderbufferStorage:fromDrawable:);
                Method m = class_getInstanceMethod(ectx, rsSel);
                if (m) { orig_eaglctx_renderbufferStorage = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_renderbufferStorage); ok++; }
            }
            
            NSLog(@"[IB3 v13] ObjC swizzle: %d/%d OK", ok, total);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnostic();
            });
        }
    });
}
