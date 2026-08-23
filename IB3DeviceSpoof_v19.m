//
//  IB3DeviceSpoof_v19.m
//  精准打击 v2：Hook EAGLView 的 SwapBuffersWithWidth:Height:
//  以及 layoutSubviewsAndDetermineFrame
//
//  分析发现：2001x1125 = 1334x750 (iPhone 6) × 1.5
//  说明 UE3 用设备预设的基础分辨率来计算渲染大小
//  我们直接 hook SwapBuffersWithWidth:Height: 来拦截最终的渲染尺寸
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
#define SPOOFED_MEM_SIZE    4294967296ULL

#define FORCED_VIEW_SCALE  1.0f

#define CONSTRUCTOR_PRIORITY 101
#define MAX_LOG 25

// ==========================

typedef struct {
    char func[48];
    int w, h;
    float val;
} CallLog;

static CallLog g_log[MAX_LOG];
static int g_log_count = 0;

static void add_log(const char *func, int w, int h, float val) {
    if (g_log_count < MAX_LOG) {
        strncpy(g_log[g_log_count].func, func, 47);
        g_log[g_log_count].w = w;
        g_log[g_log_count].h = h;
        g_log[g_log_count].val = val;
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
static IMP orig_setGlobalViewScale = NULL;
static IMP orig_getGlobalViewScale = NULL;

// EAGLView 相关
static IMP orig_swapBuffers = NULL;   // SwapBuffersWithWidth:Height:
static IMP orig_layoutSubviews = NULL; // layoutSubviewsAndDetermineFrame
static IMP orig_createFramebuffer = NULL; // CreateFramebuffer:
static int g_swap_count = 0;
static int g_swap_last_w = 0;
static int g_swap_last_h = 0;
static int g_layout_count = 0;
static int g_createFB_count = 0;

// ---- 状态 ----
static int g_rb_w = 0;
static int g_rb_h = 0;
static int g_gvs_set_count = 0;
static float g_gvs_last_value = 0;

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

// ========== sysctlbyname ==========

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
        return ret;
    }
    
    if (strcmp(name, "hw.memsize") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            *(uint64_t *)oldp = SPOOFED_MEM_SIZE;
            *oldlenp = sizeof(uint64_t);
            ret = 0;
        } else if (oldlenp) { *oldlenp = sizeof(uint64_t); ret = 0; }
        return ret;
    }
    
    if (strcmp(name, "hw.ncpu") == 0 ||
        strcmp(name, "hw.physicalcpu") == 0 ||
        strcmp(name, "hw.logicalcpu") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(int)) {
            *(int *)oldp = SPOOFED_CPU_COUNT;
            *oldlenp = sizeof(int);
            ret = 0;
        } else if (oldlenp) { *oldlenp = sizeof(int); ret = 0; }
        return ret;
    }
    
    return ret;
}

// ========== sysctl ==========

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (namelen >= 2 && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE || name[1] == 2) {
            if (oldp && oldlenp) {
                size_t n = strlen(SPOOFED_DEVICE_MODEL) + 1;
                if (*oldlenp >= n) { strlcpy((char*)oldp, SPOOFED_DEVICE_MODEL, *oldlenp); *oldlenp = n; ret = 0; }
            } else if (oldlenp) { *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1; ret = 0; }
        }
        if (name[1] == 5 && namelen == 2) {
            if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
                *(uint64_t *)oldp = SPOOFED_MEM_SIZE;
                *oldlenp = sizeof(uint64_t);
                ret = 0;
            } else if (oldlenp) { *oldlenp = sizeof(uint64_t); ret = 0; }
        }
        if (name[1] == 7 && namelen == 2) {
            if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
                *(uint64_t *)oldp = SPOOFED_MEM_SIZE;
                *oldlenp = sizeof(uint64_t);
                ret = 0;
            } else if (oldlenp) { *oldlenp = sizeof(uint64_t); ret = 0; }
        }
        if (name[1] == 3 && namelen == 2) {
            if (oldp && oldlenp && *oldlenp >= sizeof(int)) {
                *(int *)oldp = SPOOFED_CPU_COUNT;
                *oldlenp = sizeof(int);
                ret = 0;
            } else if (oldlenp) { *oldlenp = sizeof(int); ret = 0; }
        }
    }
    return ret;
}

// ========== uname ==========

int replaced_uname(struct utsname *name) {
    int ret = orig_uname(name);
    if (ret == 0 && name) strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
    return ret;
}

// ========== UIDevice model ==========

id replaced_uid_model(id self, SEL _cmd) {
    return [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
}

// ========== UIScreen ==========

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

// ========== EAGLContext renderbufferStorage ==========

BOOL replaced_eagl_renderbufferStorage(id self, SEL _cmd, GLenum target, id drawable) {
    BOOL (*orig)(id, SEL, GLenum, id) = (void*)orig_eagl_renderbufferStorage;
    
    if ([drawable isKindOfClass:[CAEAGLLayer class]]) {
        CAEAGLLayer *layer = (CAEAGLLayer *)drawable;
        CGSize s = spoofed_pt_size();
        layer.bounds = CGRectMake(0, 0, s.width, s.height);
        layer.contentsScale = SPOOFED_SCALE;
    }
    
    BOOL result = orig ? orig(self, _cmd, target, drawable) : NO;
    
    if (result) {
        GLint w = 0, h = 0;
        glGetRenderbufferParameteriv(target, GL_RENDERBUFFER_WIDTH, &w);
        glGetRenderbufferParameteriv(target, GL_RENDERBUFFER_HEIGHT, &h);
        g_rb_w = w;
        g_rb_h = h;
        add_log("renderbuffer", w, h, 0);
    }
    
    return result;
}

// ========== glViewport ==========

void replaced_glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    GLsizei maxSide = width > height ? width : height;
    GLsizei minSide = width > height ? height : width;
    
    if (maxSide > 1500 && minSide > 800) {
        CGSize px = spoofed_px_size();
        GLsizei maxTarget = px.width > px.height ? px.width : px.height;
        
        if (maxSide < maxTarget * 0.98) {
            orig_glViewport(0, 0, (GLsizei)px.width, (GLsizei)px.height);
            return;
        }
    }
    
    orig_glViewport(x, y, width, height);
}

// ========== GlobalViewScale ==========

void replaced_setGlobalViewScale(id self, SEL _cmd, float scale) {
    void (*orig)(id, SEL, float) = (void*)orig_setGlobalViewScale;
    g_gvs_set_count++;
    g_gvs_last_value = scale;
    if (g_gvs_set_count <= 2) add_log("setGVS", 0, 0, scale);
    if (orig) orig(self, _cmd, FORCED_VIEW_SCALE);
}

float replaced_getGlobalViewScale(id self, SEL _cmd) {
    float (*orig)(id, SEL) = (void*)orig_getGlobalViewScale;
    if (orig) (void)orig(self, _cmd);
    return FORCED_VIEW_SCALE;
}

// ========== 核心：SwapBuffersWithWidth:Height: ==========
// 这是每帧交换缓冲时调用的，参数就是当前渲染的宽高

void replaced_swapBuffers(id self, SEL _cmd, int width, int height) {
    void (*orig)(id, SEL, int, int) = (void*)orig_swapBuffers;
    
    g_swap_count++;
    g_swap_last_w = width;
    g_swap_last_h = height;
    
    // 只记录前几次
    if (g_swap_count <= 3) {
        add_log("SwapBuffers", width, height, 0);
    }
    
    // 直接调用原始的，不修改参数
    // 因为 SwapBuffers 只是呈现，不决定渲染分辨率
    if (orig) orig(self, _cmd, width, height);
}

// ========== layoutSubviewsAndDetermineFrame ==========
// 这个方法名暗示它决定了 frame 大小

void replaced_layoutSubviewsAndDetermineFrame(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void*)orig_layoutSubviews;
    
    g_layout_count++;
    add_log("layoutSubviews_DF", 0, 0, 0);
    
    // 调用原始方法
    if (orig) orig(self, _cmd);
    
    // 调用完之后，强制把 view 的 bounds 改大
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        view.bounds = CGRectMake(0, 0, s.width, s.height);
        view.contentScaleFactor = SPOOFED_SCALE;
        
        // 也改 layer
        view.layer.bounds = CGRectMake(0, 0, s.width, s.height);
        if ([view.layer isKindOfClass:[CAEAGLLayer class]]) {
            ((CAEAGLLayer *)view.layer).contentsScale = SPOOFED_SCALE;
        }
    }
}

// ========== CreateFramebuffer: ==========

void replaced_createFramebuffer(id self, SEL _cmd, int param) {
    void (*orig)(id, SEL, int) = (void*)orig_createFramebuffer;
    
    g_createFB_count++;
    add_log("CreateFramebuffer", 0, 0, (float)param);
    
    // 先强制改大 view，再创建 framebuffer
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        view.bounds = CGRectMake(0, 0, s.width, s.height);
        view.contentScaleFactor = SPOOFED_SCALE;
    }
    
    if (orig) orig(self, _cmd, param);
}

// ========== 查找并 hook EAGLView 的方法 ==========

static void hook_eaglview_methods() {
    Class eaglViewClass = objc_getClass("EAGLView");
    if (!eaglViewClass) {
        add_log("EAGLView_not_found", 0, 0, 0);
        return;
    }
    
    int found = 0;
    
    // SwapBuffersWithWidth:Height:
    SEL swapSel = NSSelectorFromString(@"SwapBuffersWithWidth:Height:");
    Method swapM = class_getInstanceMethod(eaglViewClass, swapSel);
    if (swapM) {
        orig_swapBuffers = method_getImplementation(swapM);
        method_setImplementation(swapM, (IMP)replaced_swapBuffers);
        add_log("SwapBuffers_hooked", 0, 0, 0);
        found++;
    }
    
    // layoutSubviewsAndDetermineFrame
    SEL layoutSel = NSSelectorFromString(@"layoutSubviewsAndDetermineFrame");
    Method layoutM = class_getInstanceMethod(eaglViewClass, layoutSel);
    if (layoutM) {
        orig_layoutSubviews = method_getImplementation(layoutM);
        method_setImplementation(layoutM, (IMP)replaced_layoutSubviewsAndDetermineFrame);
        add_log("layoutSubviews_hooked", 0, 0, 0);
        found++;
    }
    
    // CreateFramebuffer:
    SEL fbSel = NSSelectorFromString(@"CreateFramebuffer:");
    Method fbM = class_getInstanceMethod(eaglViewClass, fbSel);
    if (fbM) {
        orig_createFramebuffer = method_getImplementation(fbM);
        method_setImplementation(fbM, (IMP)replaced_createFramebuffer);
        add_log("CreateFB_hooked", 0, 0, 0);
        found++;
    }
    
    NSLog(@"[IB3 v19] EAGLView hooks: %d found", found);
}

// ========== 查找 GlobalViewScale ==========

static void hook_global_view_scale() {
    const char *names[] = { "IPhoneAppDelegate", NULL };
    
    for (int i = 0; names[i]; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        
        SEL setSel = NSSelectorFromString(@"setGlobalViewScale:");
        Method setM = class_getInstanceMethod(cls, setSel);
        if (setM) {
            orig_setGlobalViewScale = method_getImplementation(setM);
            method_setImplementation(setM, (IMP)replaced_setGlobalViewScale);
        }
        
        SEL getSel = NSSelectorFromString(@"GlobalViewScale");
        Method getM = class_getInstanceMethod(cls, getSel);
        if (getM) {
            orig_getGlobalViewScale = method_getImplementation(getM);
            method_setImplementation(getM, (IMP)replaced_getGlobalViewScale);
        }
    }
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
        
        uint64_t mem = 0; len = sizeof(mem);
        sysctlbyname("hw.memsize", &mem, &len, NULL, 0);
        
        NSMutableString *logStr = [NSMutableString string];
        int show = g_log_count > 20 ? 20 : g_log_count;
        for (int i = 0; i < show; i++) {
            if (g_log[i].val != 0 && g_log[i].w == 0) {
                [logStr appendFormat:@"  %d. %s: %.3f\n", i+1, g_log[i].func, g_log[i].val];
            } else if (g_log[i].w != 0) {
                [logStr appendFormat:@"  %d. %s: %d x %d\n", i+1, g_log[i].func, g_log[i].w, g_log[i].h];
            } else {
                [logStr appendFormat:@"  %d. %s\n", i+1, g_log[i].func];
            }
        }
        if (g_log_count > 20) {
            [logStr appendFormat:@"  ... (共 %d 次)", g_log_count];
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"IB3DeviceSpoof v19\n"
            @"（EAGLView 深度 Hook 版）\n\n"
            @"设备: %s\n"
            @"内存: %.1f GB\n\n"
            @"UIScreen: %.0f x %.0f pt\n"
            @"nativeBounds: %.0f x %.0f px\n"
            @"renderbuffer: %d x %d\n\n"
            @"SwapBuffers 次数: %d\n"
            @"  最后尺寸: %d x %d\n"
            @"layoutSubviews 次数: %d\n"
            @"CreateFramebuffer 次数: %d\n\n"
            @"GlobalViewScale 原始: %.3f\n"
            @"GlobalViewScale 强制: %.3f\n\n"
            @"调用记录:\n%@",
            machine,
            (double)mem / 1073741824.0,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            g_rb_w, g_rb_h,
            g_swap_count, g_swap_last_w, g_swap_last_h,
            g_layout_count,
            g_createFB_count,
            g_gvs_last_value,
            FORCED_VIEW_SCALE,
            logStr];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tweak v19"
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
    struct rebinding rebindings[] = {
        { "sysctlbyname", replaced_sysctlbyname, (void **)&orig_sysctlbyname },
        { "sysctl", replaced_sysctl, (void **)&orig_sysctl },
        { "uname", replaced_uname, (void **)&orig_uname },
        { "glViewport", replaced_glViewport, (void **)&orig_glViewport },
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(rebindings[0]));
    
    Class eagl = objc_getClass("EAGLContext");
    if (eagl) {
        SEL rsSel = @selector(renderbufferStorage:fromDrawable:);
        Method m = class_getInstanceMethod(eagl, rsSel);
        if (m) {
            orig_eagl_renderbufferStorage = method_getImplementation(m);
            method_setImplementation(m, (IMP)replaced_eagl_renderbufferStorage);
        }
    }
    
    fprintf(stderr, "[IB3 v19] Constructor init done\n");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            int ok = 0, total = 0;
            
            Class c = objc_getClass("UIDevice");
            if (c) { total++;
                Method m = class_getInstanceMethod(c, @selector(model));
                if (m) { orig_uid_model = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_uid_model); ok++; } }
            
            Class sc = objc_getClass("UIScreen");
            total++;
            if (sc) { Method m = class_getInstanceMethod(sc, @selector(bounds));
                if (m) { orig_screen_bounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_bounds); ok++; } }
            total++;
            if (sc && [sc instancesRespondToSelector:@selector(nativeBounds)]) {
                Method m = class_getInstanceMethod(sc, @selector(nativeBounds));
                if (m) { orig_screen_nativeBounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_nativeBounds); ok++; } }
            total++;
            if (sc) { Method m = class_getInstanceMethod(sc, @selector(scale));
                if (m) { orig_screen_scale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_scale); ok++; } }
            total++;
            if (sc && [sc instancesRespondToSelector:@selector(nativeScale)]) {
                Method m = class_getInstanceMethod(sc, @selector(nativeScale));
                if (m) { orig_screen_nativeScale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_nativeScale); ok++; } }
            
            total++;
            Class smc = objc_getClass("UIScreenMode");
            if (smc) { Method m = class_getInstanceMethod(smc, @selector(size));
                if (m) { orig_screenMode_size = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screenMode_size); ok++; } }
            
            // GlobalViewScale
            hook_global_view_scale();
            
            // EAGLView 方法
            hook_eaglview_methods();
            
            NSLog(@"[IB3 v19] ObjC swizzle: %d/%d OK", ok, total);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showDiagnostic(); });
        }
    });
}
