//
//  IB3DeviceSpoof_v15.m
//  核心方案：Hook renderbufferStorage:fromDrawable: 扩大最终帧缓冲
//
//  思路：
//  - 保持 UIScreen + 设备型号欺骗（已验证有效）
//  - 在 constructor 阶段就 swizzle EAGLContext（更早）
//  - 当引擎调用 renderbufferStorage:fromDrawable: 时，
//    先修改 CAEAGLLayer 的 bounds/contentsScale，
//    让创建出来的 renderbuffer 就是全屏尺寸
//  - 同时 hook glViewport 确保视口匹配
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
#define MAX_LOG 40

// ==========================

typedef struct {
    char func[48];
    int w, h;
} CallLog;

static CallLog g_log[MAX_LOG];
static int g_log_count = 0;

static void add_log(const char *func, int w, int h) {
    if (g_log_count < MAX_LOG) {
        strncpy(g_log[g_log_count].func, func, 47);
        g_log[g_log_count].w = w;
        g_log[g_log_count].h = h;
        g_log_count++;
    }
}

// ---- C 函数原始指针 ----
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_uname)(struct utsname *);
static void (*orig_glViewport)(GLint x, GLint y, GLsizei width, GLsizei height);

// ---- ObjC 原始 IMP ----
static IMP orig_uid_model = NULL;
static IMP orig_screen_bounds = NULL;
static IMP orig_screen_nativeBounds = NULL;
static IMP orig_screen_scale = NULL;
static IMP orig_screen_nativeScale = NULL;
static IMP orig_screenMode_size = NULL;
static IMP orig_eagl_renderbufferStorage = NULL;

// ---- 状态 ----
static int g_renderbuffer_count = 0;
static int g_renderbuffer_w = 0;
static int g_renderbuffer_h = 0;

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

// ========== 核心：EAGLContext renderbufferStorage:fromDrawable: ==========
// 这是 iOS OpenGL ES 渲染的最终关口

BOOL replaced_eagl_renderbufferStorage(id self, SEL _cmd, GLenum target, id drawable) {
    BOOL (*orig)(id, SEL, GLenum, id) = (void*)orig_eagl_renderbufferStorage;
    
    g_renderbuffer_count++;
    
    // 记录原始 layer 信息
    CGSize originalBounds = CGSizeZero;
    CGFloat originalScale = 1.0;
    
    if ([drawable isKindOfClass:[CAEAGLLayer class]]) {
        CAEAGLLayer *layer = (CAEAGLLayer *)drawable;
        originalBounds = layer.bounds.size;
        originalScale = layer.contentsScale;
        
        add_log("renderbufferStorage_in", (int)originalBounds.width, (int)originalBounds.height);
        
        // ===== 关键：修改 layer 的尺寸和 scale =====
        CGSize targetPt = spoofed_pt_size();
        layer.bounds = CGRectMake(0, 0, targetPt.width, targetPt.height);
        layer.contentsScale = SPOOFED_SCALE;
        
        add_log("renderbufferStorage_modified", (int)targetPt.width, (int)targetPt.height);
    }
    
    // 调用原始方法（此时 layer 已经是大尺寸了）
    BOOL result = orig ? orig(self, _cmd, target, drawable) : NO;
    
    // 记录结果
    if (result) {
        GLint width = 0, height = 0;
        glGetRenderbufferParameteriv(target, GL_RENDERBUFFER_WIDTH, &width);
        glGetRenderbufferParameteriv(target, GL_RENDERBUFFER_HEIGHT, &height);
        g_renderbuffer_w = width;
        g_renderbuffer_h = height;
        add_log("renderbufferStorage_out", width, height);
    }
    
    return result;
}

// ========== glViewport（确保视口跟大缓冲匹配）==========

void replaced_glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    add_log("glViewport", width, height);
    
    CGSize px = spoofed_px_size();
    
    // 如果是全屏级别的 viewport，但比目标小，就替换成目标尺寸
    if (width > 500 && height > 300 && width < px.width * 0.95) {
        orig_glViewport(x, y, (GLsizei)px.width, (GLsizei)px.height);
        return;
    }
    
    orig_glViewport(x, y, width, height);
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
        int show = g_log_count > 20 ? 20 : g_log_count;
        for (int i = 0; i < show; i++) {
            [logStr appendFormat:@"  %2d. %s: %d x %d\n",
                i+1, g_log[i].func, g_log[i].w, g_log[i].h];
        }
        if (g_log_count > 20) {
            [logStr appendFormat:@"  ... (共 %d 次)", g_log_count];
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"IB3DeviceSpoof v15\n"
            @"（renderbufferStorage 核心版）\n\n"
            @"设备: %s\n"
            @"hw.machine: %s\n\n"
            @"UIScreen bounds: %.0f x %.0f\n"
            @"nativeBounds: %.0f x %.0f\n\n"
            @"renderbufferStorage 调用: %d 次\n"
            @"  最终尺寸: %d x %d\n\n"
            @"调用记录 (前%d次):\n%@\n"
            @"目标: %.0f x %.0f pt (%.0fx)",
            SPOOFED_DEVICE_MODEL, machine,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            g_renderbuffer_count, g_renderbuffer_w, g_renderbuffer_h,
            show, logStr,
            SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT, SPOOFED_SCALE];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tweak v15"
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
        
        // 用高窗口级别确保显示
        UIWindow *aw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        aw.windowLevel = UIWindowLevelAlert + 1000;
        aw.rootViewController = [UIViewController new];
        aw.hidden = NO;
        [aw.rootViewController presentViewController:alert animated:YES completion:nil];
        objc_setAssociatedObject(alert, "alertWindow", aw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

// ========== 初始化 ==========

__attribute__((constructor(CONSTRUCTOR_PRIORITY)))
static void ib3_spoof_init() {
    // ===== 第一步：C 函数 hook（立即生效）=====
    struct rebinding rebindings[] = {
        { "sysctlbyname", replaced_sysctlbyname, (void **)&orig_sysctlbyname },
        { "sysctl", replaced_sysctl, (void **)&orig_sysctl },
        { "uname", replaced_uname, (void **)&orig_uname },
        { "glViewport", replaced_glViewport, (void **)&orig_glViewport },
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(rebindings[0]));
    
    // ===== 第二步：EAGLContext swizzle（constructor 阶段就做，越早越好）=====
    // EAGLContext 来自 OpenGLES framework，类对象在 constructor 阶段应该已经可用
    Class eaglCtxClass = objc_getClass("EAGLContext");
    if (eaglCtxClass) {
        SEL rsSel = @selector(renderbufferStorage:fromDrawable:);
        Method m = class_getInstanceMethod(eaglCtxClass, rsSel);
        if (m) {
            orig_eagl_renderbufferStorage = method_getImplementation(m);
            method_setImplementation(m, (IMP)replaced_eagl_renderbufferStorage);
            fprintf(stderr, "[IB3 v15] EAGLContext renderbufferStorage swizzled in constructor\n");
        } else {
            fprintf(stderr, "[IB3 v15] WARNING: EAGLContext renderbufferStorage method not found\n");
        }
    } else {
        fprintf(stderr, "[IB3 v15] WARNING: EAGLContext class not found in constructor\n");
    }
    
    fprintf(stderr, "[IB3 v15] Constructor init done\n");
    
    // ===== 第三步：UIScreen / UIDevice swizzle（主队列做，安全）=====
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
            
            // 再次确保 EAGLContext 被 swizzle（万一 constructor 阶段类还没加载）
            if (!orig_eagl_renderbufferStorage) {
                total++;
                Class eagl = objc_getClass("EAGLContext");
                if (eagl) {
                    SEL rsSel = @selector(renderbufferStorage:fromDrawable:);
                    Method m = class_getInstanceMethod(eagl, rsSel);
                    if (m) { orig_eagl_renderbufferStorage = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_eagl_renderbufferStorage); ok++; }
                }
            }
            
            NSLog(@"[IB3 v15] ObjC swizzle: %d/%d OK", ok, total);
            
            // 2 秒后弹窗
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnostic();
            });
        }
    });
}
