//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import <AppKit/AppKit.h>
#import "MacShade.h"
#import "FXRuntime.h"
#import "HostOverlay.h"
#import "HardwareLock.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

// This image is an opt-in entry point for a host that permits dyld loading.
// The renderer lives in libMacShade; loading this image never attaches to a PID.
static void writeReport(NSString *path, BOOL installed, NSString *failure) {
    if (!path.length) return;
    NSDictionary *report = @{
        @"schemaVersion": @1, @"pid": @(getpid()), @"libraryLoaded": @YES,
        @"hooksInstalled": @(installed), @"error": failure ?: @"",
        @"hookDiagnostics": MSHookDiagnostics(),
        @"hostBundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"overlay": MSHostOverlayStatus() ?: @"Waiting for host",
        @"processedFrames": @(MSProcessedFrameCount()),
        @"completedFrames": @(MSCompletedFrameCount()),
        @"gpuErrors": @(MSGPUErrorCount()),
        @"fxFrames": @(MSProcessedFXFrameCount()),
        @"depthCaptures": @(MSDepthCaptureCount()),
        @"depthStatus": MSLastDepthStatus() ?: @"",
        @"effectsEnabled": @(MSIsEnabled()),
        @"timestamp": @([NSDate.date timeIntervalSince1970]),
        @"counterMeaning": @"processedFrames/fxFrames count encoding; completedFrames counts successful GPU completion of processed drawable frames."
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    if (data && [data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
    }
    static BOOL reportedWriteError = NO;
    if (error && !reportedWriteError) {
        reportedWriteError = YES;
        NSLog(@"MacShadeHost: cannot write diagnostic report: %@", error.localizedDescription);
    }
}

__attribute__((constructor)) static void startMacShadeHost(void) {
    const char *enabled = getenv("MACSHADE_HOST_ENABLE");
    if (!enabled || strcmp(enabled, "1") != 0) return;
    const char *isolateChildren = getenv("MACSHADE_HOST_CLEAR_CHILD_ENV");
    if (isolateChildren && strcmp(isolateChildren, "1") == 0) {
        // The launcher targets the player only; helpers should start normally.
        unsetenv("DYLD_INSERT_LIBRARIES");
        unsetenv("MACSHADE_HOST_ENABLE");
        unsetenv("MACSHADE_HOST_CLEAR_CHILD_ENV");
    }
    
    // Enforce Hardware ID License Lock
    if (![MSHardwareLock isLicensed]) {
        fprintf(stderr, "MacShadeHost: unlicensed hardware or invalid license token. Aborting injection.\n");
        unsetenv("DYLD_INSERT_LIBRARIES");
        unsetenv("MACSHADE_HOST_ENABLE");
        unsetenv("MACSHADE_HOST_CLEAR_CHILD_ENV");
        return;
    }
    
    // A minimal loader marker also survives hosts that exit before a main runloop.
    fprintf(stderr, "MacShadeHost: library initializer entered (pid %d)\n", getpid());
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
            NSString *resources = environment[@"MACSHADE_HOST_RESOURCES"];
            NSString *reportPath = environment[@"MACSHADE_HOST_REPORT"];
            if (!resources.length) resources = NSBundle.mainBundle.resourcePath ?: @"";
            NSError *error = nil;
            MSSetSettings(MSNeutralSettings());
            const BOOL installed = MSInstallHooks(&error);
            if (installed) MSStartHostOverlay(resources);
            else NSLog(@"MacShadeHost: hook installation failed: %@", error.localizedDescription);
            NSString *failure = error.localizedDescription;
            writeReport(reportPath, installed, failure);
            // Retained for the process lifetime, and confined to the main queue.
            static dispatch_source_t reporter;
            reporter = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(reporter, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
            dispatch_source_set_event_handler(reporter, ^{
                @autoreleasepool { writeReport(reportPath, installed, failure); }
            });
            dispatch_resume(reporter);
            NSLog(@"MacShadeHost: host entry ready; hooks=%@", installed ? @"yes" : @"no");
        }
    });
}
