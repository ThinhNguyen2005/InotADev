#pragma once

#include <jni.h>

namespace hdm::hooks {

/**
 * Đăng ký native hooks cho Settings.Global.getInt(String,int) /
 * Settings.Secure.getInt(String,int).
 *
 * Cần JNIEnv của tiến trình app sau khi specialize. Phương pháp dùng:
 *   - FindClass + GetStaticMethodID để lấy jmethodID cho 4 overload
 *     (Global/Secure x getInt(String) / getInt(String,int)).
 *   - RegisterNatives chỉ áp dụng cho phương thức native; Settings.getInt
 *     không phải native, nên thay vào đó ta hook tầng C++ - ArtMethod
 *     entrypoint - bằng Dobby thông qua jmethodID (vốn là pointer ArtMethod).
 *   - Ngoài ra hook luôn JNIEnv->CallStaticIntMethod để bắt các app gọi
 *     reflection hoặc ContentResolver path.
 */
void install_settings_hooks(JNIEnv *env);

} // namespace hdm::hooks
