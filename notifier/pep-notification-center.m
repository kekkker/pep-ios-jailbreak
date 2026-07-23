#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>
#import <objc/runtime.h>

void *PEPCreateNotificationCenter(void) {
    Class centerClass = objc_getClass("UNUserNotificationCenter");
    SEL initializer = sel_registerName("initWithBundleIdentifier:");
    if (centerClass == Nil ||
        ![centerClass instancesRespondToSelector:initializer]) {
        return NULL;
    }

    id allocated = ((id (*)(id, SEL))objc_msgSend)(
        centerClass, sel_registerName("alloc"));
    id center = ((id (*)(id, SEL, id))objc_msgSend)(
        allocated, initializer, @"software.pEp.mail");
    return (__bridge_retained void *)center;
}
