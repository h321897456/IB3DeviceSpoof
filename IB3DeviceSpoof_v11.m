//
//  IB3DeviceSpoof_v11.m
//  无尽之剑3 全屏 Tweak（iPhone 13 Pro 真实分辨率版）
//
//  策略：
//  1. 伪装设备型号为 iPhone14,2（iPhone 13 Pro 本身型号）
//  2. Hook UIScreen 相关 API，返回 iPhone 13 Pro 真实的全面屏尺寸
//  3. 让 UE3 引擎用原生分辨率渲染
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "fishhook.h"
#import <objc/runtime.h>

// ========== 配置：iPhone 13 Pro 真实参数 ==========

// 设备型号：iPhone 13 Pro
#define SPOOFED_DEVICE_MODEL "iPhone14,2"

// 屏幕点坐标（竖屏）：iPhone 13 Pro
#define SPOOFED_WIDTH_PT    393.0
#define SPOOFED_HEIGHT_PT   852.0
#define SPOOFED_SCALE       3.0

#define CONSTRUCTOR_PRIORITY 101

// ==========================

// ---- C 函数原始指针 ----
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_uname)(struct utsname *);

// ---- ObjC 原始 IMP ----
static IMP orig_uid_model = NULL;
static IMP orig_screen_bounds = NULL;
static IMP orig_screen_nativeBounds = NULL;
static IMP orig_screen_scale = NULL;
static IMP orig_screen_nativeScale = NULL;
static IMP orig_screenMode_size = NULL;

// ---- 统计 ----
static int g_hw_machine_calls = 0;

// ========== 工具：根据方向返回尺寸 ==========

static CGSize spoofed_size_in_orientation(CGSize ptSize) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return ptSize; // 太早了，默认竖屏
    
    UIInterfaceOrientation orient = app.statusBarOrientation;
    if (UIInterfaceOrientationIsLandscape(orient)) {
        return CGSizeMake(ptSize.height, ptSize.width);
    }
    return ptSize;
}

static CGSize spoofed_pt_size() {
    return spoofed_size_in_orientation(CGSizeMake(SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT));
}

static CGSize spoofed_px_size() {
    CGSize pt = spoofed_size_in_orientation(CGSizeMake(SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT));
    return CGSizeMake(pt.width * SPOOFED_SCALE, pt.height * SPOOFED_SCALE);
}

// ========== sysctlbyname hook ==========

int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    
    if (!name) return ret;
    
    BOOL isMachine = (strcmp(name, "hw.machine") == 0);
    BOOL isModel = (strcmp(name, "hw.model") == 0);
    BOOL isTarget = (strcmp(name, "hw.target") == 0);
    
    if (isMachine || isModel || isTarget) {
        g_hw_machine_calls++;
        
        if (oldp && oldlenp) {
            size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= needed) {
                strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                *oldlenp = needed;
                ret = 0;
            }
        } else if (oldlenp) {
            *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
            ret = 0;
        }
    }
    
    return ret;
}

// ========== sysctl hook ==========

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    
    if (namelen >= 2 && name[0] == CTL_HW &&
        (name[1] == HW_MACHINE || name[1] == 2)) {
        if (oldp && oldlenp) {
            size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= needed) {
                strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                *oldlenp = needed;
                ret = 0;
            }
        } else if (oldlenp) {
            *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
            ret = 0;
        }
    }
    
    return ret;
}

// ========== uname hook ==========

int replaced_uname(struct utsname *name) {
    int ret = orig_uname(name);
    if (ret == 0 && name) {
        strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
    }
    return ret;
}

// ========== UIDevice model ==========

id replaced_uid_model(id self, SEL _cmd) {
    return [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
}

// ========== UIScreen bounds ==========

CGRect replaced_screen_bounds(id self, SEL _cmd) {
    CGRect (*func)(id, SEL) = (void *)orig_screen_bounds;
    if (func) { (void)func(self, _cmd); }
    
    CGSize size = spoofed_pt_size();
    return CGRectMake(0, 0, size.width, size.height);
}

// ========== UIScreen nativeBounds ==========

CGRect replaced_screen_nativeBounds(id self, SEL _cmd) {
    CGRect (*func)(id, SEL) = (void *)orig_screen_nativeBounds;
    if (func) { (void)func(self, _cmd); }
    
    CGSize size = spoofed_px_size();
    return CGRectMake(0, 0, size.width, size.height);
}

// ========== UIScreen scale ==========

CGFloat replaced_screen_scale(id self, SEL _cmd) {
    return SPOOFED_SCALE;
}

// ========== UIScreen nativeScale ==========

CGFloat replaced_screen_nativeScale(id self, SEL _cmd) {
    return SPOOFED_SCALE;
}

// ========== UIScreenMode size ==========

CGSize replaced_screenMode_size(id self, SEL _cmd) {
    CGSize (*func)(id, SEL) = (void *)orig_screenMode_size;
    CGSize real = func ? func(self, _cmd) : CGSizeZero;
    
    CGSize px = spoofed_px_size();
    return px;
}

// ========== 诊断弹窗 ==========

static void showDiagnostic() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *s = [UIScreen mainScreen];
        CGRect b = s.bounds;
        CGRect nb = CGRectZero;
        if ([s respondsToSelector:@selector(nativeBounds)]) {
            nb = s.nativeBounds;
        }
        CGSize ms = s.currentMode.size;
        CGFloat sc = s.scale;
        CGFloat nsc = s.nativeScale;
        
        char machine[256];
        size_t len = sizeof(machine);
        sysctlbyname("hw.machine", machine, &len, NULL, 0);
        
        NSString *msg = [NSString stringWithFormat:
            @"IB3DeviceSpoof v11\n"
            @"（iPhone 13 Pro 真实分辨率版）\n\n"
            @"伪装型号: %s\n"
            @"hw.machine: %s\n"
            @"调用次数: %d\n\n"
            @"bounds: %.0f x %.0f pt\n"
            @"nativeBounds: %.0f x %.0f px\n"
            @"currentMode: %.0f x %.0f px\n"
            @"scale: %.1f\n"
            @"nativeScale: %.1f\n\n"
            @"目标尺寸: %.0f x %.0f pt @ %.0fx\n"
            @"（iPhone 13 Pro 竖屏）",
            SPOOFED_DEVICE_MODEL,
            machine,
            g_hw_machine_calls,
            b.size.width, b.size.height,
            nb.size.width, nb.size.height,
            ms.width, ms.height,
            sc, nsc,
            SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT, SPOOFED_SCALE];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tweak v11"
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
    struct rebinding r1 = { "sysctlbyname", replaced_sysctlbyname, (void **)&orig_sysctlbyname };
    struct rebinding r2 = { "sysctl", replaced_sysctl, (void **)&orig_sysctl };
    struct rebinding r3 = { "uname", replaced_uname, (void **)&orig_uname };
    struct rebinding rebindings[] = { r1, r2, r3 };
    rebind_symbols(rebindings, 3);
    
    fprintf(stderr, "[IB3 v11] C hooks ready (device: %s)\n", SPOOFED_DEVICE_MODEL);
    
    // ---- ObjC swizzle ----
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            int ok = 0;
            int total = 0;
            
            // UIDevice model
            total++;
            Class c = objc_getClass("UIDevice");
            if (c) {
                Method m = class_getInstanceMethod(c, @selector(model));
                if (m) {
                    orig_uid_model = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_uid_model);
                    ok++;
                }
            }
            
            // UIScreen bounds
            total++;
            Class sc = objc_getClass("UIScreen");
            if (sc) {
                Method m = class_getInstanceMethod(sc, @selector(bounds));
                if (m) {
                    orig_screen_bounds = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_screen_bounds);
                    ok++;
                }
            }
            
            // UIScreen nativeBounds
            total++;
            if (sc && [sc instancesRespondToSelector:@selector(nativeBounds)]) {
                Method m = class_getInstanceMethod(sc, @selector(nativeBounds));
                if (m) {
                    orig_screen_nativeBounds = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_screen_nativeBounds);
                    ok++;
                }
            }
            
            // UIScreen scale
            total++;
            if (sc) {
                Method m = class_getInstanceMethod(sc, @selector(scale));
                if (m) {
                    orig_screen_scale = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_screen_scale);
                    ok++;
                }
            }
            
            // UIScreen nativeScale
            total++;
            if (sc && [sc instancesRespondToSelector:@selector(nativeScale)]) {
                Method m = class_getInstanceMethod(sc, @selector(nativeScale));
                if (m) {
                    orig_screen_nativeScale = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_screen_nativeScale);
                    ok++;
                }
            }
            
            // UIScreenMode size
            total++;
            Class smc = objc_getClass("UIScreenMode");
            if (smc) {
                Method m = class_getInstanceMethod(smc, @selector(size));
                if (m) {
                    orig_screenMode_size = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_screenMode_size);
                    ok++;
                }
            }
            
            NSLog(@"[IB3 v11] ObjC swizzle: %d/%d OK", ok, total);
            NSLog(@"[IB3 v11] Spoof: %s, %.0fx%.0f pt @ %.0fx",
                  SPOOFED_DEVICE_MODEL, SPOOFED_WIDTH_PT, SPOOFED_HEIGHT_PT, SPOOFED_SCALE);
            
            // 2 秒后弹窗
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnostic();
            });
        }
    });
}
