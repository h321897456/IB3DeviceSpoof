//
//  ElingFullscreen_v21.m
//  UIKit 层修复：强制 EAGLView 填满屏幕
//
//  v20 证明渲染目标已经是全屏的（2560x1184）
//  问题在于 EAGLView 的 frame 在屏幕上是小的
//  本版本：hook setFrame:/setBounds: + 定时器持续修正
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
#define FORCED_VIEW_SCALE   1.0f
#define CONSTRUCTOR_PRIORITY 101
#define MAX_LOG 30

// ==========================

typedef struct {
    char func[56];
    int w, h;
    float val;
} CallLog;

static CallLog g_log[MAX_LOG];
static int g_log_count = 0;

static void add_log(const char *func, int w, int h, float val) {
    if (g_log_count < MAX_LOG) {
        strncpy(g_log[g_log_count].func, func, 55);
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
static void (*orig_glViewport)(GLint, GLint, GLsizei, GLsizei);

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

// EAGLView hooks
static IMP orig_setFrame = NULL;      // setFrame:
static IMP orig_setBounds = NULL;     // setBounds:
static IMP orig_layoutSubviews = NULL; // layoutSubviews
static IMP orig_createFB = NULL;      // CreateFramebuffer:

// View hierarchy
static __weak UIView *g_eaglView = nil;
static int g_setFrame_count = 0;
static int g_setBounds_count = 0;
static int g_layout_count = 0;
static int g_createFB_count = 0;
static int g_timer_count = 0;
static float g_last_frame_w = 0;
static float g_last_frame_h = 0;
static float g_last_frame_x = 0;
static float g_last_frame_y = 0;
static int g_rb_w = 0;
static int g_rb_h = 0;
static float g_gvs_last = 0;

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
    
    if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0 || strcmp(name, "hw.target") == 0) {
        if (oldp && oldlenp) {
            size_t n = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= n) { strlcpy((char*)oldp, SPOOFED_DEVICE_MODEL, *oldlenp); *oldlenp = n; ret = 0; }
        } else if (oldlenp) { *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1; ret = 0; }
    }
    if (strcmp(name, "hw.memsize") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) { *(uint64_t *)oldp = SPOOFED_MEM_SIZE; *oldlenp = sizeof(uint64_t); ret = 0; }
        else if (oldlenp) { *oldlenp = sizeof(uint64_t); ret = 0; }
    }
    if (strcmp(name, "hw.ncpu") == 0 || strcmp(name, "hw.physicalcpu") == 0 || strcmp(name, "hw.logicalcpu") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(int)) { *(int *)oldp = SPOOFED_CPU_COUNT; *oldlenp = sizeof(int); ret = 0; }
        else if (oldlenp) { *oldlenp = sizeof(int); ret = 0; }
    }
    return ret;
}

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (namelen >= 2 && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE || name[1] == 2) {
            if (oldp && oldlenp) { size_t n = strlen(SPOOFED_DEVICE_MODEL) + 1; if (*oldlenp >= n) { strlcpy((char*)oldp, SPOOFED_DEVICE_MODEL, *oldlenp); *oldlenp = n; ret = 0; } }
            else if (oldlenp) { *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1; ret = 0; }
        }
        if (name[1] == 5 && namelen == 2) { if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) { *(uint64_t *)oldp = SPOOFED_MEM_SIZE; *oldlenp = sizeof(uint64_t); ret = 0; } }
        if (name[1] == 7 && namelen == 2) { if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) { *(uint64_t *)oldp = SPOOFED_MEM_SIZE; *oldlenp = sizeof(uint64_t); ret = 0; } }
        if (name[1] == 3 && namelen == 2) { if (oldp && oldlenp && *oldlenp >= sizeof(int)) { *(int *)oldp = SPOOFED_CPU_COUNT; *oldlenp = sizeof(int); ret = 0; } }
    }
    return ret;
}

int replaced_uname(struct utsname *name) {
    int ret = orig_uname(name);
    if (ret == 0 && name) strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
    return ret;
}

// ========== UIDevice / UIScreen ==========

id replaced_uid_model(id self, SEL _cmd) { return [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL]; }

CGRect replaced_screen_bounds(id self, SEL _cmd) {
    CGRect (*f)(id, SEL) = (void*)orig_screen_bounds; if (f) (void)f(self, _cmd);
    CGSize s = spoofed_pt_size(); return CGRectMake(0, 0, s.width, s.height);
}

CGRect replaced_screen_nativeBounds(id self, SEL _cmd) {
    CGRect (*f)(id, SEL) = (void*)orig_screen_nativeBounds; if (f) (void)f(self, _cmd);
    CGSize s = spoofed_px_size(); return CGRectMake(0, 0, s.width, s.height);
}

CGFloat replaced_screen_scale(id self, SEL _cmd) { return SPOOFED_SCALE; }
CGFloat replaced_screen_nativeScale(id self, SEL _cmd) { return SPOOFED_SCALE; }
CGSize replaced_screenMode_size(id self, SEL _cmd) {
    CGSize (*f)(id, SEL) = (void*)orig_screenMode_size; if (f) (void)f(self, _cmd);
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
        g_rb_w = w; g_rb_h = h;
        add_log("renderbuffer", w, h, 0);
    }
    return result;
}

// ========== glViewport ==========

void replaced_glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    orig_glViewport(x, y, width, height);
}

// ========== GlobalViewScale ==========

void replaced_setGlobalViewScale(id self, SEL _cmd, float scale) {
    void (*orig)(id, SEL, float) = (void*)orig_setGlobalViewScale;
    g_gvs_last = scale;
    if (orig) orig(self, _cmd, FORCED_VIEW_SCALE);
}

float replaced_getGlobalViewScale(id self, SEL _cmd) {
    float (*orig)(id, SEL) = (void*)orig_getGlobalViewScale;
    if (orig) (void)orig(self, _cmd);
    return FORCED_VIEW_SCALE;
}

// ========== EAGLView: setFrame: ==========

void replaced_setFrame(id self, SEL _cmd, CGRect frame) {
    void (*orig)(id, SEL, CGRect) = (void*)orig_setFrame;
    
    g_setFrame_count++;
    g_last_frame_w = frame.size.width;
    g_last_frame_h = frame.size.height;
    g_last_frame_x = frame.origin.x;
    g_last_frame_y = frame.origin.y;
    
    if (g_setFrame_count <= 3) {
        add_log("setFrame_IN", (int)frame.size.width, (int)frame.size.height, 0);
    }
    
    // 强制改成全屏
    CGSize s = spoofed_pt_size();
    CGRect fullFrame = CGRectMake(0, 0, s.width, s.height);
    
    if (g_setFrame_count <= 3) {
        add_log("setFrame_OUT", (int)s.width, (int)s.height, 0);
    }
    
    if (orig) orig(self, _cmd, fullFrame);
    
    // 同时设置 layer
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        view.contentScaleFactor = SPOOFED_SCALE;
        view.layer.contentsScale = SPOOFED_SCALE;
        g_eaglView = view;
    }
}

// ========== EAGLView: setBounds: ==========

void replaced_setBounds(id self, SEL _cmd, CGRect bounds) {
    void (*orig)(id, SEL, CGRect) = (void*)orig_setBounds;
    
    g_setBounds_count++;
    
    if (g_setBounds_count <= 3) {
        add_log("setBounds_IN", (int)bounds.size.width, (int)bounds.size.height, 0);
    }
    
    // 强制全屏
    CGSize s = spoofed_pt_size();
    CGRect fullBounds = CGRectMake(0, 0, s.width, s.height);
    
    if (orig) orig(self, _cmd, fullBounds);
    
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        view.contentScaleFactor = SPOOFED_SCALE;
        view.layer.contentsScale = SPOOFED_SCALE;
        view.layer.bounds = fullBounds;
        g_eaglView = view;
    }
}

// ========== EAGLView: layoutSubviews ==========

void replaced_layoutSubviews(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void*)orig_layoutSubviews;
    
    g_layout_count++;
    
    // 先调原始布局
    if (orig) orig(self, _cmd);
    
    // 然后强制改回全屏
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        CGRect full = CGRectMake(0, 0, s.width, s.height);
        view.frame = full;
        view.bounds = full;
        view.contentScaleFactor = SPOOFED_SCALE;
        view.layer.frame = full;
        view.layer.bounds = full;
        view.layer.contentsScale = SPOOFED_SCALE;
        g_eaglView = view;
    }
    
    if (g_layout_count <= 3) {
        add_log("layoutSubviews", 0, 0, 0);
    }
}

// ========== EAGLView: CreateFramebuffer: ==========

void replaced_createFB(id self, SEL _cmd, int param) {
    void (*orig)(id, SEL, int) = (void*)orig_createFB;
    
    g_createFB_count++;
    add_log("CreateFramebuffer", 0, 0, (float)param);
    
    // 创建前先改大
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        CGRect full = CGRectMake(0, 0, s.width, s.height);
        view.frame = full;
        view.bounds = full;
        view.contentScaleFactor = SPOOFED_SCALE;
        view.layer.frame = full;
        view.layer.bounds = full;
        view.layer.contentsScale = SPOOFED_SCALE;
        g_eaglView = view;
    }
    
    if (orig) orig(self, _cmd, param);
    
    // 创建后再改一次
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        CGRect full = CGRectMake(0, 0, s.width, s.height);
        view.frame = full;
        view.bounds = full;
        view.layer.frame = full;
        view.layer.bounds = full;
    }
}

// ========== 定时器：持续强制全屏 ==========

static CADisplayLink *g_displayLink = nil;

static void forceFullscreen(CADisplayLink *link) {
    g_timer_count++;
    
    UIView *view = g_eaglView;
    if (!view) return;
    
    CGSize s = spoofed_pt_size();
    CGRect full = CGRectMake(0, 0, s.width, s.height);
    
    // 检查是否需要修正
    if (fabs(view.frame.size.width - s.width) > 1 ||
        fabs(view.frame.size.height - s.height) > 1 ||
        fabs(view.frame.origin.x) > 1 ||
        fabs(view.frame.origin.y) > 1) {
        
        // 临时移除 hook 避免递归
        if (view.layer) {
            view.layer.frame = full;
            view.layer.bounds = full;
            view.layer.contentsScale = SPOOFED_SCALE;
        }
    }
    
    // 检查 superview
    UIView *sv = view.superview;
    if (sv) {
        CGSize ss = spoofed_pt_size();
        CGRect sf = CGRectMake(0, 0, ss.width, ss.height);
        if (fabs(sv.frame.size.width - ss.width) > 1 ||
            fabs(sv.frame.size.height - ss.height) > 1) {
            sv.frame = sf;
            sv.bounds = sf;
        }
    }
}

// ========== Hook EAGLView ==========

static void hook_eaglview() {
    Class cls = objc_getClass("EAGLView");
    if (!cls) {
        add_log("EAGLView_NOT_FOUND", 0, 0, 0);
        return;
    }
    
    int found = 0;
    
    // setFrame:
    Method m = class_getInstanceMethod(cls, @selector(setFrame:));
    if (m) { orig_setFrame = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_setFrame); found++; add_log("hook_setFrame", 0, 0, 0); }
    
    // setBounds:
    m = class_getInstanceMethod(cls, @selector(setBounds:));
    if (m) { orig_setBounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_setBounds); found++; add_log("hook_setBounds", 0, 0, 0); }
    
    // layoutSubviews
    m = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (m) { orig_layoutSubviews = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_layoutSubviews); found++; add_log("hook_layout", 0, 0, 0); }
    
    // CreateFramebuffer:
    SEL fbSel = NSSelectorFromString(@"CreateFramebuffer:");
    m = class_getInstanceMethod(cls, fbSel);
    if (m) { orig_createFB = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_createFB); found++; add_log("hook_CreateFB", 0, 0, 0); }
    
    NSLog(@"[Eling v21] EAGLView hooks: %d/4", found);
}

// ========== 查找 GlobalViewScale ==========

static void hook_global_view_scale() {
    Class cls = objc_getClass("IPhoneAppDelegate");
    if (!cls) return;
    SEL setSel = NSSelectorFromString(@"setGlobalViewScale:");
    Method m = class_getInstanceMethod(cls, setSel);
    if (m) { orig_setGlobalViewScale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_setGlobalViewScale); }
    SEL getSel = NSSelectorFromString(@"GlobalViewScale");
    m = class_getInstanceMethod(cls, getSel);
    if (m) { orig_getGlobalViewScale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_getGlobalViewScale); }
}

// ========== 遍历找 EAGLView ==========

static void find_eaglview_recursive(UIView *view) {
    if (!view) return;
    
    const char *clsName = class_getName([view class]);
    if (strstr(clsName, "EAGLView") || strstr(clsName, "eaglview")) {
        g_eaglView = view;
        CGSize s = spoofed_pt_size();
        view.frame = CGRectMake(0, 0, s.width, s.height);
        view.bounds = CGRectMake(0, 0, s.width, s.height);
        view.contentScaleFactor = SPOOFED_SCALE;
        view.layer.frame = CGRectMake(0, 0, s.width, s.height);
        view.layer.bounds = CGRectMake(0, 0, s.width, s.height);
        view.layer.contentsScale = SPOOFED_SCALE;
        add_log("found_EAGLView", (int)view.frame.size.width, (int)view.frame.size.height, 0);
    }
    
    for (UIView *sub in view.subviews) {
        find_eaglview_recursive(sub);
    }
}

// ========== 诊断弹窗 ==========

static void showDiagnostic() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *s = [UIScreen mainScreen];
        CGRect b = s.bounds;
        CGRect nb = [s respondsToSelector:@selector(nativeBounds)] ? s.nativeBounds : CGRectZero;
        
        char machine[256]; size_t len = sizeof(machine);
        sysctlbyname("hw.machine", machine, &len, NULL, 0);
        uint64_t mem = 0; len = sizeof(mem);
        sysctlbyname("hw.memsize", &mem, &len, NULL, 0);
        
        UIView *ev = g_eaglView;
        CGFloat evW = ev ? ev.frame.size.width : 0;
        CGFloat evH = ev ? ev.frame.size.height : 0;
        CGFloat evX = ev ? ev.frame.origin.x : 0;
        CGFloat evY = ev ? ev.frame.origin.y : 0;
        CGFloat evBW = ev ? ev.bounds.size.width : 0;
        CGFloat evBH = ev ? ev.bounds.size.height : 0;
        CGFloat supW = 0, supH = 0;
        if (ev.superview) { supW = ev.superview.frame.size.width; supH = ev.superview.frame.size.height; }
        
        NSMutableString *logStr = [NSMutableString string];
        int show = g_log_count > 22 ? 22 : g_log_count;
        for (int i = 0; i < show; i++) {
            if (g_log[i].val != 0 && g_log[i].w == 0) {
                [logStr appendFormat:@"  %d. %s: %.1f\n", i+1, g_log[i].func, g_log[i].val];
            } else if (g_log[i].w != 0) {
                [logStr appendFormat:@"  %d. %s: %d x %d\n", i+1, g_log[i].func, g_log[i].w, g_log[i].h];
            } else {
                [logStr appendFormat:@"  %d. %s\n", i+1, g_log[i].func];
            }
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"恶灵全屏 v21\n"
            @"（UIKit 层强制全屏）\n\n"
            @"设备: %s\n"
            @"UIScreen: %.0f x %.0f pt\n"
            @"nativeBounds: %.0f x %.0f px\n"
            @"renderbuffer: %d x %d\n\n"
            @"EAGLView frame: (%.1f, %.1f) %.1f x %.1f\n"
            @"EAGLView bounds: %.1f x %.1f\n"
            @"Superview: %.1f x %.1f\n\n"
            @"setFrame 调用: %d 次\n"
            @"  最后传入: %.1f x %.1f\n"
            @"setBounds 调用: %d 次\n"
            @"layoutSubviews: %d 次\n"
            @"CreateFramebuffer: %d 次\n"
            @"定时器修正: %d 次\n\n"
            @"GlobalViewScale: %.3f\n\n"
            @"调用记录:\n%@",
            machine,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            g_rb_w, g_rb_h,
            evX, evY, evW, evH,
            evBW, evBH,
            supW, supH,
            g_setFrame_count,
            g_last_frame_w, g_last_frame_h,
            g_setBounds_count,
            g_layout_count,
            g_createFB_count,
            g_timer_count,
            g_gvs_last,
            logStr];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"恶灵全屏 v21"
                             message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [UIPasteboard generalPasteboard].string = msg; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        
        UIWindow *aw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        aw.windowLevel = UIWindowLevelAlert + 1000;
        aw.rootViewController = [UIViewController new];
        aw.hidden = NO;
        [aw.rootViewController presentViewController:alert animated:YES completion:nil];
        objc_setAssociatedObject(alert, "aw", aw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        Method m = class_getInstanceMethod(eagl, @selector(renderbufferStorage:fromDrawable:));
        if (m) { orig_eagl_renderbufferStorage = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_eagl_renderbufferStorage); }
    }
    
    fprintf(stderr, "[Eling v21] init\n");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            Class c = objc_getClass("UIDevice");
            if (c) { Method m = class_getInstanceMethod(c, @selector(model)); if (m) { orig_uid_model = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_uid_model); } }
            
            Class sc = objc_getClass("UIScreen");
            if (sc) {
                Method m;
                m = class_getInstanceMethod(sc, @selector(bounds)); if (m) { orig_screen_bounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_bounds); }
                if ([sc instancesRespondToSelector:@selector(nativeBounds)]) { m = class_getInstanceMethod(sc, @selector(nativeBounds)); if (m) { orig_screen_nativeBounds = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_nativeBounds); } }
                m = class_getInstanceMethod(sc, @selector(scale)); if (m) { orig_screen_scale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_scale); }
                if ([sc instancesRespondToSelector:@selector(nativeScale)]) { m = class_getInstanceMethod(sc, @selector(nativeScale)); if (m) { orig_screen_nativeScale = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screen_nativeScale); } }
            }
            
            Class smc = objc_getClass("UIScreenMode");
            if (smc) { Method m = class_getInstanceMethod(smc, @selector(size)); if (m) { orig_screenMode_size = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_screenMode_size); } }
            
            hook_global_view_scale();
            hook_eaglview();
            
            // 启动定时器
            g_displayLink = [CADisplayLink displayLinkWithTarget:[NSObject new] selector:@selector(class)];
            // 用 block 方式
            dispatch_async(dispatch_get_main_queue(), ^{
                // 先找 EAGLView
                UIWindow *kw = [UIApplication sharedApplication].keyWindow;
                if (kw) find_eaglview_recursive(kw);
                
                // CADisplayLink 持续修正
                g_displayLink = [CADisplayLink displayLinkWithTarget:
                    [NSClassFromString(@"NSObject") new] selector:@selector(class)];
                // 用更简单的方式
                [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
                    UIView *view = g_eaglView;
                    if (!view) {
                        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
                        if (kw) find_eaglview_recursive(kw);
                        return;
                    }
                    forceFullscreen(nil);
                }];
            });
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showDiagnostic(); });
        }
    });
}
