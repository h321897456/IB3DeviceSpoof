//
//  IB3DeviceSpoof_v5.m
//  无尽之剑3 全屏 Tweak（UIScreen 模式拦截版）
//
//  核心发现：游戏调用 [UIScreen setCurrentMode:] 把屏幕设为低分辨率
//  解决方案：hook setCurrentMode:，强制使用原生最高分辨率
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "fishhook.h"
#import <objc/runtime.h>

// ========== 配置 ==========

#define SPOOFED_DEVICE_MODEL "iPhone6,2"

// ==========================

// 原始函数指针
static int (*original_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_uname)(struct utsname *name);

// 原始 ObjC 方法 IMP
static IMP original_setCurrentMode = NULL;
static IMP original_model = NULL;

// 保存原生屏幕模式
static UIScreenMode *g_nativeMode = nil;

// ========== sysctlbyname hook ==========

int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name != NULL && strcmp(name, "hw.machine") == 0) {
        if (oldp != NULL && oldlenp != NULL) {
            size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= needed) {
                strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                *oldlenp = needed;
                return 0;
            } else {
                *oldlenp = needed;
                errno = ENOMEM;
                return -1;
            }
        } else if (oldlenp != NULL) {
            *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
            return 0;
        }
    }
    return original_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ========== sysctl hook ==========

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (namelen >= 2 && name[0] == CTL_HW && name[1] == HW_MACHINE) {
        if (oldp != NULL && oldlenp != NULL) {
            size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= needed) {
                strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                *oldlenp = needed;
                return 0;
            } else {
                *oldlenp = needed;
                errno = ENOMEM;
                return -1;
            }
        } else if (oldlenp != NULL) {
            *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
            return 0;
        }
    }
    return original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

// ========== uname hook ==========

int replaced_uname(struct utsname *name) {
    int result = original_uname(name);
    if (result == 0 && name != NULL) {
        strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
    }
    return result;
}

// ========== UIDevice model swizzle ==========

id replaced_model(id self, SEL _cmd) {
    return [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
}

// ========== UIScreen setCurrentMode: swizzle ==========

// 这是关键！游戏会调用 setCurrentMode: 来降低屏幕分辨率
// 我们拦截它，强制使用最高分辨率

void replaced_setCurrentMode(id self, SEL _cmd, UIScreenMode *mode) {
    NSLog(@"[IB3DeviceSpoof v5] 拦截 setCurrentMode: %@ (size: %@)",
          mode, NSStringFromCGSize(mode.size));
    
    // 强制使用原生最高分辨率模式
    if (g_nativeMode != nil) {
        NSLog(@"[IB3DeviceSpoof v5] → 强制使用原生模式: %@ (size: %@)",
              g_nativeMode, NSStringFromCGSize(g_nativeMode.size));
        
        void (*func)(id, SEL, UIScreenMode *) = (void *)original_setCurrentMode;
        if (func) {
            func(self, _cmd, g_nativeMode);
        }
        return;
    }
    
    // 如果没找到原生模式，找 availableModes 里最大的那个
    NSArray *modes = [self valueForKey:@"availableModes"];
    if (modes && modes.count > 0) {
        UIScreenMode *bestMode = nil;
        CGFloat maxArea = 0;
        for (UIScreenMode *m in modes) {
            CGSize size = m.size;
            CGFloat area = size.width * size.height;
            if (area > maxArea) {
                maxArea = area;
                bestMode = m;
            }
        }
        if (bestMode && bestMode != mode) {
            NSLog(@"[IB3DeviceSpoof v5] → 使用最高分辨率模式: %@",
                  NSStringFromCGSize(bestMode.size));
            void (*func)(id, SEL, UIScreenMode *) = (void *)original_setCurrentMode;
            if (func) {
                func(self, _cmd, bestMode);
            }
            return;
        }
    }
    
    // 兜底：调用原始方法
    void (*func)(id, SEL, UIScreenMode *) = (void *)original_setCurrentMode;
    if (func) {
        func(self, _cmd, mode);
    }
}

// ========== 强制设置原生屏幕模式 ==========

static void forceNativeScreenMode() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *screen = [UIScreen mainScreen];
        UIScreenMode *currentMode = screen.currentMode;
        
        NSLog(@"[IB3DeviceSpoof v5] 当前屏幕模式: %@",
              NSStringFromCGSize(currentMode.size));
        NSLog(@"[IB3DeviceSpoof v5] 原生 scale: %.1f", screen.nativeScale);
        
        // 找到最高分辨率的模式
        NSArray *modes = [screen valueForKey:@"availableModes"];
        NSLog(@"[IB3DeviceSpoof v5] 可用模式数量: %lu", (unsigned long)modes.count);
        
        UIScreenMode *bestMode = nil;
        CGFloat maxArea = 0;
        for (UIScreenMode *m in modes) {
            CGSize size = m.size;
            CGFloat area = size.width * size.height;
            NSLog(@"  - %@ (area: %.0f)", NSStringFromCGSize(size), area);
            if (area > maxArea) {
                maxArea = area;
                bestMode = m;
            }
        }
        
        if (bestMode) {
            g_nativeMode = bestMode;
            NSLog(@"[IB3DeviceSpoof v5] 最高分辨率模式: %@",
                  NSStringFromCGSize(bestMode.size));
            
            // 如果当前模式不是最高的，强制改过来
            if (!CGSizeEqualToSize(currentMode.size, bestMode.size)) {
                NSLog(@"[IB3DeviceSpoof v5] 强制切换到最高分辨率...");
                [screen setCurrentMode:bestMode];
                NSLog(@"[IB3DeviceSpoof v5] 切换后 bounds: %@",
                      NSStringFromCGRect(screen.bounds));
            }
        }
    });
}

// ========== 诊断弹窗 ==========

static void showDiagnosticAlert() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *screen = [UIScreen mainScreen];
        CGRect bounds = screen.bounds;
        CGFloat scale = screen.scale;
        CGSize modeSize = screen.currentMode.size;
        
        NSString *message = [NSString stringWithFormat:
            @"IB3DeviceSpoof v5 已加载\n\n"
            @"伪装型号: %s\n"
            @"屏幕 bounds: %.0f x %.0f\n"
            @"屏幕 scale: %.1f\n"
            @"currentMode: %.0f x %.0f\n"
            @"原生 scale: %.1f",
            SPOOFED_DEVICE_MODEL,
            bounds.size.width, bounds.size.height,
            scale,
            modeSize.width, modeSize.height,
            screen.nativeScale];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Tweak v5 诊断"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window) {
            window = [[UIApplication sharedApplication].windows firstObject];
        }
        
        UIViewController *rootVC = window.rootViewController;
        if (rootVC) {
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

// ========== 初始化 ==========

__attribute__((constructor))
static void ib3_spoof_initialize() {
    @autoreleasepool {
        NSLog(@"[IB3DeviceSpoof v5] 开始加载...");
        
        int hooks_ok = 0;
        int hooks_total = 0;
        
        // --- Hook C 函数 ---
        hooks_total++;
        struct rebinding r1 = {
            .name = "sysctlbyname",
            .replacement = replaced_sysctlbyname,
            .replaced = (void **)&original_sysctlbyname
        };
        if (rebind_symbols(&r1, 1) == 0) hooks_ok++;
        
        hooks_total++;
        struct rebinding r2 = {
            .name = "sysctl",
            .replacement = replaced_sysctl,
            .replaced = (void **)&original_sysctl
        };
        if (rebind_symbols(&r2, 1) == 0) hooks_ok++;
        
        hooks_total++;
        struct rebinding r3 = {
            .name = "uname",
            .replacement = replaced_uname,
            .replaced = (void **)&original_uname
        };
        if (rebind_symbols(&r3, 1) == 0) hooks_ok++;
        
        // --- Swizzle UIDevice model ---
        hooks_total++;
        Class UIDeviceClass = objc_getClass("UIDevice");
        if (UIDeviceClass) {
            SEL modelSel = @selector(model);
            Method modelMethod = class_getInstanceMethod(UIDeviceClass, modelSel);
            if (modelMethod) {
                original_model = method_getImplementation(modelMethod);
                method_setImplementation(modelMethod, (IMP)replaced_model);
                hooks_ok++;
            }
        }
        
        // --- Swizzle UIScreen setCurrentMode: ---
        // 这是关键中的关键！
        hooks_total++;
        Class UIScreenClass = objc_getClass("UIScreen");
        if (UIScreenClass) {
            SEL setModeSel = @selector(setCurrentMode:);
            Method setModeMethod = class_getInstanceMethod(UIScreenClass, setModeSel);
            if (setModeMethod) {
                original_setCurrentMode = method_getImplementation(setModeMethod);
                method_setImplementation(setModeMethod, (IMP)replaced_setCurrentMode);
                hooks_ok++;
                NSLog(@"[IB3DeviceSpoof v5] ✓ UIScreen setCurrentMode: swizzle 成功");
            } else {
                NSLog(@"[IB3DeviceSpoof v5] ✗ 找不到 setCurrentMode: 方法");
            }
        } else {
            NSLog(@"[IB3DeviceSpoof v5] ✗ 找不到 UIScreen 类");
        }
        
        NSLog(@"[IB3DeviceSpoof v5] Hook 完成: %d/%d 成功", hooks_ok, hooks_total);
        
        // 先保存原生模式（在游戏改它之前）
        // 注意：constructor 阶段 UIScreen 可能还没完全初始化
        // 所以我们用一个早期的通知来捕获
        
        // 延迟 0.5 秒先存一下原生模式
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIScreen *screen = [UIScreen mainScreen];
            g_nativeMode = screen.currentMode;
            NSLog(@"[IB3DeviceSpoof v5] 初始屏幕模式已保存: %@",
                  NSStringFromCGSize(g_nativeMode.size));
        });
        
        // 延迟 3 秒强制切回原生模式（如果被游戏改了的话）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            forceNativeScreenMode();
        });
        
        // 延迟 2 秒显示诊断弹窗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            showDiagnosticAlert();
        });
    }
}
