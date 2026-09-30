#import <Foundation/Foundation.h>
#import "RMAssets.h"
#include <cstring>

static void Check(BOOL passed, NSString *message) {
    if (!passed) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSData *ModifyManifest(NSData *input, void (^edit)(NSMutableArray *)) {
    uint32_t size; memcpy(&size, (const uint8_t *)input.bytes + 8, 4); size = CFSwapInt32LittleToHost(size);
    NSMutableDictionary *index = [[NSJSONSerialization JSONObjectWithData:[input subdataWithRange:NSMakeRange(12, size)]
        options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    edit(index[@"files"]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:index options:0 error:nil];
    NSMutableData *output = [NSMutableData dataWithBytes:"RMPACK01" length:8];
    uint32_t length = CFSwapInt32HostToLittle((uint32_t)json.length);
    [output appendBytes:&length length:4]; [output appendData:json];
    [output appendData:[input subdataWithRange:NSMakeRange(12 + size, input.length - 12 - size)]];
    return output;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc == 3, @"Usage: PackTests pack.rmpack writable-test-directory");
        NSData *pack = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSURL *base = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        NSError *error = nil; NSURL *root = RMInstallPackAtURL(pack, base, &error);
        Check(root != nil, error.localizedDescription ?: @"Valid pack should install");
        Check([NSFileManager.defaultManager fileExistsAtPath:[root URLByAppendingPathComponent:@"Shaders/qUINT_ssr.fx"].path], @"qUINT SSR is present");
        NSDirectoryEnumerator *iterator = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        NSUInteger presets = 0; for (NSURL *url in iterator) if ([url.pathExtension.lowercaseString isEqual:@"ini"]) ++presets;
        Check(presets == 19, @"All 17 Extravi presets and two project presets are present");
        Check([RMInstallPackAtURL(pack, base, &error) isEqual:root], @"Repeated install should reuse the complete version");
        NSData *traversal = ModifyManifest(pack, ^(NSMutableArray *files) { files[0][@"path"] = @"../escape.fx"; });
        Check(RMInstallPackAtURL(traversal, base, &error) == nil && error != nil, @"Reject path traversal");
        NSData *duplicate = ModifyManifest(pack, ^(NSMutableArray *files) { files[1][@"path"] = files[0][@"path"]; });
        Check(RMInstallPackAtURL(duplicate, base, &error) == nil, @"Reject duplicate file paths");
        NSData *badHash = ModifyManifest(pack, ^(NSMutableArray *files) { files[0][@"sha256"] = [@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]; });
        Check(RMInstallPackAtURL(badHash, base, &error) == nil, @"Reject a file checksum mismatch");
        NSData *badOffset = ModifyManifest(pack, ^(NSMutableArray *files) { files[0][@"offset"] = @(-1); });
        Check(RMInstallPackAtURL(badOffset, base, &error) == nil, @"Reject an invalid payload offset");
        Check(RMInstallPackAtURL([pack subdataWithRange:NSMakeRange(0, 11)], base, &error) == nil, @"Reject a truncated header");
        Check([NSFileManager.defaultManager fileExistsAtPath:[root URLByAppendingPathComponent:@".complete"].path], @"Failed imports preserve the installed library");
        printf("PASS: pack installation, all 19 presets, reuse, traversal, duplicate paths, checksum, bounds and rollback\n");
    }
    return 0;
}
