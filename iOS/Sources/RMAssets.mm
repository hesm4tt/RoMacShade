#import "RMAssets.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <dlfcn.h>
#include <zlib.h>
#include <cstring>

static NSURL *RMAssetFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"RoMacShade.Library" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}

NSString *RMPackDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *text = [NSMutableString string];
    for (unsigned char byte : digest) [text appendFormat:@"%02x", byte];
    return text;
}

NSData *RMBundledPack(void) {
    Dl_info info = {};
    if (!dladdr((void *)&RMBundledPack, &info)) return nil;
    // These offsets belong to this library's own embedded asset section; no
    // addresses from Roblox or Maxey's framework are used.
    for (uint32_t image = 0; image < _dyld_image_count(); ++image) {
        const mach_header_64 *header = (const mach_header_64 *)_dyld_get_image_header(image);
        if ((void *)header != info.dli_fbase || header->magic != MH_MAGIC_64) continue;
        const uint8_t *command = (const uint8_t *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; ++i) {
            const load_command *load = (const load_command *)command;
            if (load->cmd == LC_SEGMENT_64) {
                const segment_command_64 *segment = (const segment_command_64 *)load;
                const section_64 *sections = (const section_64 *)(segment + 1);
                for (uint32_t j = 0; j < segment->nsects; ++j) {
                    if (strncmp(sections[j].sectname, "__rmpack", 16) == 0) {
                        const void *bytes = (const void *)(sections[j].addr + _dyld_get_image_vmaddr_slide(image));
                        return [NSData dataWithBytesNoCopy:(void *)bytes length:(NSUInteger)sections[j].size freeWhenDone:NO];
                    }
                }
            }
            command += load->cmdsize;
        }
    }
    return nil;
}

NSURL *RMUserLibrary(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [support URLByAppendingPathComponent:@"RoMacShade/UserLibrary" isDirectory:YES];
    for (NSString *folder in @[@"Shaders", @"Textures", @"Presets"])
        [NSFileManager.defaultManager createDirectoryAtURL:[root URLByAppendingPathComponent:folder]
            withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

NSURL *RMInstallPack(NSData *pack, NSError **error) {
    NSURL *base = [[RMUserLibrary() URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"LibraryVersions"];
    return RMInstallPackAtURL(pack, base, error);
}

NSURL *RMInstallPackAtURL(NSData *pack, NSURL *base, NSError **error) {
    if (error) *error = nil;
    if (pack.length < 12 || pack.length > 64 * 1024 * 1024 || memcmp(pack.bytes, "RMPACK01", 8))
        return RMAssetFail(error, @"Invalid effect pack header or size.");
    uint32_t size = 0; memcpy(&size, (const uint8_t *)pack.bytes + 8, 4);
    size = CFSwapInt32LittleToHost(size);
    if (size > 2 * 1024 * 1024 || size > pack.length - 12)
        return RMAssetFail(error, @"Invalid effect pack index.");
    id manifest = [NSJSONSerialization JSONObjectWithData:[pack subdataWithRange:NSMakeRange(12, size)] options:0 error:error];
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"schema"] isEqual:@1] ||
        ![manifest[@"files"] isKindOfClass:NSArray.class]) return RMAssetFail(error, @"Unsupported effect pack index.");
    NSArray *files = manifest[@"files"];
    if (!files.count || files.count > 4096) return RMAssetFail(error, @"Unexpected effect pack file count.");
    NSString *digest = RMPackDigest(pack);
    NSURL *version = [base URLByAppendingPathComponent:digest isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:[version URLByAppendingPathComponent:@".complete"].path]) return version;
    NSURL *stage = [base URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if (![fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSMutableSet *paths = [NSMutableSet set];
    NSUInteger payload = 12 + size, total = 0;
    BOOL success = YES;
    for (id item in files) {
        if (![item isKindOfClass:NSDictionary.class]) { success = NO; break; }
        NSString *path = item[@"path"], *sha = item[@"sha256"];
        if (![path isKindOfClass:NSString.class] || !path.length || path.length > 1024 ||
            path.isAbsolutePath || [path containsString:@"\\"] || [paths containsObject:path] ||
            ![sha isKindOfClass:NSString.class] || sha.length != 64) { success = NO; break; }
        for (NSString *part in path.pathComponents)
            if ([part isEqual:@".."] || [part isEqual:@"."] || [part hasPrefix:@"."]) success = NO;
        if (!success) break;
        for (NSString *key in @[@"offset", @"length", @"size"])
            if (![item[key] isKindOfClass:NSNumber.class]) success = NO;
        if (!success) break;
        uint64_t offset = [item[@"offset"] unsignedLongLongValue];
        uint64_t length = [item[@"length"] unsignedLongLongValue];
        uint64_t bytes = [item[@"size"] unsignedLongLongValue];
        if (bytes > 32 * 1024 * 1024 || length > pack.length - payload ||
            offset > pack.length - payload - length || total + bytes > 256 * 1024 * 1024) { success = NO; break; }
        total += (NSUInteger)bytes;
        NSMutableData *raw = [NSMutableData dataWithLength:MAX((NSUInteger)bytes, (NSUInteger)1)];
        uLongf actual = (uLongf)raw.length;
        int result = uncompress((Bytef *)raw.mutableBytes, &actual,
            (const Bytef *)pack.bytes + payload + offset, (uLong)length);
        if (result != Z_OK || actual != bytes) { success = NO; break; }
        raw.length = (NSUInteger)bytes;
        if (![RMPackDigest(raw) isEqual:sha]) { success = NO; break; }
        [paths addObject:path];
        NSURL *destination = [stage URLByAppendingPathComponent:path];
        if (![fm createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] ||
            ![raw writeToURL:destination options:NSDataWritingAtomic error:error]) { success = NO; break; }
    }
    if (success) success = [digest writeToURL:[stage URLByAppendingPathComponent:@".complete"]
        atomically:YES encoding:NSUTF8StringEncoding error:error];
    if (success) success = [fm moveItemAtURL:stage toURL:version error:error];
    if (!success) {
        [fm removeItemAtURL:stage error:nil];
        if (error && *error) return nil;
        return RMAssetFail(error, @"Effect pack validation failed; the current library was retained.");
    }
    return version;
}

static BOOL RMAllowedGitHubURL(NSURL *url) {
    if (![url.scheme.lowercaseString isEqual:@"https"]) return NO;
    return [@[@"github.com", @"release-assets.githubusercontent.com", @"objects.githubusercontent.com"] containsObject:url.host.lowercaseString];
}

@interface RMPackDownload : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, copy) NSString *sha;
@property(nonatomic, copy) void (^completion)(NSURL *, NSError *);
@property(nonatomic, strong) NSError *failure;
@end
@implementation RMPackDownload
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response;
    if (!RMAllowedGitHubURL(request.URL)) {
        self.failure = [NSError errorWithDomain:@"RoMacShade.Library" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The library download redirected outside GitHub."}];
        completionHandler(nil);
    } else completionHandler(request);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session; (void)task;
    if (![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200 ||
        response.expectedContentLength > 64 * 1024 * 1024 || !RMAllowedGitHubURL(response.URL)) {
        self.failure = [NSError errorWithDomain:@"RoMacShade.Library" code:3 userInfo:@{NSLocalizedDescriptionKey:@"The project release pack is unavailable. Your bundled library is still installed."}];
        completionHandler(NSURLSessionResponseCancel);
    } else completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if (data.length > 64 * 1024 * 1024 - self.data.length) {
        self.failure = [NSError errorWithDomain:@"RoMacShade.Library" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Effect pack download exceeds the size limit."}]; [task cancel];
    } else [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)task; NSError *failure = self.failure ?: error; NSURL *root = nil;
    if (!failure && ![RMPackDigest(self.data) isEqual:self.sha])
        failure = [NSError errorWithDomain:@"RoMacShade.Library" code:5 userInfo:@{NSLocalizedDescriptionKey:@"The release pack checksum does not match this build."}];
    if (!failure) root = RMInstallPack(self.data, &failure);
    void (^completion)(NSURL *, NSError *) = self.completion;
    self.completion = nil; self.session = nil; [session finishTasksAndInvalidate];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(root, failure); });
}
@end

void RMDownloadProjectPack(NSURL *url, NSString *sha, void (^completion)(NSURL *, NSError *)) {
    if (!RMAllowedGitHubURL(url) || ![url.host.lowercaseString isEqual:@"github.com"] ||
        ![url.path containsString:@"/releases/download/"] || sha.length != 64) {
        NSError *error = nil; RMAssetFail(&error, @"Configure a GitHub release URL and its checksum before downloading.");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); }); return;
    }
    RMPackDownload *download = [RMPackDownload new]; download.data = [NSMutableData data];
    download.sha = sha; download.completion = completion;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120;
    download.session = [NSURLSession sessionWithConfiguration:configuration delegate:download delegateQueue:nil];
    [[download.session dataTaskWithURL:url] resume];
}
