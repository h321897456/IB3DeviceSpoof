#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#import "fishhook.h"

// ========== 屏幕伪装参数（iPhone X）==========
static CGSize kSpoofedBoundsSize = (CGSize){667.0, 375.0};       // bounds
static CGSize kSpoofedNativeSize = (CGSize){2001.0, 1125.0};    // nativeBounds
static CGSize kSpoofedModeSize = (CGSize){2001.0, 1125.0};      // currentMode

// ========== UIScreen Hook ==========
static CGRect (*orig_UIScreen_bounds)(id, SEL);
static CGRect hooked_UIScreen_bounds(id self, SEL _cmd) {
    CGRect rect = orig_UIScreen_bounds(self, _cmd);
    rect.size = kSpoofedBoundsSize;
    return rect;
}

static CGRect (*orig_UIScreen_nativeBounds)(id, SEL);
static CGRect hooked_UIScreen_nativeBounds(id self, SEL _cmd) {
    CGRect rect = orig_UIScreen_nativeBounds(self, _cmd);
    rect.size = kSpoofedNativeSize;
    return rect;
}

static CGFloat (*orig_UIScreen_scale)(id, SEL);
static CGFloat hooked_UIScreen_scale(id self, SEL _cmd) {
    return 3.0;
}

static CGFloat (*orig_UIScreen_nativeScale)(id, SEL);
static CGFloat hooked_UIScreen_nativeScale(id self, SEL _cmd) {
    return 3.0;
}

static id (*orig_UIScreen_currentMode)(id, SEL);
static id hooked_UIScreen_currentMode(id self, SEL _cmd) {
    id mode = orig_UIScreen_currentMode(self, _cmd);
    if (mode) {
        // 用 KVC 修改 size，兼容 ARC
        NSValue *sizeValue = [NSValue valueWithCGSize:kSpoofedModeSize];
        [mode setValue:sizeValue forKey:@"size"];
    }
    return mode;
}

// ========== UIWindow Hook（获取设备型号）==========
static NSString *(*orig_UIDevice_model)(id, SEL);
static NSString *hooked_UIDevice_model(id self, SEL _cmd) {
    return @"iPhone";
}

static NSString *(*orig_UIDevice_systemName)(id, SEL);
static NSString *hooked_UIDevice_systemName(id self, SEL _cmd) {
    return @"iOS";
}

static NSString *(*orig_UIDevice_systemVersion)(id, SEL);
static NSString *hooked_UIDevice_systemVersion(id self, SEL _cmd) {
    return @"11.0";
}

// ========== 弹窗确认 ==========
static void showConfirmation() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
            for (UIScene *scene in scenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    window = ((UIWindowScene *)scene).windows.firstObject;
                    break;
                }
            }
        }
        if (!window) {
            window = [UIApplication sharedApplication].delegate.window;
        }
        if (!window) {
            window = [[UIApplication sharedApplication].windows firstObject];
        }

        UIViewController *rootVC = window.rootViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"✅ 这是 V10 新版！"
                                                                         message:[NSString stringWithFormat:
             @"UIScreen 伪装已生效\n\nbounds: %.0f x %.0f\nnativeBounds: %.0f x %.0f\nscale: 3.0\nnativeScale: 3.0\n\nModel: %@\nSystem: %@ %@",
             kSpoofedBoundsSize.width, kSpoofedBoundsSize.height,
             kSpoofedNativeSize.width, kSpoofedNativeSize.height,
             hooked_UIDevice_model(nil, nil),
             hooked_UIDevice_systemName(nil, nil),
             hooked_UIDevice_systemVersion(nil, nil)]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

// ========== 初始化 ==========
__attribute__((constructor))
static void initSpoof() {
    // UIScreen 5个方法全部 Hook
    rebind_symbols((struct rebinding[]){
        {"bounds", hooked_UIScreen_bounds, (void *)&orig_UIScreen_bounds},
        {"nativeBounds", hooked_UIScreen_nativeBounds, (void *)&orig_UIScreen_nativeBounds},
        {"scale", hooked_UIScreen_scale, (void *)&orig_UIScreen_scale},
        {"nativeScale", hooked_UIScreen_nativeScale, (void *)&orig_UIScreen_nativeScale},
        {"currentMode", hooked_UIScreen_currentMode, (void *)&orig_UIScreen_currentMode},
    }, 5);

    // UIDevice 信息伪装
    rebind_symbols((struct rebinding[]){
        {"model", hooked_UIDevice_model, (void *)&orig_UIDevice_model},
        {"systemName", hooked_UIDevice_systemName, (void *)&orig_UIDevice_systemName},
        {"systemVersion", hooked_UIDevice_systemVersion, (void *)&orig_UIDevice_systemVersion},
    }, 3);

    // 弹窗
    showConfirmation();
}
