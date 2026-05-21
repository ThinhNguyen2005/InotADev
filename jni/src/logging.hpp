#pragma once
#include <android/log.h>

/* Tag log dễ tìm: `adb logcat -s zn_hdm:V` */
#ifndef LOG_TAG
#define LOG_TAG "zn_hdm"
#endif

/* Log INFO/WARN/ERROR luôn bật để debug module loading.
 * Chỉ tắt DEBUG ở release build bằng -DMODULE_VERBOSE=0. */
#ifndef MODULE_VERBOSE
#define MODULE_VERBOSE 1
#endif

#if MODULE_VERBOSE
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#else
#define LOGD(...) ((void)0)
#endif

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
