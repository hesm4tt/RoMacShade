//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan Logging Utilities.
//

#pragma once

#include <cstdio>

#if defined(__ANDROID__)
#include <android/log.h>
#define ROSHADE_LOG_TAG "RoShade"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, ROSHADE_LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, ROSHADE_LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, ROSHADE_LOG_TAG, __VA_ARGS__)
#else
#define LOGI(...) do { std::fprintf(stdout, "[RoShade INFO] " __VA_ARGS__); std::fprintf(stdout, "\n"); } while(0)
#define LOGW(...) do { std::fprintf(stdout, "[RoShade WARN] " __VA_ARGS__); std::fprintf(stdout, "\n"); } while(0)
#define LOGE(...) do { std::fprintf(stderr, "[RoShade ERROR] " __VA_ARGS__); std::fprintf(stderr, "\n"); } while(0)
#endif
