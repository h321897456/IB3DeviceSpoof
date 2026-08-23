//
//  ElingFullscreen_v19.m
//  精准打击 v2：Hook EAGLView 的核心方法
//
//  修复 v19 的 bug：
//  1. SPOOFED_CPU_COUNT 未定义
//  2. 方法签名更准确
//  3. 增加 setDrawableProperties: hook
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
#define SPOOFED_CPU_COUNT   6

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
static int g_logCount = 0;

static void add_log(const char *func, int w, int h, float val) {
    if (g_logCount < MAX_LOG) {
        strncpy(g_log[g_logCount].func, func, 47);
        g_log[g_logCount].w = w;
        g_log[g_logCount].h = h;
        g_log[g_logCount].val = val;
        g_logCount++;
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
static IMP orig_swapBuffers = NULL;
static IMP orig_layoutDF = NULL;   // layoutSubviewsAndDetermineFrame
static IMP orig_createFB = NULL;   // CreateFramebuffer:
static IMP orig_setDrawableProps = NULL; // setDrawableProperties:
static int g_swapCount = 0;
static int g_swapLastW = 0;
static int g_swapLastH = 0;
static int g_layoutCount = 0;
static int g_createFBCount = 0;
static int g_setDrawableCount = 0;

// ---- 状态 ----
static int g_rbW = 0;
static int g_rbH = 0;
static int g_gvsSetCount = 0;
static float g_gvsLastValue = 0;

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
        g_rbW = w;
        g_rbH = h;
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
    g_gvsSetCount++;
    g_gvsLastValue = scale;
    if (g_gvsSetCount <= 2) add_log("setGVS", 0, 0, scale);
    if (orig) orig(self, _cmd, FORCED_VIEW_SCALE);
}

float replaced_getGlobalViewScale(id self, SEL _cmd) {
    float (*orig)(id, SEL) = (void*)orig_getGlobalViewScale;
    if (orig) (void)orig(self, _cmd);
    return FORCED_VIEW_SCALE;
}

// ========== EAGLView: SwapBuffersWithWidth:Height: ==========

void replaced_swapBuffers(id self, SEL _cmd, int width, int height) {
    void (*orig)(id, SEL, int, int) = (void*)orig_swapBuffers;
    
    g_swapCount++;
    g_swapLastW = width;
    g_swapLastH = height;
    
    if (g_swapCount <= 3) {
        add_log("SwapBuffers", width, height, 0);
    }
    
    if (orig) orig(self, _cmd, width, height);
}

// ========== EAGLView: layoutSubviewsAndDetermineFrame ==========

void replaced_layoutDF(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void*)orig_layoutDF;
    
    g_layoutCount++;
    add_log("layoutSubviews_DF", 0, 0, 0);
    
    // 先强制改大 view
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        view.bounds = CGRectMake(0, 0, s.width, s.height);
        view.contentScaleFactor = SPOOFED_SCALE;
    }
    
    // 再调用原始方法
    if (orig) orig(self, _cmd);
}

// ========== EAGLView: CreateFramebuffer: ==========

void replaced_createFB(id self, SEL _cmd, int param) {
    void (*orig)(id, SEL, int) = (void*)orig_createFB;
    
    g_createFBCount++;
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

// ========== EAGLView: setDrawableProperties: ==========

void replaced_setDrawableProps(id self, SEL _cmd, id props) {
    void (*orig)(id, SEL, id) = (void*)orig_setDrawableProps;
    
    g_setDrawableCount++;
    add_log("setDrawableProps", 0, 0, 0);
    
    // 先改大 view
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        view.bounds = CGRectMake(0, 0, s.width, s.height);
        view.contentScaleFactor = SPOOFED_SCALE;
    }
    
    if (orig) orig(self, _cmd, props);
}

// ========== 查找并 hook EAGLView 的方法 ==========

static void hook_eaglview_methods() {
    Class eaglViewClass = objc_getClass("EAGLView");
    if (!eaglViewClass) {
        add_log("EAGLView_NOT_FOUND", 0, 0, 0);
        return;
    }
    
    int found = 0;
    
    // SwapBuffersWithWidth:Height:
    SEL swapSel = NSSelectorFromString(@"SwapBuffersWithWidth:Height:");
    Method swapM = class_getInstanceMethod(eaglViewClass, swapSel);
    if (swapM) {
        orig_swapBuffers = method_getImplementation(swapM);
        method_setImplementation(swapM, (IMP)replaced_swapBuffers);
        add_log("hook_SwapBuffers", 0, 0, 0);
        found++;
    }
    
    // layoutSubviewsAndDetermineFrame
    SEL layoutSel = NSSelectorFromString(@"layoutSubviewsAndDetermineFrame");
    Method layoutM = class_getInstanceMethod(eaglViewClass, layoutSel);
    if (layoutM) {
        orig_layoutDF = method_getImplementation(layoutM);
        method_setImplementation(layoutM, (IMP)replaced_layoutDF);
        add_log("hook_layoutDF", 0, 0, 0);
        found++;
    }
    
    // CreateFramebuffer:
    SEL fbSel = NSSelectorFromString(@"CreateFramebuffer:");
    Method fbM = class_getInstanceMethod(eaglViewClass, fbSel);
    if (fbM) {
        orig_createFB = method_getImplementation(fbM);
        method_setImplementation(fbM, (IMP)replaced_createFB);
        add_log("hook_CreateFB", 0, 0, 0);
        found++;
    }
    
    // setDrawableProperties:
    SEL dpSel = NSSelectorFromString(@"setDrawableProperties:");
    Method dpM = class_getInstanceMethod(eaglViewClass, dpSel);
    if (dpM) {
        orig_setDrawableProps = method_getImplementation(dpM);
        method_setImplementation(dpM, (IMP)replaced_setDrawableProps);
        add_log("hook_setDrawableProps", 0, 0, 0);
        found++;
    }
    
    NSLog(@"[恶灵全屏 v19] EAGLView hooks: %d/4 found", found);
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
        int show = g_logCount > 20 ? 20 : g_logCount;
        for (int i = 0; i < show; i++) {
            if (g_log[i].val != 0 && g_log[i].w == 0) {
                [logStr appendFormat:@"  %d. %s: %.3f\n", i+1, g_log[i].func, g_log[i].val];
            } else if (g_log[i].w != 0) {
                [logStr appendFormat:@"  %d. %s: %d x %d\n", i+1, g_log[i].func, g_log[i].w, g_log[i].h];
            } else {
                [logStr appendFormat:@"  %d. %s\n", i+1, g_log[i].func];
            }
        }
        if (g_logCount > 20) {
            [logStr appendFormat:@"  ... (共 %d 次)", g_logCount];
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"ElingFullscreen v19\n"
            @"（EAGLView 深度 Hook 修复版）\n\n"
            @"设备: %s\n"
            @"内存: %.1f GB\n\n"
            @"UIScreen: %.0f x %.0f pt\n"
            @"nativeBounds: %.0f x %.0f px\n"
            @"renderbuffer: %d x %d\n\n"
            @"SwapBuffers 次数: %d\n"
            @"  最后尺寸: %d x %d\n"
            @"layoutSubviews_DF: %d 次\n"
            @"CreateFramebuffer: %d 次\n"
            @"setDrawableProps: %d 次\n\n"
            @"GlobalViewScale 原始: %.3f\n"
            @"GlobalViewScale 强制: %.3f\n\n"
            @"调用记录:\n%@",
            machine,
            (double)mem / 1073741824.0,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            g_rbW, g_rbH,
            g_swapCount, g_swapLastW, g_swapLastH,
            g_layoutCount,
            g_createFBCount,
            g_setDrawableCount,
            g_gvsLastValue,
            FORCED_VIEW_SCALE,
            logStr];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"恶灵全屏 v19"
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
static void eling_init() {
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
    
    fprintf(stderr, "[恶灵全屏 v19] Constructor init done\n");
    
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
            
            hook_global_view_scale();
            hook_eaglview_methods();
            
            NSLog(@"[恶灵全屏 v19] ObjC swizzle: %d/%d OK", ok, total);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showDiagnostic(); });
        }
    });
}
