#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const PEPQueueDirectory =
    @"/var/mobile/Library/Caches/software.pep.notifier/queue-v2";
static CFStringRef const PEPQueueChangedNotification =
    CFSTR("software.pep.notification-poster.queue-changed.v2");

static UNUserNotificationCenter *PEPNotificationCenter = nil;
static NSMutableSet<NSString *> *PEPProcessingPaths = nil;
static BOOL PEPAuthorized = NO;

static void PEPLog(NSString *message) {
    fprintf(stderr, "pep-notification-poster: %s\n", message.UTF8String);
    fflush(stderr);
}

static UNUserNotificationCenter *PEPCreateNotificationCenter(void) {
    Class centerClass = objc_getClass("UNUserNotificationCenter");
    SEL initializer = sel_registerName("initWithBundleIdentifier:");
    if (centerClass == Nil ||
        ![centerClass instancesRespondToSelector:initializer]) {
        return nil;
    }

    id allocated = ((id (*)(id, SEL))objc_msgSend)(
        centerClass, sel_registerName("alloc"));
    return ((id (*)(id, SEL, id))objc_msgSend)(
        allocated, initializer, @"software.pEp.mail");
}

static void PEPDrainQueue(void) {
    if (!PEPAuthorized || PEPNotificationCenter == nil) {
        return;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *files =
        [[fileManager contentsOfDirectoryAtPath:PEPQueueDirectory error:nil]
            sortedArrayUsingSelector:@selector(compare:)];

    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"plist"]) {
            continue;
        }

        NSString *path =
            [PEPQueueDirectory stringByAppendingPathComponent:file];
        if ([PEPProcessingPaths containsObject:path]) {
            continue;
        }

        NSDictionary *payload =
            [NSDictionary dictionaryWithContentsOfFile:path];
        NSString *title = payload[@"title"];
        NSString *message = payload[@"message"];
        if (![title isKindOfClass:NSString.class] ||
            ![message isKindOfClass:NSString.class] ||
            title.length == 0 || message.length == 0) {
            [fileManager removeItemAtPath:path error:nil];
            continue;
        }

        UNMutableNotificationContent *content =
            [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = message;
        content.sound = UNNotificationSound.defaultSound;
        content.interruptionLevel = UNNotificationInterruptionLevelActive;

        NSString *identifier =
            [NSString stringWithFormat:@"pep-mail-%@",
                [[NSUUID UUID] UUIDString]];
        UNNotificationRequest *request =
            [UNNotificationRequest requestWithIdentifier:identifier
                                                 content:content
                                                 trigger:nil];
        [PEPProcessingPaths addObject:path];
        [PEPNotificationCenter
            addNotificationRequest:request
            withCompletionHandler:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error == nil) {
                        [fileManager removeItemAtPath:path error:nil];
                        PEPLog([NSString stringWithFormat:
                            @"stored %@ with usernotificationsd", identifier]);
                    } else {
                        PEPLog([NSString stringWithFormat:
                            @"delivery failed; payload retained: %@",
                            error.localizedDescription]);
                    }
                    [PEPProcessingPaths removeObject:path];
                });
            }];
    }
}

static void PEPQueueChanged(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PEPDrainQueue();
    });
}

int main(int argc, char **argv) {
    @autoreleasepool {
        PEPProcessingPaths = [[NSMutableSet alloc] init];
        PEPNotificationCenter = PEPCreateNotificationCenter();
        if (PEPNotificationCenter == nil) {
            PEPLog(@"explicit pEp notification center is unavailable");
            return 75;
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            PEPQueueChanged,
            PEPQueueChangedNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        [PEPNotificationCenter
            getNotificationSettingsWithCompletionHandler:
                ^(UNNotificationSettings *settings) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        PEPAuthorized =
                            settings.authorizationStatus ==
                            UNAuthorizationStatusAuthorized;
                        PEPLog([NSString stringWithFormat:
                            @"authorization status %ld",
                            (long)settings.authorizationStatus]);
                        if (PEPAuthorized) {
                            PEPDrainQueue();
                        }
                    });
                }];

        [NSRunLoop.mainRunLoop run];
    }
    return 0;
}
