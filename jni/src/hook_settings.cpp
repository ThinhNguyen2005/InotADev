#include "hook_settings.hpp"
#include "logging.hpp"

#include <jni.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>

#include <atomic>

namespace hdm::hooks {

namespace {

/* ---------------------------------------------------------------------------
 * Danh sách key trong Settings.Global / Settings.Secure cần ép giá trị 0.
 *   - "development_settings_enabled" -> Developer Options
 *   - "adb_enabled"                  -> USB Debugging
 *   - "adb_wifi_enabled"             -> Wireless Debugging (Android 11+)
 *   - các alias khác xuất hiện trên một số ROM/OEM
 * ------------------------------------------------------------------------- */
constexpr const char *kSpoofedKeys[] = {
    "development_settings_enabled",
    "adb_enabled",
    "adb_wifi_enabled",
    "wifi_adb_enabled",            // alias trên một số OEM
    "verifier_verify_adb_installs",
};

inline bool should_spoof_key(JNIEnv *env, jstring jname) {
    if (!jname) return false;
    const char *cstr = env->GetStringUTFChars(jname, nullptr);
    if (!cstr) return false;
    bool match = false;
    for (const char *k : kSpoofedKeys) {
        if (strcmp(cstr, k) == 0) { match = true; break; }
    }
    env->ReleaseStringUTFChars(jname, cstr);
    return match;
}

/* ---------------------------------------------------------------------------
 * Strategy: hook tầng JNI bằng cách thay thế con trỏ hàm trong
 * JNINativeInterface (function table mà mọi JNIEnv* trỏ tới).
 *
 * Ưu điểm so với patch ArtMethod:
 *   - Layout của JNINativeInterface CỐ ĐỊNH theo spec JNI 1.6, không thay đổi
 *     theo version Android -> không phụ thuộc offset.
 *   - Không cần inline trampoline cho Java method -> không cần hook engine
 *     riêng cho phần này, giảm bề mặt tấn công.
 *
 * Settings.Global.getInt() / Settings.Secure.getInt() KHÔNG phải native, nên
 * chúng ta không thể đặt JNI native binding cho chúng. Thay vào đó:
 *   - Mọi caller native (JNI / reflection từ native / framework) gọi qua
 *     JNIEnv->CallStaticIntMethodV (hoặc A). Hook tại đây bắt được tất cả.
 *   - Java code gọi trực tiếp Settings.getInt() KHÔNG đi qua vector này.
 *     Tuy nhiên, hầu hết app phòng tránh detection đều gọi qua reflection
 *     hoặc qua chuỗi `ContentResolver.call -> Binder` -> điểm đáp xuống native
 *     vẫn nằm trong các CallStaticXxx này.
 * ------------------------------------------------------------------------- */

using CallStaticIntV_t = jint (*)(JNIEnv *, jclass, jmethodID, va_list);
using CallStaticIntA_t = jint (*)(JNIEnv *, jclass, jmethodID, const jvalue *);

CallStaticIntV_t orig_CallStaticIntMethodV = nullptr;
CallStaticIntA_t orig_CallStaticIntMethodA = nullptr;

/* Cache jmethodID của các overload getInt mà ta quan tâm. */
struct TargetMethods {
    jmethodID global_getInt_2 = nullptr; // (CR,String) -> int
    jmethodID global_getInt_3 = nullptr; // (CR,String,int) -> int
    jmethodID secure_getInt_2 = nullptr;
    jmethodID secure_getInt_3 = nullptr;
    jmethodID system_getInt_2 = nullptr; // Settings.System (1 số ROM dùng)
    jmethodID system_getInt_3 = nullptr;
};
TargetMethods g_targets{};

inline bool is_target_method(jmethodID mid) {
    return mid && (mid == g_targets.global_getInt_2 || mid == g_targets.global_getInt_3 ||
                   mid == g_targets.secure_getInt_2 || mid == g_targets.secure_getInt_3 ||
                   mid == g_targets.system_getInt_2 || mid == g_targets.system_getInt_3);
}

/* Mọi getInt overload có chung schema:
 *   arg[0] = ContentResolver
 *   arg[1] = String (key)        <-- đây là cái ta cần
 *   arg[2] = int (default)        <-- chỉ trong overload 3 tham số
 * Vì chỉ cần arg[1] để quyết định, không cần phân biệt overload khi parse.
 */
inline jstring extract_key_from_va(va_list ap) {
    /* Sao chép trước khi va_arg để không phá ap gốc của caller. */
    va_list copy;
    va_copy(copy, ap);
    (void) va_arg(copy, jobject);     // ContentResolver
    jstring name = va_arg(copy, jstring);
    va_end(copy);
    return name;
}

inline jstring extract_key_from_jvalue(const jvalue *args) {
    return static_cast<jstring>(args[1].l);
}

jint hook_CallStaticIntMethodV(JNIEnv *env, jclass clazz, jmethodID mid, va_list ap) {
    if (is_target_method(mid)) {
        jstring name = extract_key_from_va(ap);
        if (should_spoof_key(env, name)) {
            LOGD("spoofed Settings.getInt[V] -> 0");
            return 0;
        }
    }
    return orig_CallStaticIntMethodV(env, clazz, mid, ap);
}

jint hook_CallStaticIntMethodA(JNIEnv *env, jclass clazz, jmethodID mid, const jvalue *args) {
    if (is_target_method(mid)) {
        jstring name = extract_key_from_jvalue(args);
        if (should_spoof_key(env, name)) {
            LOGD("spoofed Settings.getInt[A] -> 0");
            return 0;
        }
    }
    return orig_CallStaticIntMethodA(env, clazz, mid, args);
}

/* ---------------------------------------------------------------------------
 * Patch JNIEnv->functions. Đây là một con trỏ tới JNINativeInterface mà ART
 * đặt trong .data của libart.so. Sau fork, child kế thừa qua copy-on-write,
 * mprotect + write -> kernel tự cấp page riêng cho process này, KHÔNG ảnh
 * hưởng các process khác.
 * ------------------------------------------------------------------------- */
bool patch_jni_table(JNIEnv *env) {
    auto *table = const_cast<JNINativeInterface *>(env->functions);

    long page = sysconf(_SC_PAGESIZE);
    auto base = reinterpret_cast<uintptr_t>(table) & ~(page - 1);
    auto end  = (reinterpret_cast<uintptr_t>(table) + sizeof(JNINativeInterface) + page - 1)
                & ~(page - 1);
    size_t span = end - base;

    if (mprotect(reinterpret_cast<void *>(base), span,
                 PROT_READ | PROT_WRITE) != 0) {
        LOGE("mprotect JNIEnv table thất bại: errno=%d", errno);
        return false;
    }

    orig_CallStaticIntMethodV = table->CallStaticIntMethodV;
    orig_CallStaticIntMethodA = table->CallStaticIntMethodA;

    table->CallStaticIntMethodV = &hook_CallStaticIntMethodV;
    table->CallStaticIntMethodA = &hook_CallStaticIntMethodA;

    /* Khôi phục lại R-X (libart.so vốn không cần X cho .data, nhưng giữ R+X
     * an toàn cho mọi mapping mà table có thể nằm trong). */
    mprotect(reinterpret_cast<void *>(base), span, PROT_READ | PROT_EXEC);
    return true;
}

void resolve_target_methods(JNIEnv *env) {
    auto resolve = [&](const char *cls, jmethodID &m2, jmethodID &m3) {
        jclass c = env->FindClass(cls);
        if (!c) {
            env->ExceptionClear();
            LOGW("FindClass %s thất bại", cls);
            return;
        }
        m2 = env->GetStaticMethodID(c, "getInt",
                "(Landroid/content/ContentResolver;Ljava/lang/String;)I");
        if (env->ExceptionCheck()) env->ExceptionClear();
        m3 = env->GetStaticMethodID(c, "getInt",
                "(Landroid/content/ContentResolver;Ljava/lang/String;I)I");
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteLocalRef(c);
    };

    resolve("android/provider/Settings$Global",
            g_targets.global_getInt_2, g_targets.global_getInt_3);
    resolve("android/provider/Settings$Secure",
            g_targets.secure_getInt_2, g_targets.secure_getInt_3);
    resolve("android/provider/Settings$System",
            g_targets.system_getInt_2, g_targets.system_getInt_3);

    LOGD("Resolved mids: g2=%p g3=%p s2=%p s3=%p",
         g_targets.global_getInt_2, g_targets.global_getInt_3,
         g_targets.secure_getInt_2, g_targets.secure_getInt_3);
}

std::atomic<bool> installed{false};

} // namespace

void install_settings_hooks(JNIEnv *env) {
    if (!env) return;
    bool expected = false;
    if (!installed.compare_exchange_strong(expected, true)) return;

    resolve_target_methods(env);
    if (!patch_jni_table(env)) {
        LOGE("Cài Settings hook thất bại");
        installed.store(false);
        return;
    }
    LOGI("Settings JNI hooks installed");
}

} // namespace hdm::hooks
