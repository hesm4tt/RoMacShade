//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "HardwareLock.h"
#import "Obfuscate.h"
#import <IOKit/IOKitLib.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#include <sys/stat.h>

@implementation MSHardwareLock

+ (NSString *)salt {
    return OBFUSCATE("MacShade::HWID::v1::AppleMetal::2026");
}

+ (NSData *)secretKeyData {
    NSString *sec = OBFUSCATE("9f8a3c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f");
    return [sec dataUsingEncoding:NSUTF8StringEncoding];
}

+ (NSString *)currentHWID {
    static NSString *cachedHWID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *uuid = nil;
        NSString *serial = nil;
        
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
        if (service) {
            CFTypeRef uuidRef = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPlatformUUIDKey), kCFAllocatorDefault, 0);
            if (uuidRef) {
                if (CFGetTypeID(uuidRef) == CFStringGetTypeID()) {
                    uuid = (__bridge_transfer NSString *)uuidRef;
                } else {
                    CFRelease(uuidRef);
                }
            }
            
            CFTypeRef serialRef = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPlatformSerialNumberKey), kCFAllocatorDefault, 0);
            if (serialRef) {
                if (CFGetTypeID(serialRef) == CFStringGetTypeID()) {
                    serial = (__bridge_transfer NSString *)serialRef;
                } else {
                    CFRelease(serialRef);
                }
            }
            IOObjectRelease(service);
        }
        
        if (!uuid.length) uuid = OBFUSCATE("UNKNOWN_UUID");
        if (!serial.length) serial = OBFUSCATE("UNKNOWN_SERIAL");
        
        NSString *payload = [NSString stringWithFormat:@"%@:%@:%@", uuid, serial, [self salt]];
        NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];
        
        unsigned char md[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(payloadData.bytes, (CC_LONG)payloadData.length, md);
        
        char hex[33];
        for (int i = 0; i < 16; i++) {
            snprintf(hex + (i * 2), 3, "%02X", md[i]);
        }
        hex[32] = '\0';
        
        cachedHWID = [NSString stringWithFormat:@"MS-%.4s-%.4s-%.4s-%.4s",
                      hex, hex + 4, hex + 8, hex + 12];
    });
    return cachedHWID;
}

+ (NSString *)generateKeyForHWID:(NSString *)hwid {
    if (!hwid.length) return @"";
    NSString *norm = [[hwid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    NSData *data = [norm dataUsingEncoding:NSUTF8StringEncoding];
    NSData *key = [self secretKeyData];
    
    unsigned char hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, hmac);
    
    char hex[33];
    for (int i = 0; i < 16; i++) {
        snprintf(hex + (i * 2), 3, "%02X", hmac[i]);
    }
    hex[32] = '\0';
    
    return [NSString stringWithFormat:@"KEY-%.4s-%.4s-%.4s-%.4s",
            hex, hex + 4, hex + 8, hex + 12];
}

+ (NSString *)licenseFilePath {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *macshadeDir = [appSupport stringByAppendingPathComponent:OBFUSCATE("MacShade")];
    return [macshadeDir stringByAppendingPathComponent:OBFUSCATE("License.dat")];
}

+ (BOOL)isLicensed {
    NSString *path = [self licenseFilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return NO;
    
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return NO;
    
    NSString *storedHWID = dict[OBFUSCATE("hwid")];
    NSString *storedKey = dict[OBFUSCATE("key")];
    if (!storedHWID.length || !storedKey.length) return NO;
    
    NSString *curHWID = [self currentHWID];
    if (![storedHWID isEqualToString:curHWID]) {
        // HWID mismatch - file was moved from another computer
        return NO;
    }
    
    NSString *expectedKey = [self generateKeyForHWID:curHWID];
    if (![storedKey isEqualToString:expectedKey]) {
        // Key invalid for this HWID
        return NO;
    }
    
    return YES;
}

+ (BOOL)activateWithKey:(NSString *)licenseKey error:(NSError * _Nullable * _Nullable)error {
    if (!licenseKey.length) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeLicensing" code:1 userInfo:@{NSLocalizedDescriptionKey: @"License key cannot be empty."}];
        return NO;
    }
    
    NSString *normKey = [[licenseKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    NSString *curHWID = [self currentHWID];
    NSString *expectedKey = [self generateKeyForHWID:curHWID];
    
    if (![normKey isEqualToString:expectedKey]) {
        if (error) *error = [NSError errorWithDomain:@"MacShadeLicensing" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid license key for this computer's Hardware ID."}];
        return NO;
    }
    
    NSString *path = [self licenseFilePath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSDictionary *record = @{
        OBFUSCATE("hwid"): curHWID,
        OBFUSCATE("key"): normKey,
        OBFUSCATE("activatedAt"): [[NSDate date] description]
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:error];
    if (!jsonData) return NO;
    
    BOOL success = [jsonData writeToFile:path options:NSDataWritingAtomic error:error];
    if (success) {
        chmod([path UTF8String], 0600);
    }
    return success;
}

+ (nullable NSDictionary *)licenseInfo {
    if (![self isLicensed]) return nil;
    NSString *path = [self licenseFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

@end
