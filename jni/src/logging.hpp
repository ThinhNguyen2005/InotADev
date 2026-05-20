#pragma once
#include <android/log.h>

// Tag ngắn, không chứa chữ "hide" để tránh bị app scan logcat phát hiện.
#ifndef LOG_TAG
#define LOG_TAG "zn_hdm"
#endif

// Đặt MODULE_VERBOSE=0 trong release để tắt toàn bộ log -> giảm dấu vết.
#ifndef MODULE_VERBOSE
#define MODULE_VERBOSE 1
#endif

#if MODULE_VERBOSE
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#else
#define LOGD(...) ((void)0)
#define LOGI(...) ((void)0)
#endif

#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
