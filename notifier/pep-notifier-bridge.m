#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kQueueDirectory =
    @"/var/mobile/Library/Caches/software.pep.notifier/queue";
static CFStringRef const kDarwinNotification =
    CFSTR("software.pep.notifier.new-bulletin");

static id notificationServer = nil;
static dispatch_queue_t notificationServerQueue = nil;
static BOOL serverHooksInstalled = NO;

typedef id (*InitWithQueueIMP)(id, SEL, id);
static InitWithQueueIMP originalInitWithQueue = NULL;

typedef id (*InitWithServicesIMP)(id, SEL, id, id, id, id, id, id, id, id, id);
static InitWithServicesIMP originalInitWithServices = NULL;

static void rememberServer(id server, id queue) {
    if (server != nil && queue != nil) {
        notificationServer = server;
        notificationServerQueue = (dispatch_queue_t)queue;
        NSLog(@"pep-notifier-bridge: captured persistent BBServer queue");
    }
}

static id replacementInitWithQueue(id self, SEL command, id queue) {
    id server = originalInitWithQueue(self, command, queue);
    rememberServer(server, queue);
    return server;
}

static id replacementInitWithServices(
    id self,
    SEL command,
    id queue,
    id dataProviderManager,
    id syncService,
    id dismissalSyncCache,
    id observerListener,
    id utilitiesListener,
    id conduitListener,
    id systemStateListener,
    id settingsListener) {
    id server = originalInitWithServices(
        self,
        command,
        queue,
        dataProviderManager,
        syncService,
        dismissalSyncCache,
        observerListener,
        utilitiesListener,
        conduitListener,
        systemStateListener,
        settingsListener);
    rememberServer(server, queue);
    return server;
}

static void installServerHooks(void) {
    @synchronized(NSProcessInfo.processInfo) {
        if (serverHooksInstalled) {
            return;
        }

        Class serverClass = objc_getClass("BBServer");
        if (serverClass == Nil) {
            return;
        }

        Method simpleInitializer = class_getInstanceMethod(
            serverClass, sel_registerName("initWithQueue:"));
        if (simpleInitializer != NULL) {
            originalInitWithQueue = (InitWithQueueIMP)method_setImplementation(
                simpleInitializer, (IMP)replacementInitWithQueue);
        }

        SEL servicesSelector = sel_registerName(
            "initWithQueue:dataProviderManager:syncService:dismissalSyncCache:"
            "observerListener:utilitiesListener:conduitListener:"
            "systemStateListener:settingsListener:");
        Method servicesInitializer =
            class_getInstanceMethod(serverClass, servicesSelector);
        if (servicesInitializer != NULL) {
            originalInitWithServices =
                (InitWithServicesIMP)method_setImplementation(
                    servicesInitializer, (IMP)replacementInitWithServices);
        }

        serverHooksInstalled =
            originalInitWithQueue != NULL || originalInitWithServices != NULL;
        if (serverHooksInstalled) {
            NSLog(@"pep-notifier-bridge: installed persistent BBServer hooks");
        } else {
            NSLog(@"pep-notifier-bridge: no supported BBServer initializer found");
        }
    }
}

static void setObject(id object, const char *setterName, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(
        object, sel_registerName(setterName), value);
}

static void setBool(id object, const char *setterName, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        object, sel_registerName(setterName), value);
}

static BOOL publishPersistentBulletin(
    NSString *title, NSString *message, NSString *bundleID) {
    if (notificationServer == nil || notificationServerQueue == nil) {
        NSLog(@"pep-notifier-bridge: persistent BBServer unavailable");
        return NO;
    }

    Class bulletinClass = objc_getClass("BBBulletin");
    Class actionClass = objc_getClass("BBAction");
    if (bulletinClass == Nil || actionClass == Nil) {
        NSLog(@"pep-notifier-bridge: BulletinBoard classes unavailable");
        return NO;
    }

    NSString *identifier = NSProcessInfo.processInfo.globallyUniqueString;
    NSDate *now = NSDate.date;
    id bulletin = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(bulletinClass, sel_registerName("alloc")),
        sel_registerName("init"));

    setObject(bulletin, "setBulletinID:", identifier);
    setObject(bulletin, "setRecordID:", identifier);
    setObject(bulletin, "setPublisherBulletinID:", identifier);
    setObject(bulletin, "setSectionID:", bundleID);
    setObject(bulletin, "setTitle:", title);
    setObject(bulletin, "setMessage:", message);
    setObject(bulletin, "setDate:", now);
    setObject(bulletin, "setPublicationDate:", now);
    setObject(bulletin, "setLastInterruptDate:", now);
    setBool(bulletin, "setClearable:", YES);
    if ([bulletin respondsToSelector:sel_registerName("setShowsMessagePreview:")]) {
        setBool(bulletin, "setShowsMessagePreview:", YES);
    }

    id action = ((id (*)(id, SEL, id, id))objc_msgSend)(
        actionClass,
        sel_registerName("actionWithLaunchBundleID:callblock:"),
        bundleID,
        nil);
    setObject(bulletin, "setDefaultAction:", action);

    SEL publishSelector =
        sel_registerName("publishBulletin:destinations:");
    SEL alternateSelector = sel_registerName(
        "publishBulletin:destinations:alwaysToLockScreen:");
    __block BOOL published = NO;
    dispatch_sync(notificationServerQueue, ^{
        if ([notificationServer respondsToSelector:publishSelector]) {
            ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(
                notificationServer, publishSelector, bulletin, 14);
            published = YES;
        } else if ([notificationServer respondsToSelector:alternateSelector]) {
            ((void (*)(id, SEL, id, unsigned long long, BOOL))objc_msgSend)(
                notificationServer, alternateSelector, bulletin, 14, NO);
            published = YES;
        }
    });

    if (published) {
        NSLog(@"pep-notifier-bridge: published persistent pEp bulletin %@", identifier);
    } else {
        NSLog(@"pep-notifier-bridge: no supported BBServer publish selector");
    }
    return published;
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

    if (notificationServer == nil || notificationServerQueue == nil) {
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

        if (publishPersistentBulletin(title, message, bundleID)) {
            [fm removeItemAtPath:path error:nil];
        }
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

static void imageLoaded(
    const struct mach_header *header, intptr_t vmAddressSlide) {
    installServerHooks();
}

__attribute__((constructor))
static void initializePEPNotifierBridge(void) {
    @autoreleasepool {
        installServerHooks();
        _dyld_register_func_for_add_image(imageLoaded);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            notificationReceived,
            kDarwinNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
            @autoreleasepool {
                drainQueue();
            }
        });
    }
}
