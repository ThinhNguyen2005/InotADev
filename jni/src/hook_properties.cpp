#include "hook_properties.hpp"
#include "logging.hpp"

#include <dlfcn.h>
#include <string.h>
#include <sys/system_properties.h>

#include <atomic>

namespace hdm::hooks {

namespace {

/* ---------------------------------------------------------------------------
 * Bảng spoof property. Dùng mảng static thay cho map để tránh allocator nóng:
 *   - Số entry ít, linear search còn nhanh hơn hashing.
 *   - Không phụ thuộc heap -> an toàn khi gọi rất sớm trong vòng đời process.
 * ------------------------------------------------------------------------- */
struct PropOverride {
    const char *key;
    const char *value;
};

constexpr PropOverride kOverrides[] = {
    {"ro.debuggable",                "0"},
    {"ro.secure",                    "1"},
    {"ro.adb.secure",                "1"},
    {"init.svc.adbd",                "stopped"},
    {"init.svc.adb_root",            "stopped"},
    {"sys.usb.state",                "mtp"},
    {"sys.usb.config",               "mtp"},
    {"sys.usb.configfs",             "0"},
    {"sys.usb.ffs.ready",            "0"},
    {"persist.sys.usb.config",       "mtp"},
    {"persist.sys.usb.reboot.func",  "mtp"},
    {"persist.adb.tls_server.enable","0"},
    {"persist.adb.wifi",             "0"},
    {"service.adb.tls.port",         ""},
};

inline const char *find_override(const char *key) {
    if (!key) return nullptr;
    for (const auto &o : kOverrides) {
        if (strcmp(key, o.key) == 0) return o.value;
    }
    return nullptr;
}

/* ---------------------------------------------------------------------------
 * Trampolines tới hàm gốc. Zygisk PLT engine ghi địa chỉ gốc vào pointer ta
 * cung cấp khi commit thành công.
 * ------------------------------------------------------------------------- */
using sp_get_t       = int (*)(const char *, char *);
using prop_read_cb_t = void (*)(void *, const char *, const char *, uint32_t);
using sp_read_cb_t   = void (*)(const prop_info *, prop_read_cb_t, void *);
using sp_read_t      = int (*)(const prop_info *, char *, char *);

sp_get_t      orig_sp_get     = nullptr;
sp_read_cb_t  orig_sp_read_cb = nullptr;
sp_read_t     orig_sp_read    = nullptr;

/* 1) __system_property_get(name, value) */
int hook_sp_get(const char *name, char *value) {
    if (const char *spoof = find_override(name)) {
        size_t len = strlen(spoof);
        if (len >= PROP_VALUE_MAX) len = PROP_VALUE_MAX - 1;
        memcpy(value, spoof, len);
        value[len] = '\0';
        return static_cast<int>(len);
    }
    /* Fallback gọi qua dlsym để bao trường hợp PLT hook không cover được
     * (vd: caller nội tại trong libc.so). */
    if (orig_sp_get) return orig_sp_get(name, value);
    auto *fb = reinterpret_cast<sp_get_t>(
            dlsym(RTLD_DEFAULT, "__system_property_get"));
    return fb ? fb(name, value) : 0;
}

/* 2) __system_property_read_callback - intercept callback của caller. */
struct CbWrap {
    prop_read_cb_t  user_cb;
    void           *user_cookie;
};

void trampoline_cb(void *cookie, const char *name,
                   const char *value, uint32_t serial) {
    auto *w = static_cast<CbWrap *>(cookie);
    if (const char *spoof = find_override(name)) {
        w->user_cb(w->user_cookie, name, spoof, serial);
    } else {
        w->user_cb(w->user_cookie, name, value, serial);
    }
}

void hook_sp_read_cb(const prop_info *pi, prop_read_cb_t user_cb, void *user_cookie) {
    if (!user_cb) return;
    CbWrap wrap{user_cb, user_cookie};

    if (orig_sp_read_cb) {
        orig_sp_read_cb(pi, trampoline_cb, &wrap);
        return;
    }
    auto *fb = reinterpret_cast<sp_read_cb_t>(
            dlsym(RTLD_DEFAULT, "__system_property_read_callback"));
    if (fb) fb(pi, trampoline_cb, &wrap);
}

/* 3) __system_property_read - intercept đọc trực tiếp từ cấu trúc prop_info. */
int hook_sp_read(const prop_info *pi, char *name, char *value) {
    char tmp_name[92] = {0};
    char tmp_value[128] = {0};
    int ret = 0;

    if (orig_sp_read) {
        ret = orig_sp_read(pi, tmp_name, tmp_value);
    } else {
        auto *fb = reinterpret_cast<sp_read_t>(
                dlsym(RTLD_DEFAULT, "__system_property_read"));
        if (fb) ret = fb(pi, tmp_name, tmp_value);
    }

    if (ret >= 0) {
        if (const char *spoof = find_override(tmp_name)) {
            size_t len = strlen(spoof);
            if (len >= PROP_VALUE_MAX) len = PROP_VALUE_MAX - 1;
            memcpy(tmp_value, spoof, len);
            tmp_value[len] = '\0';
            ret = static_cast<int>(len);
        }
        if (name) strcpy(name, tmp_name);
        if (value) strcpy(value, tmp_value);
    }
    return ret;
}

std::atomic<bool> installed{false};

} // namespace

void install_property_hooks(zygisk::Api *api) {
    if (!api) return;
    bool expected = false;
    if (!installed.compare_exchange_strong(expected, true)) return;

    /* Zygisk PLT-hook API:
     *   pltHookRegister(dev, ino, symbol, replace, &backup)
     *
     * Cách Magisk loader implement: nếu dev=0 và ino=0, áp dụng cho TẤT CẢ
     * shared object đã load - đúng như nhu cầu của ta.
     *
     * Không cần lo về thread-safety của PLT page: loader đã mprotect và đảm
     * bảo atomic write.
     */
    api->pltHookRegister(0, 0, "__system_property_get",
                         reinterpret_cast<void *>(&hook_sp_get),
                         reinterpret_cast<void **>(&orig_sp_get));

    api->pltHookRegister(0, 0, "__system_property_read_callback",
                         reinterpret_cast<void *>(&hook_sp_read_cb),
                         reinterpret_cast<void **>(&orig_sp_read_cb));

    api->pltHookRegister(0, 0, "__system_property_read",
                         reinterpret_cast<void *>(&hook_sp_read),
                         reinterpret_cast<void **>(&orig_sp_read));

    if (!api->pltHookCommit()) {
        LOGE("pltHookCommit thất bại - properties hooks không hoạt động");
        installed.store(false);
        return;
    }
    LOGI("Property PLT hooks installed (orig_get=%p, orig_cb=%p, orig_read=%p)",
         orig_sp_get, orig_sp_read_cb, orig_sp_read);
}

} // namespace hdm::hooks
