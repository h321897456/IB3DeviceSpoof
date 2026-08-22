//
//  IB3DeviceSpoof_v6.m
//  无尽之剑3 设备型号欺骗 Tweak（纯诊断版）
//
//  目标：不硬改任何东西，只做设备型号欺骗 + 详细诊断
//  搞清楚游戏到底是怎么检测设备的
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "fishhook.h"
#import <objc/runtime.h>

// ========== 配置 ==========

#define SPOOFED_DEVICE_MODEL "iPhone6,2"

// constructor 优先级（数字越小越先执行，100 以上是用户空间）
#define CONSTRUCTOR_PRIORITY 101

// ==========================

// 原始函数指针
static int (*original_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_uname)(struct utsname *name);

// 原始 ObjC 方法 IMP
static IMP original_uid_model = NULL;
static IMP original_nsprocessinfo_hostname = NULL;

// 统计调用次数
static int g_sysctlbyname_count = 0;
static int g_sysctl_count = 0;
static int g_uname_count = 0;

// ========== sysctlbyname hook ==========

int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int result = original_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    
    g_sysctlbyname_count++;
    
    // 只记录跟设备相关的查询
    if (name != NULL && (strstr(name, "hw.") != NULL || 
                         strstr(name, "kern.") != NULL ||
                         strstr(name, "machdep.") != NULL)) {
        
        const char *value = "(null)";
        char buf[256];
        if (oldp != NULL && oldlenp != NULL && *oldlenp > 0 && *oldlenp < sizeof(buf)) {
            strncpy(buf, (const char *)oldp, *oldlenp);
            buf[*oldlenp - 1] = '\0';
            value = buf;
        }
        
        // 如果是 hw.machine，替换成伪装的值
        if (strcmp(name, "hw.machine") == 0) {
            if (oldp != NULL && oldlenp != NULL) {
                size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
                if (*oldlenp >= needed) {
                    strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                    *oldlenp = needed;
                    result = 0;
                    value = SPOOFED_DEVICE_MODEL;
                }
            } else if (oldlenp != NULL) {
                *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
                result = 0;
            }
        }
        
        // 如果是 hw.model，也替换
        if (strcmp(name, "hw.model") == 0) {
            if (oldp != NULL && oldlenp != NULL) {
                size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
                if (*oldlenp >= needed) {
                    strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                    *oldlenp = needed;
                    result = 0;
                    value = SPOOFED_DEVICE_MODEL;
                }
            } else if (oldlenp != NULL) {
                *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
                result = 0;
            }
        }
        
        NSLog(@"[IB3 v6] sysctlbyname[%d] %s → %s (ret=%d)",
              g_sysctlbyname_count, name, value, result);
    }
    
    return result;
}

// ========== sysctl hook ==========

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int result = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    
    g_sysctl_count++;
    
    // CTL_HW = 6, HW_MACHINE = 1, HW_MODEL = 2
    if (namelen >= 2 && name[0] == CTL_HW && 
        (name[1] == HW_MACHINE || name[1] == 2 /* HW_MODEL */)) {
        
        const char *fieldName = (name[1] == HW_MACHINE) ? "hw.machine" : "hw.model";
        
        if (oldp != NULL && oldlenp != NULL) {
            size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= needed) {
                strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                *oldlenp = needed;
                result = 0;
            }
        } else if (oldlenp != NULL) {
            *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
            result = 0;
        }
        
        NSLog(@"[IB3 v6] sysctl[%d] %s → %s (ret=%d)",
              g_sysctl_count, fieldName, SPOOFED_DEVICE_MODEL, result);
    }
    
    return result;
}

// ========== uname hook ==========

int replaced_uname(struct utsname *name) {
    int result = original_uname(name);
    
    g_uname_count++;
    
    if (result == 0 && name != NULL) {
        NSLog(@"[IB3 v6] uname[%d] 原始 machine: %s", g_uname_count, name->machine);
        // 替换
        strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
        NSLog(@"[IB3 v6] uname[%d] 替换后 machine: %s", g_uname_count, name->machine);
    }
    
    return result;
}

// ========== UIDevice model swizzle ==========

id replaced_uid_model(id self, SEL _cmd) {
    NSString *spoofed = [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
    NSLog(@"[IB3 v6] UIDevice model 被调用，返回: %@", spoofed);
    return spoofed;
}

// ========== NSProcessInfo 相关（也可能被用来检测） ==========
// 暂时不 hook，先看日志

// ========== 诊断弹窗 ==========

static void showDiagnosticAlert() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *screen = [UIScreen mainScreen];
        CGRect bounds = screen.bounds;
        CGSize modeSize = screen.currentMode.size;
        
        // 用 sysctlbyname 直接查一下（会经过我们的 hook）
        char machine[256];
        size_t len = sizeof(machine);
        sysctlbyname("hw.machine", machine, &len, NULL, 0);
        
        NSString *message = [NSString stringWithFormat:
            @"IB3DeviceSpoof v6 诊断\n\n"
            @"伪装型号: %s\n"
            @"当前 hw.machine: %s\n\n"
            @"屏幕 bounds: %.0f x %.0f\n"
            @"currentMode: %.0f x %.0f\n"
            @"scale: %.1f\n\n"
            @"sysctlbyname 调用次数: %d\n"
            @"sysctl 调用次数: %d\n"
            @"uname 调用次数: %d",
            SPOOFED_DEVICE_MODEL,
            machine,
            bounds.size.width, bounds.size.height,
            modeSize.width, modeSize.height,
            screen.scale,
            g_sysctlbyname_count,
            g_sysctl_count,
            g_uname_count];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Tweak v6"
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

// ========== 初始化（高优先级） ==========

__attribute__((constructor(CONSTRUCTOR_PRIORITY)))
static void ib3_spoof_initialize() {
    // 注意：这里不能用 ObjC 的东西太早，可能会 crash
    // 先做 C 函数的 hook，ObjC 的稍后做
    
    // --- Hook sysctlbyname ---
    struct rebinding r1 = {
        .name = "sysctlbyname",
        .replacement = replaced_sysctlbyname,
        .replaced = (void **)&original_sysctlbyname
    };
    rebind_symbols(&r1, 1);
    
    // --- Hook sysctl ---
    struct rebinding r2 = {
        .name = "sysctl",
        .replacement = replaced_sysctl,
        .replaced = (void **)&original_sysctl
    };
    rebind_symbols(&r2, 1);
    
    // --- Hook uname ---
    struct rebinding r3 = {
        .name = "uname",
        .replacement = replaced_uname,
        .replaced = (void **)&original_uname
    };
    rebind_symbols(&r3, 1);
    
    // 用宏打印日志（避免太早用 NSLog）
    fprintf(stderr, "[IB3 v6] Constructor 执行完成，C 函数 hook 已就绪\n");
    
    // 延迟做 ObjC 的 swizzle 和弹窗
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            // --- Swizzle UIDevice model ---
            Class UIDeviceClass = objc_getClass("UIDevice");
            if (UIDeviceClass) {
                SEL modelSel = @selector(model);
                Method modelMethod = class_getInstanceMethod(UIDeviceClass, modelSel);
                if (modelMethod) {
                    original_uid_model = method_getImplementation(modelMethod);
                    method_setImplementation(modelMethod, (IMP)replaced_uid_model);
                    NSLog(@"[IB3 v6] UIDevice model swizzle 成功");
                }
            }
            
            NSLog(@"[IB3 v6] 全部 hook 就绪");
            
            // 延迟 2 秒弹窗
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnosticAlert();
            });
        }
    });
}
