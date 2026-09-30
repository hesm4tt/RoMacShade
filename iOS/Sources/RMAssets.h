#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSData *RMBundledPack(void);
FOUNDATION_EXPORT NSURL *RMInstallPack(NSData *pack, NSError **error);
FOUNDATION_EXPORT NSURL *RMInstallPackAtURL(NSData *pack, NSURL *versionsDirectory, NSError **error);
FOUNDATION_EXPORT NSURL *RMUserLibrary(void);
FOUNDATION_EXPORT NSString *RMPackDigest(NSData *data);
FOUNDATION_EXPORT void RMDownloadProjectPack(NSURL *url, NSString *expectedSHA256,
    void (^completion)(NSURL *installedRoot, NSError *error));
