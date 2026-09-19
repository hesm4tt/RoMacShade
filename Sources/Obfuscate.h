//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#pragma once

#include <cstddef>
#include <string>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

namespace MacShadeSecurity {

// Compile-time string encryption template
template <size_t N, char Key>
class ObfuscatedString {
    char data_[N];
public:
    constexpr ObfuscatedString(const char (&str)[N]) : data_{} {
        for (size_t i = 0; i < N; ++i) {
            data_[i] = str[i] ^ (Key + static_cast<char>(i % 7));
        }
    }
    
    std::string decrypt() const {
        std::string result;
        result.resize(N - 1);
        for (size_t i = 0; i < N - 1; ++i) {
            result[i] = data_[i] ^ (Key + static_cast<char>(i % 7));
        }
        return result;
    }

#ifdef __OBJC__
    NSString *toNSString() const {
        std::string s = decrypt();
        return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    }
#endif
};

// Seed generator based on compile-time macros
#define MS_OBF_KEY ((__TIME__[7] * 17 + __LINE__ * 31) & 0x7F | 0x20)

} // namespace MacShadeSecurity

#ifdef __OBJC__
#define OBFUSCATE(s) (MacShadeSecurity::ObfuscatedString<sizeof(s), MS_OBF_KEY>(s).toNSString())
#endif
#define OBFUSCATE_CSTR(s) (MacShadeSecurity::ObfuscatedString<sizeof(s), MS_OBF_KEY>(s).decrypt().c_str())
#define OBFUSCATE_STD(s) (MacShadeSecurity::ObfuscatedString<sizeof(s), MS_OBF_KEY>(s).decrypt())

//
// Mach-O Objective-C Symbol Mangling
// Transforms readable class names into obfuscated hex hashes in Mach-O metadata
//
#define MSDraggableCircleButton    _0xMS_Btn_8f2a1
#define MSHostOverlayContainer     _0xMS_Cont_c31b9
#define MSHostSession              _0xMS_Sess_4d8e2
#define MSScaleHelper              _0xMS_Scl_9a1f7
#define MSOverlayController        _0xMS_Ctrl_5e2b4
#define MSOverlayRootView          _0xMS_Root_7b9d1
#define MSOverlayCanvasView        _0xMS_Canv_1c4f8
#define MSOverlayFlippedView       _0xMS_Flip_3a7e2
#define MSGlassGripView            _0xMS_Grip_6d2c9
#define MSGlassSeparator           _0xMS_Sep_8e1a4
#define MSLauncherWindowController _0xMS_Lnc_9f4c3
#define MSLogoView                 _0xMS_Logo_2b7d5
#define MSHostLauncher             _0xMS_Host_7a3e1
#define MSWeakDrawable             _0xMS_Drw_6c1b3
#define MSDepthCandidate           _0xMS_Dpt_4e9a2
#define MSDepthConverter           _0xMS_Dcnv_8b2f1
#define MSFXFrameResources         _0xMS_FRes_3d5a8
#define MSFXPreset                 _0xMS_Prst_1e4a7
#define MSHardwareLock             _0xMS_HwLock_b7e12
