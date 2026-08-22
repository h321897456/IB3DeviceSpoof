//
//  IB3DeviceSpoof_v9.m
//  无尽之剑3 设备型号欺骗 Tweak（iPhone X 版 - 含屏幕伪装）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "fishhook.h"
#import <objc/runtime.h>

#define SPOOFED_DEVICE_MODEL "iPhone10,3"
#define CONSTRUCTOR_PRIORITY 101

// ====== iPhone X 屏幕参数 ======
// 横屏模式：宽高互换
static const CGSize kSpoofedBounds = {812.0, 375.0};
static const CGSize kSpoofedNativeBounds = {2436.0, 1125.0};
static const CGSize kSpoofedModeSize = {2436.0, 1125.0};
static const CGFloat kSpoofedScale = 3.0;
static const CGFloat kSpoofedNativeScale = 3.0;

static int (*original_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_uname)(struct utsname *name);

static IMP original_uid_model = NULL;
static IMP original_screen_bounds = NULL;
static IMP original_screen_nativeBounds = NULL;
static IMP original_screen_scale = NULL;
static IMP original_screen_nativeScale = NULL;
static IMP original_screen_currentMode = NULL;

static int g_sysctlbyname_count = 0;

// ========== C 函数 hook ==========

int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int result = original_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    
    if (name != NULL) {
        BOOL isMachine = (strcmp(name, "hw.machine") == 0);
        BOOL isModel = (strcmp(name, "hw.model") == 0);
        BOOL isTarget = (strcmp(name, "hw.target") == 0);
        
        if (isMachine || isModel || isTarget) {
            g_sysctlbyname_count++;
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
        }
    }
    return result;
}

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int result = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (namelen >= 2 && name[0] == CTL_HW && 
        (name[1] == HW_MACHINE || name[1] == 2)) {
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
    }
    return result;
}

int replaced_uname(struct utsname *name) {
    int result = original_uname(name);
    if (result == 0 && name != NULL) {
        strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
    }
    return result;
}

// ========== UIScreen hook ==========

static CGRect replaced_screen_bounds(id self, SEL _cmd) {
    return CGRectMake(0, 0, kSpoofedBounds.width, kSpoofedBounds.height);
}

static CGRect replaced_screen_nativeBounds(id self, SEL _cmd) {
    return CGRectMake(0, 0, kSpoofedNativeBounds.width, kSpoofedNativeBounds.height);
}

static CGFloat replaced_screen_scale(id self, SEL _cmd) {
    return kSpoofedScale;
}

static CGFloat replaced_screen_nativeScale(id self, SEL _cmd) {
    return kSpoofedNativeScale;
}

static id replaced_screen_currentMode(id self, SEL _cmd) {
    // 模拟一个 UIScreenMode 对象
    Class UIScreenModeClass = objc_getClass("UIScreenMode");
    id mode = [[UIScreenModeClass alloc] init];
    object_setInstanceVariable(mode, "_size", (void *)&kSpoofedModeSize);
    return mode;
}

// ========== UIDevice hook ==========

id replaced_uid_model(id self, SEL _cmd) {
    return [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
}

// ========== 诊断弹窗 ==========

static void showDiagnosticAlert() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *screen = [UIScreen mainScreen];
        CGRect bounds = screen.bounds;
        CGRect nativeBounds = CGRectZero;
        if ([screen respondsToSelector:@selector(nativeBounds)]) {
            nativeBounds = screen.nativeBounds;
        }
        CGSize modeSize = screen.currentMode.size;
        CGFloat scale = screen.scale;
        CGFloat nativeScale = screen.nativeScale;
        
        char machine[256];
        size_t len = sizeof(machine);
        sysctlbyname("hw.machine", machine, &len, NULL, 0);
        
        NSString *message = [NSString stringWithFormat:
            @"IB3DeviceSpoof v9 诊断 ✅\n"
            @"（iPhone X 伪装版 - 含屏幕）\n\n"
            @"伪装型号: %s\n"
            @"当前 hw.machine: %s\n"
            @"sysctlbyname 调用: %d 次\n\n"
            @"屏幕 bounds: %.0f x %.0f\n"
            @"nativeBounds: %.0f x %.0f\n"
            @"currentMode: %.0f x %.0f\n"
            @"scale: %.1f\n"
            @"nativeScale: %.1f",
            SPOOFED_DEVICE_MODEL,
            machine,
            g_sysctlbyname_count,
            bounds.size.width, bounds.size.height,
            nativeBounds.size.width, nativeBounds.size.height,
            modeSize.width, modeSize.height,
            scale,
            nativeScale];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Tweak v9.1 (iPhone X)"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"复制日志"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            UIPasteboard *pb = [UIPasteboard generalPasteboard];
            pb.string = message;
        }]];
        
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

__attribute__((constructor(CONSTRUCTOR_PRIORITY)))
static void ib3_spoof_initialize() {
    // Hook C 函数
    struct rebinding r1 = { .name = "sysctlbyname", .replacement = replaced_sysctlbyname, .replaced = (void **)&original_sysctlbyname };
    struct rebinding r2 = { .name = "sysctl", .replacement = replaced_sysctl, .replaced = (void **)&original_sysctl };
    struct rebinding r3 = { .name = "uname", .replacement = replaced_uname, .replaced = (void **)&original_uname };
    rebind_symbols((struct rebinding[]){r1, r2, r3}, 3);
    
    fprintf(stderr, "[IB3 v9] C hooks ready\n");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            // UIDevice model
            Class UIDeviceClass = objc_getClass("UIDevice");
            if (UIDeviceClass) {
                SEL modelSel = @selector(model);
                Method m = class_getInstanceMethod(UIDeviceClass, modelSel);
                if (m) {
                    original_uid_model = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_uid_model);
                }
            }
            
            // UIScreen hooks
            Class UIScreenClass = objc_getClass("UIScreen");
            if (UIScreenClass) {
                struct { SEL sel; IMP *original; IMP replacement; } hooks[] = {
                    { @selector(bounds), &original_screen_bounds, (IMP)replaced_screen_bounds },
                    { @selector(nativeBounds), &original_screen_nativeBounds, (IMP)replaced_screen_nativeBounds },
                    { @selector(scale), &original_screen_scale, (IMP)replaced_screen_scale },
                    { @selector(nativeScale), &original_screen_nativeScale, (IMP)replaced_screen_nativeScale },
                    { @selector(currentMode), &original_screen_currentMode, (IMP)replaced_screen_currentMode },
                };
                for (int i = 0; i < 5; i++) {
                    Method m = class_getInstanceMethod(UIScreenClass, hooks[i].sel);
                    if (m) {
                        *hooks[i].original = method_getImplementation(m);
                        method_setImplementation(m, hooks[i].replacement);
                    }
                }
            }
            
            NSLog(@"[IB3 v9] All hooks ready. Spoofing as %s", SPOOFED_DEVICE_MODEL);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnosticAlert();
            });
        }
    });
}