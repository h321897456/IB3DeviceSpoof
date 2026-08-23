//
//  IB3DeviceSpoof_v14.m
//  纯诊断版：只记录，不修改任何渲染参数
//
//  目的：搞清楚 UE3 初始化渲染时的完整调用链
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
#define MAX_LOG 60

// ==========================

typedef struct {
    char func[48];
    int w, h;
    int x, y;
} CallLog;

static CallLog g_log[MAX_LOG];
static int g_log_count = 0;
static int g_log_lock = 0; // 简单的自旋锁，防止并发

static void add_log(const char *func, int x, int y, int w, int h) {
    // 简单锁
    while (__sync_lock_test_and_set(&g_log_lock, 1)) {}
    if (g_log_count < MAX_LOG) {
        strncpy(g_log[g_log_count].func, func, 47);
        g_log[g_log_count].x = x;
        g_log[g_log_count].y = y;
        g_log[g_log_count].w = w;
        g_log[g_log_count].h = h;
        g_log_count++;
    }
    __sync_lock_release(&g_log_lock);
}

// ---- C 函数原始指针 ----
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_uname)(struct utsname *);

static void (*orig_glViewport)(GLint x, GLint y, GLsizei width, GLsizei height);
static void (*orig_glRenderbufferStorage)(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);

// ---- ObjC 原始 IMP ----
static IMP orig_uid_model = NULL;
static IMP orig_screen_bounds = NULL;
static IMP orig_screen_nativeBounds = NULL;
static IMP orig_screen_scale = NULL;
static IMP orig_screen_nativeScale = NULL;
static IMP orig_screenMode_size = NULL;

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

// ========== sysctlbyname / sysctl / uname（继续欺骗）==========

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

// ========== UIScreen 系列（继续欺骗）==========

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

// ========== glViewport（只记录，不修改！）==========

void replaced_glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    add_log("glViewport", x, y, width, height);
    orig_glViewport(x, y, width, height);
}

// ========== glRenderbufferStorage（只记录）==========

void replaced_glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) {
    add_log("glRenderbufferStorage", 0, 0, width, height);
    orig_glRenderbufferStorage(target, internalformat, width, height);
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
            if (g_log[i].x == 0 && g_log[i].y == 0) {
                [logStr appendFormat:@"  %2d. %s: %d x %d\n",
                    i+1, g_log[i].func, g_log[i].w, g_log[i].h];
            } else {
                [logStr appendFormat:@"  %2d. %s: (%d,%d) %d x %d\n",
                    i+1, g_log[i].func, g_log[i].x, g_log[i].y, g_log[i].w, g_log[i].h];
            }
        }
        if (g_log_count > 20) {
            [logStr appendFormat:@"  ... (共 %d 次)", g_log_count];
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"IB3DeviceSpoof v14 纯诊断\n"
            @"（只记录，不修改渲染）\n\n"
            @"设备: %s\n"
            @"hw.machine: %s\n\n"
            @"UIScreen bounds: %.0f x %.0f\n"
            @"nativeBounds: %.0f x %.0f\n\n"
            @"GL 调用记录 (前%d次/共%d次):\n%@",
            SPOOFED_DEVICE_MODEL, machine,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            show, g_log_count, logStr];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tweak v14 (纯诊断)"
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
        
        // 用最高窗口级别确保弹框在最上面
        UIWindow *alertWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        alertWindow.windowLevel = UIWindowLevelAlert + 1000;
        alertWindow.rootViewController = [UIViewController new];
        alertWindow.hidden = NO;
        [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
        
        // 引用一下防止被释放
        objc_setAssociatedObject(alert, "alertWindow", alertWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        { "glRenderbufferStorage", replaced_glRenderbufferStorage, (void **)&orig_glRenderbufferStorage },
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(rebindings[0]));
    
    fprintf(stderr, "[IB3 v14] C hooks ready (diagnostic only)\n");
    
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
            
            NSLog(@"[IB3 v14] ObjC swizzle: %d/%d OK", ok, total);
            
            // 1.5 秒后弹窗（更早一点，确保在游戏渲染循环跑起来之前）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnostic();
            });
        }
    });
}
