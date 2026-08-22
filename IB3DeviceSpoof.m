//
//  IB3DeviceSpoof.m
//  无尽之剑3 设备型号欺骗 Tweak
//
//  原理：使用 fishhook hook sysctlbyname，
//  当游戏询问 hw.machine 设备型号时，
//  返回高端设备型号，让 UE3 使用高画质/全屏预设
//

#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import "fishhook.h"

// 伪装的设备型号
// iPhone6,2 = iPhone 5S（首款 64-bit iPhone，UE3 肯定认识且归为高端）
#define SPOOFED_DEVICE_MODEL "iPhone6,2"

// 保存原始 sysctlbyname 函数指针
static int (*original_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

// 我们的替换函数
int replaced_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // 只拦截 hw.machine 的查询
    if (name != NULL && strcmp(name, "hw.machine") == 0) {
        if (oldp != NULL && oldlenp != NULL) {
            // 返回伪装的型号
            size_t needed = strlen(SPOOFED_DEVICE_MODEL) + 1;
            if (*oldlenp >= needed) {
                strlcpy((char *)oldp, SPOOFED_DEVICE_MODEL, *oldlenp);
                *oldlenp = needed;
                return 0; // 成功
            } else {
                // 缓冲区不够，返回需要的大小
                *oldlenp = needed;
                errno = ENOMEM;
                return -1;
            }
        } else if (oldlenp != NULL) {
            // 只查询所需大小
            *oldlenp = strlen(SPOOFED_DEVICE_MODEL) + 1;
            return 0;
        }
    }
    
    // 其他查询走原始函数
    return original_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// 构造函数：dylib 加载时自动执行
__attribute__((constructor))
static void ib3_spoof_initialize() {
    @autoreleasepool {
        NSLog(@"[IB3DeviceSpoof] 加载中...");
        
        // 设置 hook
        struct rebinding sysctl_rebinding;
        sysctl_rebinding.name = "sysctlbyname";
        sysctl_rebinding.replacement = replaced_sysctlbyname;
        sysctl_rebinding.replaced = (void **)&original_sysctlbyname;
        
        int result = rebind_symbols(&sysctl_rebinding, 1);
        
        if (result == 0) {
            NSLog(@"[IB3DeviceSpoof] Hook 成功，设备型号将伪装为: %s", SPOOFED_DEVICE_MODEL);
        } else {
            NSLog(@"[IB3DeviceSpoof] Hook 失败，错误码: %d", result);
        }
    }
}
