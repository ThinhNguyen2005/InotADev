#include "hook_properties.hpp"
#include "logging.hpp"

#include <dobby.h>
#include <dlfcn.h>
#include <string.h>
#include <sys/system_properties.h>

#include <atomic>
#include <string_view>

namespace hdm::hooks {

namespace {

/* ---------------------------------------------------------------------------
 * Bảng spoof property. Dùng mảng static thay vì std::unordered_map để:
 *   - Không cần allocator (an toàn khi gọi rất sớm trong app process).
 *   - Số entry ít, linear search còn nhanh hơn hashing.
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

/* Tìm override theo key. nullptr nếu không match. */
inline const char *find_override(const char *key) {
    if (!key) return nullptr;
    for (const auto &o : kOverrides) {
        if (strcmp(key, o.key) == 0) return o.value;
    }
    return nullptr;
}

/* ---------------------------------------------------------------------------
 * 1) __system_property_get(const char *name, char *value) -> int
 *    Trả về số ký tự ghi vào value (không tính '\0').
 * ------------------------------------------------------------------------- */
using sp_get_t = int (*)(const char *, char *);
sp_get_t orig_sp_get = nullptr;

int hook_sp_get(const char *name, char *value) {
    if (const char *spoof = find_override(name)) {
        size_t len = strlen(spoof);
        if (len >= PROP_VALUE_MAX) len = PROP_VALUE_MAX - 1;
        memcpy(value, spoof, len);
        value[len] = '\0';
        return static_cast<int>(len);
    }
    return orig_sp_get ? orig_sp_get(name, value) : 0;
}

/* ---------------------------------------------------------------------------
 * 2) __system_property_read_callback(const prop_info *pi,
 *                                    void (*cb)(void *cookie,
 *                                               const char *name,
 *                                               const char *value,
 *                                               uint32_t serial),
 *                                    void *cookie)
 *
 *    Đây là API "modern" mà bionic và nhiều process zygote-spawned dùng. Chúng
 *    ta intercept callback: nếu name match override, đổi value trước khi gọi
 *    callback gốc của caller.
 * ------------------------------------------------------------------------- */
using prop_read_cb_t  = void (*)(void *, const char *, const char *, uint32_t);
using sp_read_cb_t    = void (*)(const prop_info *, prop_read_cb_t, void *);
sp_read_cb_t orig_sp_read_cb = nullptr;

/* Wrapper cookie để truyền callback gốc + cookie gốc qua trampoline. */
struct CbWrap {
    prop_read_cb_t  user_cb;
    void           *user_cookie;
};

void trampoline_cb(void *cookie, const char *name, const char *value, uint32_t serial) {
    auto *w = static_cast<CbWrap *>(cookie);
    if (const char *spoof = find_override(name)) {
        w->user_cb(w->user_cookie, name, spoof, serial);
    } else {
        w->user_cb(w->user_cookie, name, value, serial);
    }
}

void hook_sp_read_cb(const prop_info *pi, prop_read_cb_t user_cb, void *user_cookie) {
    if (!orig_sp_read_cb || !user_cb) return;

    /* CbWrap đặt trên stack -> tự release sau khi orig trả về.
     * Bionic gọi callback đồng bộ trong cùng frame nên an toàn. */
    CbWrap wrap{user_cb, user_cookie};
    orig_sp_read_cb(pi, trampoline_cb, &wrap);
}

/* ---------------------------------------------------------------------------
 * Cài hook bằng Dobby. Dùng dlsym vì symbol được libc export (không cần
 * giải mã ELF), gọn và đáng tin cậy.
 * ------------------------------------------------------------------------- */
std::atomic<bool> installed{false};

void install_one(const char *name, void *replacement, void **out_orig) {
    void *target = dlsym(RTLD_DEFAULT, name);
    if (!target) {
        LOGW("dlsym(%s) thất bại - bỏ qua", name);
        return;
    }
    int rc = DobbyHook(target, replacement, out_orig);
    if (rc != 0) {
        LOGE("DobbyHook(%s) thất bại rc=%d", name, rc);
        *out_orig = nullptr;
    } else {
        LOGD("Hook %s -> %p (orig=%p)", name, replacement, *out_orig);
    }
}

} // namespace

void install_property_hooks() {
    bool expected = false;
    if (!installed.compare_exchange_strong(expected, true)) return;

    install_one("__system_property_get",
                reinterpret_cast<void *>(&hook_sp_get),
                reinterpret_cast<void **>(&orig_sp_get));

    install_one("__system_property_read_callback",
                reinterpret_cast<void *>(&hook_sp_read_cb),
                reinterpret_cast<void **>(&orig_sp_read_cb));
}

} // namespace hdm::hooks
