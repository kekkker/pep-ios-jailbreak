#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kQueueDirectory =
    @"/var/mobile/Library/Caches/software.pep.notifier/queue";
static CFStringRef const kDarwinNotification =
    CFSTR("software.pep.notifier.new-bulletin");

static id sendSharedInstance(Class managerClass) {
    SEL selector = sel_registerName("sharedInstance");
    return ((id (*)(id, SEL))objc_msgSend)(managerClass, selector);
}

static void showBulletin(id manager, NSString *title, NSString *message,
                         NSString *bundleID) {
    SEL selector = sel_registerName("showBulletinWithTitle:message:bundleID:");
    ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        manager, selector, title, message, bundleID);
}

static void drainQueue(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listError = nil;
    NSArray<NSString *> *files =
        [[fm contentsOfDirectoryAtPath:kQueueDirectory error:&listError]
            sortedArrayUsingSelector:@selector(compare:)];
    if (files == nil) {
        return;
    }

    Class managerClass = objc_getClass("JBBulletinManager");
    if (managerClass == Nil) {
        NSLog(@"pep-notifier-bridge: libbulletin manager unavailable");
        return;
    }
    id manager = sendSharedInstance(managerClass);
    if (manager == nil) {
        NSLog(@"pep-notifier-bridge: libbulletin manager not initialized");
        return;
    }

    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"plist"]) {
            continue;
        }
        NSString *path = [kQueueDirectory stringByAppendingPathComponent:file];
        NSDictionary *payload = [NSDictionary dictionaryWithContentsOfFile:path];
        NSString *title = payload[@"title"];
        NSString *message = payload[@"message"];
        NSString *bundleID = payload[@"bundle_id"];
        if (![title isKindOfClass:NSString.class] ||
            ![message isKindOfClass:NSString.class] ||
            ![bundleID isKindOfClass:NSString.class] ||
            title.length == 0 || message.length == 0 || bundleID.length == 0) {
            [fm removeItemAtPath:path error:nil];
            continue;
        }

        showBulletin(manager, title, message, bundleID);
        [fm removeItemAtPath:path error:nil];
    }
}

static void notificationReceived(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            drainQueue();
        }
    });
}

__attribute__((constructor))
static void initializePEPNotifierBridge(void) {
    @autoreleasepool {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            notificationReceived,
            kDarwinNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                drainQueue();
            }
        });
    }
}
