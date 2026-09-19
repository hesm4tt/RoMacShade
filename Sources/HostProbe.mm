// Read-only host diagnostics. This executable never loads code into the target,
// changes its signature, or reads/writes/suspends its task or threads.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <unistd.h>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Darwin exports csops, but the public SDK does not ship sys/codesign.h.
// This declaration and these status bits follow Apple's XNU sources:
// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/codesign.h
// https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
static constexpr unsigned int MS_CS_OPS_STATUS = 0;
static constexpr uint32_t MS_CS_VALID = 0x00000001;
static constexpr uint32_t MS_CS_FORCED_LV = 0x00000010;
static constexpr uint32_t MS_CS_REQUIRE_LV = 0x00002000;
static constexpr uint32_t MS_CS_RUNTIME = 0x00010000;

static NSString *SecurityMessage(OSStatus status) {
    NSString *message = CFBridgingRelease(SecCopyErrorMessageString(status, nullptr));
    return message ?: [NSString stringWithFormat:@"OSStatus %d", (int)status];
}

static NSString *MachMessage(kern_return_t status) {
    const char *message = mach_error_string(status);
    return message ? [NSString stringWithUTF8String:message] : [NSString stringWithFormat:@"Mach status %d", status];
}

static id EntitlementValue(NSDictionary *entitlements, NSString *key, BOOL available) {
    if (!available) return NSNull.null;
    id value = entitlements[key];
    if (!value) return @NO;
    // Entitlements are booleans. Do not treat a string such as "true" as an
    // entitlement granted by the OS if a malformed signature contains one.
    return [value isKindOfClass:NSNumber.class] ? @([value boolValue]) : NSNull.null;
}

static int WriteReport(NSDictionary *report, int exitCode) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:&error];
    if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF) {
        fputs("HostProbe could not write its JSON report.\n", stderr);
        return 70;
    }
    return exitCode;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL selfTest = argc == 2 && strcmp(argv[1], "--self-test") == 0;
        if (argc != 2 || (strcmp(argv[1], "--help") == 0)) {
            return WriteReport(@{@"schemaVersion": @1, @"usage": @"HostProbe PID | HostProbe --self-test",
                @"error": argc == 2 ? @"" : @"Exactly one positive process ID is required."}, argc == 2 ? 0 : 64);
        }
        pid_t pid = getpid();
        if (!selfTest) {
            // Require decimal digits only: no zero/kernel PID, signs, whitespace,
            // truncation, or accidentally interpreted option text.
            const char *argument = argv[1];
            BOOL digitsOnly = argument[0] != '\0';
            for (const char *c = argument; *c; ++c) if (*c < '0' || *c > '9') digitsOnly = NO;
            char *end = nullptr; errno = 0;
            long number = strtol(argument, &end, 10);
            if (!digitsOnly || errno == ERANGE || !end || *end || number <= 0 || number > INT_MAX) {
                return WriteReport(@{@"schemaVersion": @1, @"error": @"PID must be a positive decimal process ID.",
                    @"usage": @"HostProbe PID | HostProbe --self-test"}, 64);
            }
            pid = static_cast<pid_t>(number);
        }

        char path[PROC_PIDPATHINFO_MAXSIZE] = {};
        errno = 0;
        int pathLength = proc_pidpath(pid, path, static_cast<uint32_t>(sizeof(path)));
        int pathErrno = pathLength > 0 ? 0 : errno;
        NSString *executable = pathLength > 0 ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:path length:strlen(path)] : nil;

        uint32_t flags = 0;
        errno = 0;
        int csResult = csops(pid, MS_CS_OPS_STATUS, &flags, sizeof(flags));
        int csErrno = csResult == 0 ? 0 : errno;
        BOOL csAvailable = csResult == 0;
        NSDictionary *codeSigning = @{
            @"available": @(csAvailable), @"errno": @(csErrno),
            @"message": csAvailable ? @"Status read successfully." : [NSString stringWithUTF8String:strerror(csErrno)],
            @"flags": csAvailable ? @(flags) : NSNull.null,
            @"flagsHex": csAvailable ? [NSString stringWithFormat:@"0x%08x", flags] : NSNull.null,
            @"validFlag": csAvailable ? @((flags & MS_CS_VALID) != 0) : NSNull.null,
            @"hardenedRuntime": csAvailable ? @((flags & MS_CS_RUNTIME) != 0) : NSNull.null,
            @"requireLibraryValidation": csAvailable ? @((flags & MS_CS_REQUIRE_LV) != 0) : NSNull.null,
            @"forcedLibraryValidation": csAvailable ? @((flags & MS_CS_FORCED_LV) != 0) : NSNull.null
        };

        SecCodeRef code = nullptr;
        NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
        OSStatus guestStatus = SecCodeCopyGuestWithAttributes(nullptr, (__bridge CFDictionaryRef)attributes,
            kSecCSDefaultFlags, &code);
        CFDictionaryRef information = nullptr;
        OSStatus signingStatus = guestStatus;
        if (guestStatus == errSecSuccess && code) {
            signingStatus = SecCodeCopySigningInformation(code,
                kSecCSSigningInformation | kSecCSRequirementInformation, &information);
        }
        NSDictionary *info = CFBridgingRelease(information);
        if (code) CFRelease(code);
        id embedded = info[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
        BOOL entitlementsAvailable = signingStatus == errSecSuccess && info != nil &&
            ([embedded isKindOfClass:NSDictionary.class] || (!embedded && !info[(__bridge NSString *)kSecCodeInfoEntitlements]));
        NSDictionary *entitlements = [embedded isKindOfClass:NSDictionary.class] ? embedded : @{};
        NSDictionary *signing = @{
            @"guestStatusCode": @(guestStatus), @"statusCode": @(signingStatus),
            @"message": SecurityMessage(signingStatus),
            @"entitlementsAvailable": @(entitlementsAvailable),
            // These are reported signature metadata, not a full signature audit.
            @"signatureValidated": @NO,
            @"entitlements": @{
                @"disableLibraryValidation": EntitlementValue(entitlements, @"com.apple.security.cs.disable-library-validation", entitlementsAvailable),
                @"allowDyldEnvironmentVariables": EntitlementValue(entitlements, @"com.apple.security.cs.allow-dyld-environment-variables", entitlementsAvailable),
                @"getTaskAllow": EntitlementValue(entitlements, @"com.apple.security.get-task-allow", entitlementsAvailable)
            }
        };

        // Probe permission only. Immediately discard any acquired send right.
        // There are deliberately no task/thread or vm operations on this right.
        task_t task = MACH_PORT_NULL;
        kern_return_t taskStatus = task_for_pid(mach_task_self(), pid, &task);
        BOOL acquired = taskStatus == KERN_SUCCESS && MACH_PORT_VALID(task);
        kern_return_t releaseStatus = acquired ? mach_port_deallocate(mach_task_self(), task) : KERN_SUCCESS;
        NSDictionary *taskPort = @{
            @"statusCode": @(taskStatus), @"message": MachMessage(taskStatus),
            @"acquired": @(acquired), @"released": @(acquired && releaseStatus == KERN_SUCCESS),
            @"releaseStatusCode": acquired ? @(releaseStatus) : NSNull.null,
            @"releaseMessage": acquired ? MachMessage(releaseStatus) : NSNull.null,
            @"observation": acquired ? (releaseStatus == KERN_SUCCESS
                ? @"The OS granted a task send right; it was immediately released. No target task operations were performed."
                : @"The OS granted a task send right, but its immediate deallocation returned an error. No target task operations were performed.")
                : @"The OS did not grant a task send right to this diagnostic process."
        };

        BOOL selfTestPassed = pathLength > 0 && csAvailable && signingStatus == errSecSuccess &&
            entitlementsAvailable && acquired && releaseStatus == KERN_SUCCESS;
        NSMutableDictionary *report = [@{
            @"schemaVersion": @1, @"pid": @(pid), @"executable": executable ?: NSNull.null,
            @"processPath": @{@"available": @(pathLength > 0), @"errno": @(pathErrno),
                @"message": pathLength > 0 ? @"Path read successfully." : [NSString stringWithUTF8String:strerror(pathErrno)]},
            @"codeSigning": codeSigning, @"signingInformation": signing, @"taskPort": taskPort,
            @"readOnly": @YES,
            @"note": @"A point-in-time diagnostic. An OS error is reported as returned; flags and entitlements alone do not prove that a dylib can load."
        } mutableCopy];
        if (selfTest) report[@"selfTestPassed"] = @(selfTestPassed);
        return WriteReport(report, selfTest && !selfTestPassed ? 1 : 0);
    }
}
