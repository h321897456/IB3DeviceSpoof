//
//  ElingFullscreen_v20.m
//  诊断版：查找离屏 FBO 尺寸
//
//  问题：主 framebuffer 已经是 2556x1179 了，但画面还是小的
//  猜测：游戏先渲染到离屏 FBO，然后贴到主 framebuffer
//  本版本 hook glFramebufferTexture2D 来诊断所有 FBO 的尺寸
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
#define MAX_LOG 30
#define MAX_FBO 20

// ==========================

typedef struct {
    char func[56];
    int w, h;
    int id;  // FBO id 或 texture id
} CallLog;

static CallLog g_log[MAX_LOG];
static int g_log_count = 0;

static void add_log(const char *func, int id, int w, int h) {
    if (g_log_count < MAX_LOG) {
        strncpy(g_log[g_log_count].func, func, 55);
        g_log[g_log_count].id = id;
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
static void (*orig_glFramebufferTexture2D)(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level);
static void (*orig_glTexImage2D)(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *data);
static void (*orig_glBindFramebuffer)(GLenum target, GLuint framebuffer);
static void (*orig_glRenderbufferStorage)(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);

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
static IMP orig_swapBuffers = NULL;
static IMP orig_createFB = NULL;

// ---- 状态 ----
static int g_rb_w = 0;
static int g_rb_h = 0;
static int g_gvs_set_count = 0;
static float g_gvs_last_value = 0;
static int g_swap_count = 0;
static int g_swap_last_w = 0;
static int g_swap_last_h = 0;

static int g_curFBO = 0;
static int g_fboTexCount = 0;
static int g_rbStorageCount = 0;
static int g_texImageCount = 0;

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
        add_log("renderbuffer", 0, w, h);
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
    
    g_swap_count++;
    g_swap_last_w = width;
    g_swap_last_h = height;
    
    if (g_swap_count <= 2) {
        add_log("SwapBuffers", 0, width, height);
    }
    
    if (orig) orig(self, _cmd, width, height);
}

// ========== EAGLView: CreateFramebuffer: ==========

void replaced_createFB(id self, SEL _cmd, int param) {
    void (*orig)(id, SEL, int) = (void*)orig_createFB;
    
    add_log("CreateFramebuffer", param, 0, 0);
    
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)self;
        CGSize s = spoofed_pt_size();
        view.bounds = CGRectMake(0, 0, s.width, s.height);
        view.contentScaleFactor = SPOOFED_SCALE;
    }
    
    if (orig) orig(self, _cmd, param);
}

// ========== 核心诊断：glFramebufferTexture2D ==========
// 记录每次把纹理附加到 FBO 的操作，从而知道每个 FBO 的纹理尺寸

void replaced_glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level) {
    orig_glFramebufferTexture2D(target, attachment, textarget, texture, level);
    
    // 只记录颜色附件（COLOR_ATTACHMENT0）
    if (attachment == GL_COLOR_ATTACHMENT0 && texture != 0) {
        // 获取纹理尺寸
        GLint w = 0, h = 0;
        glBindTexture(textarget, texture);
        glGetTexParameteriv(textarget, GL_TEXTURE_WIDTH, &w);
        glGetTexParameteriv(textarget, GL_TEXTURE_HEIGHT, &h);
        
        g_fboTexCount++;
        
        // 只记录全屏级别的（> 1000 像素）
        if (w > 500 && h > 300 && g_log_count < MAX_LOG - 5) {
            char buf[56];
            snprintf(buf, 56, "FBOtex_%d_tex%d", g_curFBO, texture);
            add_log(buf, 0, w, h);
        }
    }
}

// ========== glBindFramebuffer ==========

void replaced_glBindFramebuffer(GLenum target, GLuint framebuffer) {
    orig_glBindFramebuffer(target, framebuffer);
    if (target == GL_FRAMEBUFFER) {
        g_curFBO = framebuffer;
    }
}

// ========== glRenderbufferStorage ==========

void replaced_glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) {
    g_rbStorageCount++;
    
    // 记录大的 renderbuffer
    if (width > 500 && height > 300 && g_log_count < MAX_LOG - 5) {
        char buf[56];
        snprintf(buf, 56, "RBStorage_fbo%d", g_curFBO);
        add_log(buf, 0, width, height);
    }
    
    orig_glRenderbufferStorage(target, internalformat, width, height);
}

// ========== glTexImage2D ==========

void replaced_glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *data) {
    g_texImageCount++;
    
    // 只在 level=0 且是大纹理时记录
    if (level == 0 && width > 500 && height > 300 && g_log_count < MAX_LOG - 5) {
        char buf[56];
        snprintf(buf, 56, "TexImage2D_%dx%d", width, height);
        add_log(buf, 0, width, height);
    }
    
    orig_glTexImage2D(target, level, internalformat, width, height, border, format, type, data);
}

// ========== Hook EAGLView ==========

static void hook_eaglview_methods() {
    Class eaglViewClass = objc_getClass("EAGLView");
    if (!eaglViewClass) {
        add_log("EAGLView_NOT_FOUND", 0, 0, 0);
        return;
    }
    
    SEL swapSel = NSSelectorFromString(@"SwapBuffersWithWidth:Height:");
    Method swapM = class_getInstanceMethod(eaglViewClass, swapSel);
    if (swapM) {
        orig_swapBuffers = method_getImplementation(swapM);
        method_setImplementation(swapM, (IMP)replaced_swapBuffers);
        add_log("hook_SwapBuffers", 0, 0, 0);
    }
    
    SEL fbSel = NSSelectorFromString(@"CreateFramebuffer:");
    Method fbM = class_getInstanceMethod(eaglViewClass, fbSel);
    if (fbM) {
        orig_createFB = method_getImplementation(fbM);
        method_setImplementation(fbM, (IMP)replaced_createFB);
        add_log("hook_CreateFB", 0, 0, 0);
    }
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
        int show = g_log_count > 25 ? 25 : g_log_count;
        for (int i = 0; i < show; i++) {
            if (g_log[i].w != 0) {
                [logStr appendFormat:@"  %d. %s: %d x %d\n", i+1, g_log[i].func, g_log[i].w, g_log[i].h];
            } else {
                [logStr appendFormat:@"  %d. %s\n", i+1, g_log[i].func];
            }
        }
        if (g_log_count > 25) {
            [logStr appendFormat:@"  ... (共 %d 条)", g_log_count];
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"恶灵全屏 v20\n"
            @"（FBO 诊断版）\n\n"
            @"设备: %s\n"
            @"内存: %.1f GB\n\n"
            @"UIScreen: %.0f x %.0f pt\n"
            @"nativeBounds: %.0f x %.0f px\n"
            @"renderbuffer: %d x %d\n"
            @"SwapBuffers: %d x %d\n\n"
            @"FBO 纹理附加次数: %d\n"
            @"RenderbufferStorage 次数: %d\n"
            @"TexImage2D 次数: %d\n\n"
            @"GlobalViewScale: %.3f → %.3f\n\n"
            @"FBO/纹理记录 (大尺寸):\n%@",
            machine,
            (double)mem / 1073741824.0,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            g_rb_w, g_rb_h,
            g_swap_last_w, g_swap_last_h,
            g_fboTexCount,
            g_rbStorageCount,
            g_texImageCount,
            g_gvs_last_value,
            FORCED_VIEW_SCALE,
            logStr];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"恶灵全屏 v20"
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
        { "glFramebufferTexture2D", replaced_glFramebufferTexture2D, (void **)&orig_glFramebufferTexture2D },
        { "glBindFramebuffer", replaced_glBindFramebuffer, (void **)&orig_glBindFramebuffer },
        { "glRenderbufferStorage", replaced_glRenderbufferStorage, (void **)&orig_glRenderbufferStorage },
        { "glTexImage2D", replaced_glTexImage2D, (void **)&orig_glTexImage2D },
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
    
    fprintf(stderr, "[Eling v20] Constructor init done\n");
    
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
            
            NSLog(@"[Eling v20] ObjC swizzle: %d/%d OK", ok, total);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showDiagnostic(); });
        }
    });
}
