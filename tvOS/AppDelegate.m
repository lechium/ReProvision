//
//  AppDelegate.m
//  tvOS
//
//  Created by Matt Clarke on 07/08/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "AppDelegate.h"
#import "RPVResources.h"
#import "RPVNotificationManager.h"
#import "RPVBackgroundSigningManager.h"
#import "RPVResources.h"

#import "RPVIpaBundleApplication.h"
#import "RPVApplicationDetailController.h"

#import "RPVDaemonProtocol.h"
#import "RPVApplicationProtocol.h"

#import "SAMKeychain.h"

#import <objc/runtime.h>
#include <notify.h>

#import "RPVTabBarController.h"
#import "UIViewController+Additions.h"

typedef enum : NSUInteger {
    SDAirDropDiscoverableModeOff,
    SDAirDropDiscoverableModeContactsOnly,
    SDAirDropDiscoverableModeEveryone,
} SDAirDropDiscoverableMode;

@interface SFAirDropDiscoveryController: UIViewController
- (void)setDiscoverableMode:(NSInteger)mode;
@end;

@interface PSAppDataUsagePolicyCache : NSObject
+ (id)sharedInstance;
- (bool)setUsagePoliciesForBundle:(id)arg1 cellular:(bool)arg2 wifi:(bool)arg3;
@end

@interface AppWirelessDataUsageManager : NSObject
+(void)setAppCellularDataEnabled:(id)arg1 forBundleIdentifier:(id)arg2 completionHandler:(/*^block*/ id)arg3 ;
+(void)setAppWirelessDataOption:(id)arg1 forBundleIdentifier:(id)arg2 completionHandler:(/*^block*/ id)arg3 ;
@end

@interface AppDelegate ()

@property (nonatomic, strong) NSXPCConnection *daemonConnection;
@property (nonatomic, strong) id discoveryController;

@property (nonatomic, readwrite) BOOL applicationIsActive;
@property (nonatomic, readwrite) BOOL pendingDaemonConnectionAlert;

@end

@interface NSXPCConnection (Private)
- (id)initWithMachServiceName:(NSString*)arg1;
@end

@implementation AppDelegate

- (void)setupFileLogging {
    
    [DDLog addLogger:[DDASLLogger sharedInstance]];
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
    NSString *dir = @"/var/mobile/Library/Caches/com.nito.ReProvision/Logs";
    
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    
    DDLogFileManagerDefault *manager = [[DDLogFileManagerDefault alloc] initWithLogsDirectory:dir];
    DDFileLogger *fileLogger = [[DDFileLogger alloc] initWithLogFileManager:manager];
    fileLogger.rollingFrequency = 60 * 60 * 24; // 24 hour rolling
    fileLogger.logFileManager.maximumNumberOfLogFiles = 7;
    [DDLog addLogger:fileLogger];
    
}

- (void)processPath:(NSString *)path  {
    
    //NSString *path = [url path];
    NSString *fileName = path.lastPathComponent;
    NSFileManager *man = [NSFileManager defaultManager];
    NSString *adFolder = [NSHomeDirectory() stringByAppendingPathComponent:@"AirDrop"];
    if (![man fileExistsAtPath:adFolder]){
        [man createDirectoryAtPath:adFolder withIntermediateDirectories:TRUE attributes:nil error:nil];
    }
    NSString *attemptCopy = [[NSHomeDirectory() stringByAppendingPathComponent:@"AirDrop"] stringByAppendingPathComponent:fileName];
    DDLogInfo(@"attempted path: %@", attemptCopy);
    NSError *error = nil;
    [[NSFileManager defaultManager] copyItemAtPath:path toPath:attemptCopy error:&error];

    if ([@[@"ipa"] containsObject:[[path pathExtension] lowercaseString]]){
        RPVIpaBundleApplication *ipaApplication = [[RPVIpaBundleApplication alloc] initWithIpaURL:[NSURL fileURLWithPath:attemptCopy]];
        
        RPVApplicationDetailController *detailController = [[RPVApplicationDetailController alloc] initWithApplication:ipaApplication];
        
        // Update with current states.
        [detailController setButtonTitle:@"INSTALL"];
        detailController.lockWhenInstalling = YES;
        
        // Add to the rootViewController of the application, as an effective overlay.
        detailController.view.alpha = 0.0;
        
        UIViewController *rootController = [UIApplication sharedApplication].keyWindow.rootViewController;
        
        
        
        if ([rootController isKindOfClass:RPVTabBarController.class]){
            RPVTabBarController *tbc = (RPVTabBarController *)rootController;
            NSArray *vcs = [tbc viewControllers];
            if (vcs.count > 0){
                UIViewController *vc = vcs[0];
                if ([vc respondsToSelector:@selector(disableViewAndRefocus)]){
                    [vc disableViewAndRefocus];
                }
            }
        }
        
        DDLogInfo(@"ROOT VIEW CONTROLLER: %@", rootController);
        
        [rootController addChildViewController:detailController];
        [rootController.view addSubview:detailController.view];
        
        detailController.view.frame = rootController.view.bounds;
        
        // Animate in!
        [detailController animateForPresentation];
        
    }
    
    
    
}

- (void)airDropReceived:(NSNotification *)n {
    
    NSDictionary *userInfo = [n userInfo];
    NSArray <NSString *>*items = userInfo[@"Items"];
    DDLogInfo(@"airdropped Items: %@", items);
    if (items.count > 1){
        
        DDLogInfo(@"please one at a time!");
        [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"One at a time please" body:@"Currently it is only possible to AirDrop one IPA at a time" isDebugMessage:FALSE isUrgentMessage:TRUE andNotificationID:nil];
    }
    
    [self processPath:items[0]];
    
    //TODO: some kind of a NSOperationQueue or something...
    
    /*
    [items enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        
        [self processPath:obj];
        
    }];
    */
    
}

- (void)disableAirDrop {
    
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:@"com.nito.AirDropper/airDropFileReceived" object:nil];
    [self.discoveryController setDiscoverableMode:SDAirDropDiscoverableModeOff];
    
}

- (void)setupAirDrop {
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(airDropReceived:) name:@"com.nito.AirDropper/airDropFileReceived" object:nil];
    self.discoveryController = [[NSClassFromString(@"SFAirDropDiscoveryController") alloc] init] ;
    [self.discoveryController setDiscoverableMode:SDAirDropDiscoverableModeEveryone];
    
}

- (void)setupChinaApplicationNetworkAccess {
    // See: https://github.com/pwn20wndstuff/Undecimus/issues/136
    
    NSOperatingSystemVersion version;
    version.majorVersion = 12;
    version.minorVersion = 0;
    version.patchVersion = 0;
    
    if (objc_getClass("PSAppDataUsagePolicyCache")) {
        // iOS 12+
        PSAppDataUsagePolicyCache *cache = [objc_getClass("PSAppDataUsagePolicyCache") sharedInstance];
        [cache setUsagePoliciesForBundle:[NSBundle mainBundle].bundleIdentifier cellular:YES wifi:YES];
    } else if (objc_getClass("AppWirelessDataUsageManager")) {
        // iOS 10 - 11
        [objc_getClass("AppWirelessDataUsageManager") setAppWirelessDataOption:[NSNumber numberWithInt:3]
                                                           forBundleIdentifier:[NSBundle mainBundle].bundleIdentifier completionHandler:nil];
        [objc_getClass("AppWirelessDataUsageManager") setAppCellularDataEnabled:[NSNumber numberWithInt:1]
                                                            forBundleIdentifier:[NSBundle mainBundle].bundleIdentifier completionHandler:nil];
    }
    // Not required for iOS 9
}

- (void)loadUIFrameworkIfNecessary {
    
    NSString *suf = @"/System/Library/PrivateFrameworks/SharingUI.framework";
    if ([[NSFileManager defaultManager] fileExistsAtPath:suf]){
        NSBundle *sharingUI = [NSBundle bundleWithPath:suf];
        [sharingUI load];
    }
    
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    [self loadUIFrameworkIfNecessary];
    [self setupFileLogging];
    [self setupAirDrop];
    
    // Override point for customization after application launch.
    [[RPVApplicationSigning sharedInstance] addSigningUpdatesObserver:self];
    
    // Register to send notifications
    [[RPVNotificationManager sharedInstance] registerToSendNotifications];
    
    // Register for background signing notifications.
    [self _setupDameonConnection];
    
    // Ensure Chinese devices have internet access
    [self setupChinaApplicationNetworkAccess];
    
    // Setup Keychain accessibility for when locked.
    // (prevents not being able to correctly read the passcode when the device is locked)
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlock];
    
    DDLogInfo(@"*** [ReProvision] :: applicationDidFinishLaunching, options: %@", launchOptions);
    NSString *suf = @"/System/Library/PrivateFrameworks/SharingUI.framework";
    if ([[NSFileManager defaultManager] fileExistsAtPath:suf]){
        NSBundle *sharingUI = [NSBundle bundleWithPath:suf];
        [sharingUI load];
    }
    
    
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // nop
    self.applicationIsActive = NO;

}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Launched in background by daemon, or when exiting the application.
    DDLogInfo(@"*** [ReProvision] :: applicationDidEnterBackground");
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // nop
    DDLogInfo(@"*** [ReProvision] :: applicationWillEnterForeground");
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    // nop
    DDLogInfo(@"*** [ReProvision] :: applicationDidBecomeActive");
    
    self.applicationIsActive = YES;
    if (self.pendingDaemonConnectionAlert) {
        [self _notifyDaemonFailedToConnect];
        self.pendingDaemonConnectionAlert = NO;
    }

}

- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


//////////////////////////////////////////////////////////////////////////////////
// Application Signing delegate methods.
//////////////////////////////////////////////////////////////////////////////////

- (void)applicationSigningDidStart {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.matchstic.reprovision/signingInProgress" object:nil];
    DDLogInfo(@"Started signing...");
}

- (void)applicationSigningUpdateProgress:(int)percent forBundleIdentifier:(NSString *)bundleIdentifier {
    DDLogInfo(@"'%@' at %d%%", bundleIdentifier, percent);
    
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:bundleIdentifier forKey:@"bundleIdentifier"];
    [userInfo setObject:[NSNumber numberWithInt:percent] forKey:@"percent"];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.matchstic.reprovision/signingUpdate" object:nil userInfo:userInfo];
    
    switch (percent) {
        case 100:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Success" body:[NSString stringWithFormat:@"Signed '%@'", bundleIdentifier] isDebugMessage:NO isUrgentMessage:YES andNotificationID:nil];
            break;
        case 10:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Started signing routine for '%@'", bundleIdentifier] isDebugMessage:YES andNotificationID:nil];
            break;
        case 50:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Wrote signatures for bundle '%@'", bundleIdentifier] isDebugMessage:YES andNotificationID:nil];
            break;
        case 60:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Rebuilt IPA for bundle '%@'", bundleIdentifier] isDebugMessage:YES andNotificationID:nil];
            break;
        case 90:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Installing IPA for bundle '%@'", bundleIdentifier] isDebugMessage:YES andNotificationID:nil];
            break;
            
        default:
            break;
    }
}

- (void)applicationSigningDidEncounterError:(NSError *)error forBundleIdentifier:(NSString *)bundleIdentifier {
    DDLogInfo(@"'%@' had error: %@", bundleIdentifier, error);
    [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Error" body:[NSString stringWithFormat:@"For '%@'\n%@", bundleIdentifier, error.localizedDescription] isDebugMessage:NO isUrgentMessage:YES andNotificationID:nil];
    
    // Ensure the UI goes back to when signing was not occuring
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:bundleIdentifier forKey:@"bundleIdentifier"];
    [userInfo setObject:[NSNumber numberWithInt:100] forKey:@"percent"];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.matchstic.reprovision/signingUpdate" object:nil userInfo:userInfo];
}

- (void)applicationSigningCompleteWithError:(NSError *)error {
    DDLogInfo(@"Completed signing, with error: %@", error);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.matchstic.reprovision/signingComplete" object:nil];
    
    // Display any errors if needed.
    if (error) {
        switch (error.code) {
            case RPVErrorNoSigningRequired:
                [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Success" body:@"No applications require signing at this time" isDebugMessage:NO isUrgentMessage:NO andNotificationID:nil];
                break;
            default:
                [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Error" body:error.localizedDescription isDebugMessage:NO isUrgentMessage:YES andNotificationID:nil];
                break;
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Automatic application signing
///////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)_setupDameonConnection {
#if TARGET_OS_SIMULATOR
    return;
#endif
    
    if (self.daemonConnection) {
        [self.daemonConnection invalidate];
        self.daemonConnection = nil;
    }
    self.daemonConnection = [[NSXPCConnection alloc] initWithMachServiceName:@"com.matchstic.reprovisiond"];
    self.daemonConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RPVDaemonProtocol)];
    
    self.daemonConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RPVApplicationProtocol)];
    self.daemonConnection.exportedObject = self;
    
    [self.daemonConnection resume];
    
    // Handle connection errors
    __weak AppDelegate *weakSelf = self;
    self.daemonConnection.interruptionHandler = ^{
        NSLog(@"interruption handler called");
        
        [weakSelf.daemonConnection invalidate];
        weakSelf.daemonConnection = nil;
        
        // Notify of failed connection
        [weakSelf _notifyDaemonFailedToConnect];

    };
    self.daemonConnection.invalidationHandler = ^{
        
        NSLog(@"invalidation handler called");
        
        [weakSelf.daemonConnection invalidate];
        weakSelf.daemonConnection = nil;
        
        // Re-create connection
        [weakSelf _setupDameonConnection];
    };
    
    // Notify daemon that we've now launched
    @try {
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
            NSLog(@"%@", error);
            
            if (error.code == NSXPCConnectionInvalid) {
                [weakSelf _notifyDaemonFailedToConnect];
            }
        }] applicationDidLaunch];
        
    } @catch (NSException *e) {
        [self _notifyDaemonFailedToConnect];
        return;
    }

    DDLogInfo(@"*** [ReProvision] :: Setup daemon connection: %@", self.daemonConnection);
}

- (void)_notifyDaemonFailedToConnect {
    if (!self.applicationIsActive) {
        self.pendingDaemonConnectionAlert = YES;
        return;
    }
    
    // That's not good...
    UIAlertController *av = [UIAlertController alertControllerWithTitle:@"Error" message:@"Could not connect to daemon; automatic background signing is disabled.\n\nPlease reinstall ReProvision, or reboot your device." preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *action = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {}];
    [av addAction:action];
    
    [self.window.rootViewController presentViewController:av animated:YES completion:nil];
    
    NSLog(@"*** [ReProvision] :: ERROR :: Failed to setup daemon connection: %@", self.daemonConnection);
}



- (void)_notifyDaemonOfMessageHandled {
    // Let the daemon know to release the background assertion.
    @try {
        [[self.daemonConnection remoteObjectProxy] applicationDidFinishTask];
    } @catch (NSException *e) {
        // Error previous shown
    }

}


- (void)daemonDidRequestNewBackgroundSigning {
    DDLogInfo(@"*** [ReProvision] :: daemonDidRequestNewBackgroundSigning");
    
    // Start a background sign
    UIApplication *application = [UIApplication sharedApplication];
    UIBackgroundTaskIdentifier __block bgTask = [application beginBackgroundTaskWithName:@"ReProvision Background Signing" expirationHandler:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
        
        [self performSelector:@selector(_notifyDaemonOfMessageHandled) withObject:nil afterDelay:5];
    }];
    
    [[RPVBackgroundSigningManager sharedInstance] attemptBackgroundSigningIfNecessary:^{
        // Ask to remove our process assertion 5 seconds later, so that we can assume any notifications
        // have been scheduled.
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self _notifyDaemonOfMessageHandled];
            
            // Done, so stop this background task.
            [application endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        });
    }];
}

- (void)daemonDidRequestCredentialsCheck {
    DDLogInfo(@"*** [ReProvision] :: daemonDidRequestCredentialsCheck");
    
    // Check that user credentials exist, notify if not
    if (![RPVResources getUsername] || [[RPVResources getUsername] isEqualToString:@""] || ![RPVResources getPassword] || [[RPVResources getPassword] isEqualToString:@""]) {
        
        [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Login Required" body:@"Tap to login to ReProvision. This is needed to re-sign applications." isDebugMessage:NO isUrgentMessage:YES andNotificationID:@"login"];
        
        // Ask to remove our process assertion 5 seconds later, so that we can assume any notifications
        // have been scheduled.
        [self performSelector:@selector(_notifyDaemonOfMessageHandled) withObject:nil afterDelay:5];
    } else {
        // Nothing to do, just notify that we're done.
        [self _notifyDaemonOfMessageHandled];
    }
}

- (void)daemonDidRequestQueuedNotification {
    DDLogInfo(@"*** [ReProvision] :: daemonDidRequestQueuedNotification");
    
    // Check if any applications need resigning. If they do, show notifications as appropriate.
    
    if ([[RPVBackgroundSigningManager sharedInstance] anyApplicationsNeedingResigning]) {
        [self _sendBackgroundedNotificationWithTitle:@"Re-signing Queued" body:@"Unlock your device to resign applications." isDebug:NO isUrgent:YES withNotificationID:@"resignQueued"];
    } else {
        [self _sendBackgroundedNotificationWithTitle:@"DEBUG" body:@"Background check has been queued for next unlock." isDebug:YES isUrgent:NO withNotificationID:nil];
    }
    
    [self _notifyDaemonOfMessageHandled];
}

- (void)requestDebuggingBackgroundSigning {
    @try {
        [[self.daemonConnection remoteObjectProxy] applicationRequestsDebuggingBackgroundSigning];
    } @catch (NSException *e) {
        // Error previous shown
    }

}

- (void)requestPreferencesUpdate {
    @try {
        [[self.daemonConnection remoteObjectProxy] applicationRequestsPreferencesUpdate];
    } @catch (NSException *e) {
        // Error previous shown
    }

}

- (void)_sendBackgroundedNotificationWithTitle:(NSString*)title body:(NSString*)body isDebug:(BOOL)isDebug isUrgent:(BOOL)isUrgent withNotificationID:(NSString*)notifID {
    
    // We start a background task to ensure the notification is posted when expected.
    UIApplication *application = [UIApplication sharedApplication];
    UIBackgroundTaskIdentifier __block bgTask = [application beginBackgroundTaskWithName:@"ReProvision Background Notification" expirationHandler:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
        
        [self performSelector:@selector(_notifyDaemonOfMessageHandled) withObject:nil afterDelay:5];
    }];
    
    // Post the notification.
    [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:title body:body isDebugMessage:isDebug isUrgentMessage:isUrgent andNotificationID:notifID];
    
    // Done, so stop this background task.
    [application endBackgroundTask:bgTask];
    bgTask = UIBackgroundTaskInvalid;
    
    // Ask to remove our process assertion 5 seconds later, so that we can assume any notifications
    // have been scheduled.
    [self performSelector:@selector(_notifyDaemonOfMessageHandled) withObject:nil afterDelay:5];
}
@end
