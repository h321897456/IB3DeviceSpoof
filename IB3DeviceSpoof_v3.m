//
//  IB3DeviceSpoof_v3.m
//  无尽之剑3 设备型号欺骗 Tweak（诊断版）
//
//  特点：
//  1. 启动时弹 UIAlertController 确认 tweak 已加载
//  2. Hook 多种设备检测 API
//  3. 记录屏幕尺寸信息
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

static IMP original_model_imp = NULL;

id replaced_model(id self, SEL _cmd) {
    return [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
}

// ========== 弹窗诊断 ==========

static void showDiagnosticAlert() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 获取当前屏幕尺寸
        CGRect bounds = [UIScreen mainScreen].bounds;
        CGFloat scale = [UIScreen mainScreen].scale;
        CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
        
        // 读取真实设备型号（没被 hook 前的值我们拿不到了，但可以看系统版本）
        NSString *sysVersion = [UIDevice currentDevice].systemVersion;
        NSString *deviceModel = [UIDevice currentDevice].model;
        
        NSString *message = [NSString stringWithFormat:
            @"IB3DeviceSpoof 已加载！\n\n"
            @"伪装型号: %s\n"
            @"屏幕 bounds: %.0f x %.0f\n"
            @"屏幕 scale: %.1f\n"
            @"原生 scale: %.1f\n"
            @"系统版本: %@\n"
            @"UIDevice model: %@",
            SPOOFED_DEVICE_MODEL,
            bounds.size.width, bounds.size.height,
            scale,
            nativeScale,
            sysVersion,
            deviceModel];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Tweak 诊断"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        
        // 找到最顶层的 viewController 来 present
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

// ========== 延迟弹窗（等 UI 准备好） ==========

static void setupAlertDelay() {
    // 延迟 2 秒弹窗，确保游戏 UI 已经初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        showDiagnosticAlert();
    });
}

// ========== 初始化 ==========

__attribute__((constructor))
static void ib3_spoof_initialize() {
    @autoreleasepool {
        NSLog(@"[IB3DeviceSpoof v3] 开始加载...");
        
        int hooks_ok = 0;
        int hooks_total = 0;
        
        // Hook sysctlbyname
        hooks_total++;
        struct rebinding r1 = {
            .name = "sysctlbyname",
            .replacement = replaced_sysctlbyname,
            .replaced = (void **)&original_sysctlbyname
        };
        if (rebind_symbols(&r1, 1) == 0) { hooks_ok++; }
        
        // Hook sysctl
        hooks_total++;
        struct rebinding r2 = {
            .name = "sysctl",
            .replacement = replaced_sysctl,
            .replaced = (void **)&original_sysctl
        };
        if (rebind_symbols(&r2, 1) == 0) { hooks_ok++; }
        
        // Hook uname
        hooks_total++;
        struct rebinding r3 = {
            .name = "uname",
            .replacement = replaced_uname,
            .replaced = (void **)&original_uname
        };
        if (rebind_symbols(&r3, 1) == 0) { hooks_ok++; }
        
        // Swizzle UIDevice model
        hooks_total++;
        Class UIDeviceClass = objc_getClass("UIDevice");
        if (UIDeviceClass) {
            SEL modelSel = @selector(model);
            Method modelMethod = class_getInstanceMethod(UIDeviceClass, modelSel);
            if (modelMethod) {
                original_model_imp = method_getImplementation(modelMethod);
                method_setImplementation(modelMethod, (IMP)replaced_model);
                hooks_ok++;
            }
        }
        
        NSLog(@"[IB3DeviceSpoof v3] Hook 完成: %d/%d 成功", hooks_ok, hooks_total);
        NSLog(@"[IB3DeviceSpoof v3] 伪装型号: %s", SPOOFED_DEVICE_MODEL);
        
        // 注册一个 runloop 观察者，等 UI 就绪后弹窗
        // 用延迟执行的方式更简单
        setupAlertDelay();
    }
}
