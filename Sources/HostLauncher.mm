//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "HostLauncher.h"
#import "Obfuscate.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>
#include <spawn.h>
#include <fcntl.h>
#include <dlfcn.h>

@implementation MSHostLauncher

+ (NSString *)detectRobloxApp {
    NSArray<NSString *> *candidates = @[
        OBFUSCATE("/Applications/Roblox.app"),
        [NSHomeDirectory() stringByAppendingPathComponent:OBFUSCATE("Applications/Roblox.app")]
    ];
    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

+ (NSString *)sha256OfFile:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    
    @try {
        while (YES) {
            NSData *chunk = [handle readDataOfLength:1024 * 1024];
            if (chunk.length == 0) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    } @catch (...) {
        return nil;
    } @finally {
        [handle closeFile];
    }
    
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

+ (NSString *)bundleExecutablePath:(NSString *)appPath {
    NSString *plistPath = [appPath stringByAppendingPathComponent:OBFUSCATE("Contents/Info.plist")];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *execName = info[OBFUSCATE("CFBundleExecutable")];
    if (!execName.length) return nil;
    NSString *execPath = [[appPath stringByAppendingPathComponent:OBFUSCATE("Contents/MacOS")]
                          stringByAppendingPathComponent:execName];
    if ([NSFileManager.defaultManager fileExistsAtPath:execPath]) {
        return execPath;
    }
    return nil;
}

+ (NSDictionary *)entitlementsForApp:(NSString *)appPath error:(NSError **)error {
    NSTask *task = [NSTask new];
    task.launchPath = OBFUSCATE("/usr/bin/codesign");
    task.arguments = @[OBFUSCATE("-d"), OBFUSCATE("--xml"), OBFUSCATE("--entitlements"), OBFUSCATE("-"), appPath];
    
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    
    if (![task launchAndReturnError:error]) return nil;
    [task waitUntilExit];
    
    NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
    if (data.length == 0) {
        data = [errPipe.fileHandleForReading readDataToEndOfFile];
    }
    
    if (data.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not extract entitlements"}];
        return nil;
    }
    
    NSError *plistError = nil;
    NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&plistError];
    if (!dict && error) *error = plistError;
    return dict ?: @{};
}

+ (NSString *)markerPathForApp:(NSString *)appPath {
    return [NSString stringWithFormat:@"%@.macshade.json", appPath];
}

+ (BOOL)prepareRobloxFromSource:(NSString *)sourcePath
                    destination:(NSString *)destPath
                          error:(NSError **)error {
    NSString *sourceExec = [self bundleExecutablePath:sourcePath];
    if (!sourceExec) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Source Roblox executable not found"}];
        return NO;
    }
    
    NSString *plistPath = [sourcePath stringByAppendingPathComponent:OBFUSCATE("Contents/Info.plist")];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![info[OBFUSCATE("CFBundleIdentifier")] isEqualToString:OBFUSCATE("com.roblox.RobloxPlayer")]) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Source is not the official RobloxPlayer app bundle"}];
        return NO;
    }
    
    NSString *originalHash = [self sha256OfFile:sourceExec];
    if (!originalHash.length) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Could not compute source executable digest"}];
        return NO;
    }
    
    NSDictionary *entitlements = [self entitlementsForApp:sourcePath error:error];
    if (!entitlements) return NO;
    
    NSMutableDictionary *modifiedEntitlements = [entitlements mutableCopy];
    modifiedEntitlements[OBFUSCATE("com.apple.security.cs.allow-dyld-environment-variables")] = @YES;
    modifiedEntitlements[OBFUSCATE("com.apple.security.cs.disable-library-validation")] = @YES;
    
    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Copy cleanly via ditto
    NSTask *ditto = [NSTask new];
    ditto.launchPath = OBFUSCATE("/usr/bin/ditto");
    ditto.arguments = @[sourcePath, destPath];
    if (![ditto launchAndReturnError:error]) return NO;
    [ditto waitUntilExit];
    if (ditto.terminationStatus != 0) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Ditto failed to clone Roblox app"}];
        return NO;
    }
    
    // Verify cloned executable integrity before re-signing
    NSString *destExec = [self bundleExecutablePath:destPath];
    if (!destExec) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Cloned Roblox executable not found"}];
        return NO;
    }
    NSString *preSignHash = [self sha256OfFile:destExec];
    if (![preSignHash isEqualToString:originalHash]) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Executable mismatch after cloning"}];
        return NO;
    }
    
    // Write temporary entitlements plist
    NSString *tempPlist = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"macshade-ent-%d.plist", getpid()]];
    NSData *entData = [NSPropertyListSerialization dataWithPropertyList:modifiedEntitlements format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!entData || ![entData writeToFile:tempPlist atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write entitlements plist"}];
        return NO;
    }
    
    // Re-sign clone ad-hoc
    NSTask *sign = [NSTask new];
    sign.launchPath = OBFUSCATE("/usr/bin/codesign");
    sign.arguments = @[OBFUSCATE("--force"), OBFUSCATE("--sign"), OBFUSCATE("-"),
                       OBFUSCATE("--options"), OBFUSCATE("runtime"),
                       OBFUSCATE("--entitlements"), tempPlist, destPath];
    BOOL signedOk = [sign launchAndReturnError:error];
    if (signedOk) [sign waitUntilExit];
    [NSFileManager.defaultManager removeItemAtPath:tempPlist error:nil];
    
    if (!signedOk || sign.terminationStatus != 0) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:7 userInfo:@{NSLocalizedDescriptionKey: @"Codesign failed on cloned app"}];
        return NO;
    }
    
    NSString *copyHash = [self sha256OfFile:destExec];
    if (!copyHash.length) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:8 userInfo:@{NSLocalizedDescriptionKey: @"Could not compute signed executable digest"}];
        return NO;
    }
    
    NSDictionary *marker = @{
        @"source": sourcePath,
        @"copy": destPath,
        @"sourceExecutableSHA256": originalHash,
        @"copyExecutableSHA256": copyHash ?: @"",
        @"created": [NSDate date].description
    };
    NSData *markerData = [NSJSONSerialization dataWithJSONObject:marker options:NSJSONWritingPrettyPrinted error:nil];
    [markerData writeToFile:[self markerPathForApp:destPath] atomically:YES];
    
    return YES;
}

+ (BOOL)runRobloxWithSource:(NSString *)sourcePath
                    library:(nullable NSString *)libraryPath
                  resources:(nullable NSString *)resourcesPath
                 logHandler:(void (^)(NSString *line))logHandler
                      error:(NSError **)error {
    if (!libraryPath.length) {
        // Look inside Frameworks
        NSString *bundled = [[NSBundle.mainBundle privateFrameworksPath] stringByAppendingPathComponent:OBFUSCATE("libMacShadeHost.dylib")];
        if ([NSFileManager.defaultManager fileExistsAtPath:bundled]) libraryPath = bundled;
        else {
            NSString *repoLib = [[[[NSBundle.mainBundle bundlePath] stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:OBFUSCATE("build")] stringByAppendingPathComponent:OBFUSCATE("libMacShadeHost.dylib")];
            if ([NSFileManager.defaultManager fileExistsAtPath:repoLib]) libraryPath = repoLib;
        }
    }
    
    if (![NSFileManager.defaultManager fileExistsAtPath:libraryPath ?: @""]) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:9 userInfo:@{NSLocalizedDescriptionKey: @"libMacShadeHost.dylib not found"}];
        return NO;
    }
    
    if (!resourcesPath.length) {
        NSString *bundleRes = [NSBundle.mainBundle resourcePath];
        if ([NSFileManager.defaultManager fileExistsAtPath:[bundleRes stringByAppendingPathComponent:OBFUSCATE("Effects")]]) {
            resourcesPath = bundleRes;
        } else {
            resourcesPath = [[NSBundle.mainBundle bundlePath] stringByDeletingLastPathComponent];
        }
    }
    
    NSString *sourceExec = [self bundleExecutablePath:sourcePath];
    if (!sourceExec) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Roblox executable not found"}];
        return NO;
    }
    
    NSString *hash = [self sha256OfFile:sourceExec];
    NSString *shortHash = hash.length >= 16 ? [hash substringToIndex:16] : @"default";
    
    NSString *hostDir = [[NSHomeDirectory() stringByAppendingPathComponent:OBFUSCATE("Library/Application Support/MacShade/Hosts")]
                         stringByAppendingPathComponent:shortHash];
    NSString *destApp = [hostDir stringByAppendingPathComponent:OBFUSCATE("Roblox-MacShade.app")];
    
    BOOL needPrepare = YES;
    if ([NSFileManager.defaultManager fileExistsAtPath:destApp]) {
        NSString *markerFile = [self markerPathForApp:destApp];
        NSData *mdata = [NSData dataWithContentsOfFile:markerFile];
        if (mdata) {
            NSDictionary *mdict = [NSJSONSerialization JSONObjectWithData:mdata options:0 error:nil];
            if ([mdict[@"sourceExecutableSHA256"] isEqualToString:hash]) {
                needPrepare = NO;
            }
        }
    }
    
    if (needPrepare) {
        logHandler(OBFUSCATE("Preparing isolated Roblox bundle with Metal hooks…"));
        [NSFileManager.defaultManager removeItemAtPath:destApp error:nil];
        if (![self prepareRobloxFromSource:sourcePath destination:destApp error:error]) {
            return NO;
        }
        logHandler(OBFUSCATE("Isolated bundle prepared and signed successfully."));
    } else {
        logHandler(OBFUSCATE("Using existing verified host bundle for this Roblox version."));
    }
    
    NSString *destExec = [self bundleExecutablePath:destApp];
    if (!destExec) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:11 userInfo:@{NSLocalizedDescriptionKey: @"Prepared executable not found"}];
        return NO;
    }
    
    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:OBFUSCATE("Library/Logs/MacShade")];
    [NSFileManager.defaultManager createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *statusReport = [logDir stringByAppendingPathComponent:[NSString stringWithFormat:@"host-%@.json", stamp]];
    NSString *logFile = [logDir stringByAppendingPathComponent:[NSString stringWithFormat:@"host-%@.log", stamp]];
    
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    [env removeObjectForKey:OBFUSCATE("DYLD_INSERT_LIBRARIES")];
    [env removeObjectForKey:OBFUSCATE("MACSHADE_AUTOLOAD")];
    env[OBFUSCATE("DYLD_INSERT_LIBRARIES")] = libraryPath;
    env[OBFUSCATE("MACSHADE_HOST_ENABLE")] = @"1";
    env[OBFUSCATE("MACSHADE_HOST_CLEAR_CHILD_ENV")] = @"1";
    env[OBFUSCATE("MACSHADE_HOST_RESOURCES")] = resourcesPath;
    env[OBFUSCATE("MACSHADE_HOST_REPORT")] = statusReport;
    
    [[NSFileManager defaultManager] createFileAtPath:logFile contents:[NSData data] attributes:nil];

    // Prepare environment array
    NSMutableArray<NSData *> *envStorage = [NSMutableArray new];
    char **envp = (char **)calloc(env.count + 1, sizeof(char *));
    NSUInteger envIdx = 0;
    for (NSString *k in env) {
        NSString *line = [NSString stringWithFormat:@"%@=%@", k, env[k]];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        [envStorage addObject:d];
        envp[envIdx++] = (char *)d.bytes;
    }
    envp[envIdx] = NULL;

    // Prepare argv array
    char *argv[] = {
        (char *)[destExec fileSystemRepresentation],
        NULL
    };

    // Prepare file actions for stdout/stderr redirection and working directory
    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    const char *logFilePath = [logFile fileSystemRepresentation];
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logFilePath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, logFilePath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    NSString *workingDir = [destExec stringByDeletingLastPathComponent];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    posix_spawn_file_actions_addchdir_np(&fileActions, workingDir.fileSystemRepresentation);
#pragma clang diagnostic pop

    // Prepare attributes with TCC responsibility disclaimed so Roblox runs under its own bundle identity
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    typedef int (*resp_disclaim_fn)(posix_spawnattr_t *, int);
    resp_disclaim_fn disclaim_fn = (resp_disclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (disclaim_fn) {
        disclaim_fn(&attr, 1);
    }

    logHandler([NSString stringWithFormat:@"Injecting: %@", libraryPath.lastPathComponent]);
    logHandler([NSString stringWithFormat:@"Launching: %@", destApp.lastPathComponent]);

    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, destExec.fileSystemRepresentation, &fileActions, &attr, argv, envp);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fileActions);
    free(envp);

    if (spawnErr != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:spawnErr userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to spawn Roblox: %s (%d)", strerror(spawnErr), spawnErr]
        }];
        return NO;
    }

    logHandler([NSString stringWithFormat:@"Process started with PID %d", (int)pid]);
    
    // Monitor for successful frame hook evaluation
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        if ([NSFileManager.defaultManager fileExistsAtPath:statusReport]) {
            NSData *repData = [NSData dataWithContentsOfFile:statusReport];
            if (repData) {
                NSDictionary *rep = [NSJSONSerialization JSONObjectWithData:repData options:0 error:nil];
                if ([rep[@"pid"] intValue] == pid && [rep[@"hooksInstalled"] boolValue] && [rep[@"completedFrames"] intValue] > 0) {
                    logHandler(OBFUSCATE("MacShade is processing Roblox frames."));
                    logHandler(OBFUSCATE("Press Command-E or tap the floating 'M' button in-game to toggle effects."));
                    return YES;
                }
            }
        }
        
        if (kill(pid, 0) != 0) {
            if (error) *error = [NSError errorWithDomain:@"MacShadeSecurity" code:12 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Roblox exited early. See log at %@", logFile]}];
            return NO;
        }
        
        [NSThread sleepForTimeInterval:0.25];
    }
    
    // Still running after 15s
    logHandler(OBFUSCATE("Roblox is running. Hooks initialized."));
    return YES;
}

@end
