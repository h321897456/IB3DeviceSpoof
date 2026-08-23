//
//  IB3DeviceSpoof_v17.m
//  锁死 Viewport 版：所有全屏级 glViewport 一律替换为原生分辨率
//
//  核心修复：
//  - 修复方向判断 bug：用 max(w,h) 来判断是不是全屏级别，不依赖方向
//  - 更激进的替换策略：只要是大尺寸 viewport 就换成全屏
//  - 同时 hook glScissor 确保裁剪区域也是全屏
//  - 保留内存欺骗、UIScreen 欺骗、renderbuffer 放大
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

// 目标像素尺寸（横屏，即最大的那个方向）
#define TARGET_PX_LANDSCAPE_W  2556.0
#define TARGET_PX_LANDSCAPE_H  1179.0

// 起点尺寸（点坐标）
#define SPOOFED_WIDTH_PT    393.0
#define SPOOFED_HEIGHT_PT   852.0
#define SPOOFED_SCALE       3.0

// 内存欺骗
#define SPOOFED_MEM_SIZE    4294967296ULL  // 4GB
#define SPOOFED_CPU_COUNT   6

#define CONSTRUCTOR_PRIORITY 101
#define MAX_LOG 30

// ==========================

typedef struct {
    char func[48];
    int w, h;
    int x, y;
} CallLog;

static CallLog g_log[MAX_LOG];
static int g_log_count = 0;

static void add_log(const char *func, int x, int y, int w, int h) {
    if (g_log_count < MAX_LOG) {
        strncpy(g_log[g_log_count].func, func, 47);
        g_log[g_log_count].x = x;
        g_log[g_log_count].y = y;
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
static void (*orig_glScissor)(GLint x, GLint y, GLsizei width, GLsizei height);

// ---- ObjC 原始 IMP ----
static IMP orig_uid_model = NULL;
static IMP orig_screen_bounds = NULL;
static IMP orig_screen_nativeBounds = NULL;
static IMP orig_screen_scale = NULL;
static IMP orig_screen_nativeScale = NULL;
static IMP orig_screenMode_size = NULL;
static IMP orig_eagl_renderbufferStorage = NULL;

// ---- 统计 ----
static int g_rb_w = 0;
static int g_rb_h = 0;
static int g_vp_replaced = 0; // 被替换的 glViewport 次数
static int g_vp_kept = 0;     // 保持原样的次数

// ========== 工具：获取目标尺寸（不依赖方向，用长边判断）==========

// 返回横屏的目标像素尺寸
static void get_target_px(GLsizei *out_w, GLsizei *out_h, GLsizei cur_w, GLsizei cur_h) {
    // 根据输入的宽高比例，判断当前是横屏还是竖屏调用
    if (cur_w >= cur_h) {
        // 横屏调用 → 返回横屏目标
        *out_w = (GLsizei)TARGET_PX_LANDSCAPE_W;
        *out_h = (GLsizei)TARGET_PX_LANDSCAPE_H;
    } else {
        // 竖屏调用 → 返回竖屏目标
        *out_w = (GLsizei)TARGET_PX_LANDSCAPE_H;
        *out_h = (GLsizei)TARGET_PX_LANDSCAPE_W;
    }
}

// 判断是不是"全屏级别"的 viewport（大于一定尺寸，且比例接近全屏）
static BOOL is_fullscreen_viewport(GLsizei w, GLsizei h) {
    GLsizei maxSide = w > h ? w : h;
    GLsizei minSide = w > h ? h : w;
    
    // 长边大于目标长边的 70%，认为是全屏级别
    // 目标长边是 2556，70% 是 ~1789
    // 2001 > 1789 → 是全屏级别 ✓
    if (maxSide < TARGET_PX_LANDSCAPE_W * 0.7) return NO;
    
    // 短边也不能太小（排除长条状的 UI 元素）
    if (minSide < TARGET_PX_LANDSCAPE_H * 0.7) return NO;
    
    return YES;
}

// ========== sysctlbyname（内存+型号+CPU 欺骗）==========

int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (!name) return ret;
    
    // 设备型号
    if (strcmp(name, "hw.machine") == 0 ||
        strcmp(name, "hw.model") == 0 ||
        strcmp(name, "hw.target") == 0) {
        if (oldp && oldlenp) {
            size_t n = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= n) { strlcpy((char*)oldp, SPOOFED_DEVICE_MODEL, *oldlenp); *oldlenp = n; ret = 0; }
        } else if (oldlenp) { *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1; ret = 0; }
        return ret;
    }
    
    // 内存
    if (strcmp(name, "hw.memsize") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            *(uint64_t *)oldp = SPOOFED_MEM_SIZE;
            *oldlenp = sizeof(uint64_t);
            ret = 0;
        } else if (oldlenp) {
            *oldlenp = sizeof(uint64_t);
            ret = 0;
        }
        return ret;
    }
    
    // CPU 核心数
    if (strcmp(name, "hw.ncpu") == 0 ||
        strcmp(name, "hw.physicalcpu") == 0 ||
        strcmp(name, "hw.logicalcpu") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(int)) {
            *(int *)oldp = SPOOFED_CPU_COUNT;
            *oldlenp = sizeof(int);
            ret = 0;
        } else if (oldlenp) {
            *oldlenp = sizeof(int);
            ret = 0;
        }
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
        // HW_PHYSMEM = 5
        if (name[1] == 5 && namelen == 2) {
            if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
                *(uint64_t *)oldp = SPOOFED_MEM_SIZE;
                *oldlenp = sizeof(uint64_t);
                ret = 0;
            } else if (oldlenp) { *oldlenp = sizeof(uint64_t); ret = 0; }
        }
        // HW_USERMEM = 7
        if (name[1] == 7 && namelen == 2) {
            if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
                *(uint64_t *)oldp = SPOOFED_MEM_SIZE;
                *oldlenp = sizeof(uint64_t);
                ret = 0;
            } else if (oldlenp) { *oldlenp = sizeof(uint64_t); ret = 0; }
        }
        // HW_NCPU = 3
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
        add_log("renderbuffer", 0, 0, w, h);
    }
    
    return result;
}

// ========== glViewport（核心：锁死全屏视口）==========

void replaced_glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    // 只处理全屏级别的 viewport
    if (is_fullscreen_viewport(width, height)) {
        GLsizei target_w, target_h;
        get_target_px(&target_w, &target_h, width, height);
        
        // 如果已经接近目标尺寸，就不用改了
        GLsizei maxTarget = target_w > target_h ? target_w : target_h;
        GLsizei maxCur = width > height ? width : height;
        
        if (maxCur < maxTarget * 0.98) {
            // 替换为全屏
            add_log("glViewport_REPLACED", x, y, width, height);
            g_vp_replaced++;
            orig_glViewport(0, 0, target_w, target_h);
            return;
        }
    }
    
    // 非全屏或已经是全屏 → 保持原样
    if (width > 500) {
        add_log("glViewport_kept", x, y, width, height);
        g_vp_kept++;
    }
    orig_glViewport(x, y, width, height);
}

// ========== glScissor（同步放大裁剪区域）==========

void replaced_glScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    if (is_fullscreen_viewport(width, height)) {
        GLsizei target_w, target_h;
        get_target_px(&target_w, &target_h, width, height);
        
        GLsizei maxTarget = target_w > target_h ? target_w : target_h;
        GLsizei maxCur = width > height ? width : height;
        
        if (maxCur < maxTarget * 0.98) {
            orig_glScissor(0, 0, target_w, target_h);
            return;
        }
    }
    
    orig_glScissor(x, y, width, height);
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
        int show = g_log_count > 15 ? 15 : g_log_count;
        for (int i = 0; i < show; i++) {
            if (g_log[i].x == 0 && g_log[i].y == 0) {
                [logStr appendFormat:@"  %2d. %s: %d x %d\n",
                    i+1, g_log[i].func, g_log[i].w, g_log[i].h];
            } else {
                [logStr appendFormat:@"  %2d. %s: (%d,%d) %d x %d\n",
                    i+1, g_log[i].func, g_log[i].x, g_log[i].y, g_log[i].w, g_log[i].h];
            }
        }
        if (g_log_count > 15) {
            [logStr appendFormat:@"  ... (共 %d 次)", g_log_count];
        }
        
        NSString *msg = [NSString stringWithFormat:
            @"IB3DeviceSpoof v17\n"
            @"（锁死 Viewport 版）\n\n"
            @"设备: %s\n"
            @"内存: %.1f GB\n\n"
            @"UIScreen: %.0f x %.0f pt\n"
            @"nativeBounds: %.0f x %.0f px\n"
            @"renderbuffer: %d x %d\n\n"
            @"glViewport 替换: %d 次\n"
            @"glViewport 保持: %d 次\n\n"
            @"调用记录:\n%@\n"
            @"目标: %.0f x %.0f px (横屏)",
            machine,
            (double)mem / 1073741824.0,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            g_rb_w, g_rb_h,
            g_vp_replaced, g_vp_kept,
            logStr,
            TARGET_PX_LANDSCAPE_W, TARGET_PX_LANDSCAPE_H];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tweak v17"
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
        { "glScissor", replaced_glScissor, (void **)&orig_glScissor },
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(rebindings[0]));
    
    // EAGLContext swizzle
    Class eagl = objc_getClass("EAGLContext");
    if (eagl) {
        SEL rsSel = @selector(renderbufferStorage:fromDrawable:);
        Method m = class_getInstanceMethod(eagl, rsSel);
        if (m) {
            orig_eagl_renderbufferStorage = method_getImplementation(m);
            method_setImplementation(m, (IMP)replaced_eagl_renderbufferStorage);
        }
    }
    
    fprintf(stderr, "[IB3 v17] Constructor init done (viewport lock)\n");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            int ok = 0, total = 0;
            
            Class c = objc_getClass("UIDevice");
            if (c) { total++;
                Method m = class_getInstanceMethod(c, @selector(model));
                if (m) { orig_uid_model = method_getImplementation(m); method_setImplementation(m, (IMP)replaced_uid_model); ok++; }
            }
            
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
            
            NSLog(@"[IB3 v17] ObjC swizzle: %d/%d OK", ok, total);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showDiagnostic(); });
        }
    });
}
