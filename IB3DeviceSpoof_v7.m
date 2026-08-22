//
//  IB3DeviceSpoof_v7.m
//  无尽之剑3 设备型号欺骗 Tweak（全量日志诊断版）
//
//  目标：记录 ALL sysctlbyname 调用，看看游戏到底查了什么
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "fishhook.h"
#import <objc/runtime.h>

// ========== 配置 ==========

#define SPOOFED_DEVICE_MODEL "iPhone6,2"
#define CONSTRUCTOR_PRIORITY 101

// 最多记录多少条调用
#define MAX_LOG_ENTRIES 50

// ==========================

// 原始函数指针
static int (*original_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int (*original_uname)(struct utsname *name);

// 原始 ObjC IMP
static IMP original_uid_model = NULL;

// 调用日志
static int g_call_count = 0;

static struct {
    const char *name;
    char value[128];
    int ret;
} g_call_log[MAX_LOG_ENTRIES];

// ========== 记录调用 ==========

static void log_call(const char *name, const char *value, int ret) {
    if (g_call_count < MAX_LOG_ENTRIES && name != NULL) {
        g_call_log[g_call_count].name = name; // 注意：这是指针，可能失效
        if (value != NULL) {
            strncpy(g_call_log[g_call_count].value, value, 127);
            g_call_log[g_call_count].value[127] = '\0';
        } else {
            g_call_log[g_call_count].value[0] = '\0';
        }
        g_call_log[g_call_count].ret = ret;
        g_call_count++;
    }
}

// ========== sysctlbyname hook ==========

int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // 先调用原始函数
    int result = original_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    
    if (name == NULL) return result;
    
    // 检查是否是我们要替换的字段
    BOOL isMachine = (strcmp(name, "hw.machine") == 0);
    BOOL isModel = (strcmp(name, "hw.model") == 0);
    BOOL isTarget = (strcmp(name, "hw.target") == 0);
    
    // 替换
    if (isMachine || isModel || isTarget) {
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
    
    // 记录返回值
    char valueStr[256];
    if (oldp != NULL && oldlenp != NULL && *oldlenp > 0 && *oldlenp < sizeof(valueStr)) {
        // 判断是不是字符串
        BOOL isString = YES;
        const char *p = (const char *)oldp;
        for (size_t i = 0; i < *oldlenp - 1; i++) {
            if (p[i] < 0x20 || p[i] > 0x7E) {
                isString = NO;
                break;
            }
        }
        if (isString) {
            strncpy(valueStr, p, *oldlenp);
            valueStr[*oldlenp - 1] = '\0';
        } else {
            // 数字类型，打印前几个字节
            if (*oldlenp == 4) {
                uint32_t val = *(uint32_t *)oldp;
                snprintf(valueStr, sizeof(valueStr), "uint32: %u", val);
            } else if (*oldlenp == 8) {
                uint64_t val = *(uint64_t *)oldp;
                snprintf(valueStr, sizeof(valueStr), "uint64: %llu", (unsigned long long)val);
            } else {
                snprintf(valueStr, sizeof(valueStr), "[binary %zu bytes]", *oldlenp);
            }
        }
    } else if (oldlenp != NULL && oldp == NULL) {
        snprintf(valueStr, sizeof(valueStr), "[size query: %zu]", *oldlenp);
    } else {
        strcpy(valueStr, "(unknown)");
    }
    
    // 记录日志
    log_call(name, valueStr, result);
    
    // 同时用 NSLog 打印（方便看设备日志）
    // 只打印跟硬件相关的，避免刷屏
    if (strncmp(name, "hw.", 3) == 0 || 
        strncmp(name, "kern.", 5) == 0 ||
        strncmp(name, "machdep.", 8) == 0 ||
        strncmp(name, "debug.", 6) == 0) {
        NSLog(@"[IB3 v7] sysctlbyname: %s = %s (ret=%d)", name, valueStr, result);
    }
    
    return result;
}

// ========== sysctl hook ==========

int replaced_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int result = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    
    // CTL_HW = 6
    if (namelen >= 2 && name[0] == CTL_HW) {
        const char *fieldName = "hw.?";
        char fieldBuf[64];
        
        switch (name[1]) {
            case HW_MACHINE: fieldName = "hw.machine"; break;
            case HW_MODEL: fieldName = "hw.model"; break;
            case HW_NCPU: fieldName = "hw.ncpu"; break;
            case HW_PHYSMEM: fieldName = "hw.physmem"; break;
            case HW_USERMEM: fieldName = "hw.usermem"; break;
            case HW_MEMSIZE: fieldName = "hw.memsize"; break;
            default:
                snprintf(fieldBuf, sizeof(fieldBuf), "hw.%d", name[1]);
                fieldName = fieldBuf;
                break;
        }
        
        // 替换 machine/model
        if (name[1] == HW_MACHINE || name[1] == HW_MODEL) {
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
        
        // 记录
        char valStr[128] = "(null)";
        if (oldp != NULL && oldlenp != NULL && *oldlenp > 0) {
            if (*oldlenp < sizeof(valStr)) {
                // 试试当字符串
                BOOL isStr = YES;
                const char *p = (const char *)oldp;
                for (size_t i = 0; i < *oldlenp - 1; i++) {
                    if (p[i] < 0x20 || p[i] > 0x7E) { isStr = NO; break; }
                }
                if (isStr) {
                    strncpy(valStr, p, *oldlenp);
                    valStr[*oldlenp - 1] = '\0';
                } else if (*oldlenp == 4) {
                    snprintf(valStr, sizeof(valStr), "%u", *(uint32_t *)oldp);
                } else if (*oldlenp == 8) {
                    snprintf(valStr, sizeof(valStr), "%llu", (unsigned long long)*(uint64_t *)oldp);
                } else {
                    snprintf(valStr, sizeof(valStr), "[%zu bytes]", *oldlenp);
                }
            }
        }
        
        log_call(fieldName, valStr, result);
        NSLog(@"[IB3 v7] sysctl: %s = %s", fieldName, valStr);
    }
    
    return result;
}

// ========== uname hook ==========

int replaced_uname(struct utsname *name) {
    int result = original_uname(name);
    if (result == 0 && name != NULL) {
        NSLog(@"[IB3 v7] uname: sysname=%s release=%s version=%s machine=%s",
              name->sysname, name->release, name->version, name->machine);
        strlcpy(name->machine, SPOOFED_DEVICE_MODEL, sizeof(name->machine));
    }
    return result;
}

// ========== UIDevice model swizzle ==========

id replaced_uid_model(id self, SEL _cmd) {
    NSString *spoofed = [NSString stringWithUTF8String:SPOOFED_DEVICE_MODEL];
    NSLog(@"[IB3 v7] UIDevice model 被调用");
    return spoofed;
}

// ========== 生成诊断文本 ==========

static NSString *diagnosticText() {
    UIScreen *screen = [UIScreen mainScreen];
    CGRect bounds = screen.bounds;
    CGSize modeSize = screen.currentMode.size;
    CGRect nativeBounds = CGRectZero;
    
    // 尝试读取 nativeBounds
    if ([screen respondsToSelector:@selector(nativeBounds)]) {
        nativeBounds = screen.nativeBounds;
    }
    
    NSMutableString *text = [NSMutableString string];
    
    [text appendFormat:@"屏幕信息:\n"];
    [text appendFormat:@"  bounds: %.0f x %.0f\n", bounds.size.width, bounds.size.height];
    [text appendFormat:@"  currentMode: %.0f x %.0f\n", modeSize.width, modeSize.height];
    [text appendFormat:@"  scale: %.1f\n", screen.scale];
    [text appendFormat:@"  nativeBounds: %.0f x %.0f\n", nativeBounds.size.width, nativeBounds.size.height];
    [text appendFormat:@"  nativeScale: %.1f\n", screen.nativeScale];
    [text appendFormat:@"\n"];
    
    [text appendFormat:@"sysctlbyname 调用记录 (共 %d 次):\n", g_call_count];
    
    int displayCount = MIN(g_call_count, 15); // 弹框里显示前15条
    for (int i = 0; i < displayCount; i++) {
        [text appendFormat:@"  %d. %s → %s\n",
              i + 1,
              g_call_log[i].name,
              g_call_log[i].value];
    }
    
    if (g_call_count > 15) {
        [text appendFormat:@"  ... 还有 %d 条未显示\n", g_call_count - 15];
    }
    
    return text;
}

// ========== 诊断弹窗 ==========

static void showDiagnosticAlert() {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *message = diagnosticText();
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Tweak v7 全量诊断"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"复制日志"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            // 把完整日志复制到剪贴板
            UIPasteboard *pb = [UIPasteboard generalPasteboard];
            pb.string = diagnosticText();
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
    // 先 hook C 函数（越早越好）
    
    struct rebinding r1 = {
        .name = "sysctlbyname",
        .replacement = replaced_sysctlbyname,
        .replaced = (void **)&original_sysctlbyname
    };
    rebind_symbols(&r1, 1);
    
    struct rebinding r2 = {
        .name = "sysctl",
        .replacement = replaced_sysctl,
        .replaced = (void **)&original_sysctl
    };
    rebind_symbols(&r2, 1);
    
    struct rebinding r3 = {
        .name = "uname",
        .replacement = replaced_uname,
        .replaced = (void **)&original_uname
    };
    rebind_symbols(&r3, 1);
    
    fprintf(stderr, "[IB3 v7] C hooks ready\n");
    
    // ObjC 部分稍后做
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            Class UIDeviceClass = objc_getClass("UIDevice");
            if (UIDeviceClass) {
                SEL modelSel = @selector(model);
                Method m = class_getInstanceMethod(UIDeviceClass, modelSel);
                if (m) {
                    original_uid_model = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replaced_uid_model);
                    NSLog(@"[IB3 v7] UIDevice model swizzled");
                }
            }
            
            NSLog(@"[IB3 v7] All hooks ready");
            
            // 3 秒后弹窗
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showDiagnosticAlert();
            });
        }
    });
}
