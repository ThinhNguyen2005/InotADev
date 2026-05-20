/* SPDX-License-Identifier: MIT
 *
 * Zygisk Module API v4 — header tương thích với:
 *   - Magisk Zygisk    >= v26
 *   - Zygisk-Next      (KernelSU / APatch)
 *
 * Layout binary của struct Api / module_abi PHẢI khớp với contract của loader,
 * vì module được dlopen() và gọi qua function pointer table. Toàn bộ struct
 * dưới đây mirror header chính thức của Magisk (commit ổn định kể từ v26):
 *   https://github.com/topjohnwu/Magisk/blob/master/native/src/zygisk/api.hpp
 */
#pragma once

#include <jni.h>
#include <sys/types.h>

#define ZYGISK_API_VERSION 4

namespace zygisk {

struct Api;
struct AppSpecializeArgs;
struct ServerSpecializeArgs;

class ModuleBase {
public:
    virtual ~ModuleBase() = default;
    virtual void onLoad([[maybe_unused]] Api *api,
                        [[maybe_unused]] JNIEnv *env) {}
    virtual void preAppSpecialize([[maybe_unused]] AppSpecializeArgs *args) {}
    virtual void postAppSpecialize([[maybe_unused]] const AppSpecializeArgs *args) {}
    virtual void preServerSpecialize([[maybe_unused]] ServerSpecializeArgs *args) {}
    virtual void postServerSpecialize([[maybe_unused]] const ServerSpecializeArgs *args) {}
};

struct AppSpecializeArgs {
    jint &uid;
    jint &gid;
    jintArray &gids;
    jint &runtime_flags;
    jobjectArray &rlimits;
    jint &mount_external;
    jstring &se_info;
    jstring &nice_name;
    jstring &instruction_set;
    jstring &app_data_dir;

    /* Trường tùy chọn — có thể là nullptr trên Android cũ. */
    jintArray   *const fds_to_ignore;
    jboolean    *const is_child_zygote;
    jboolean    *const is_top_app;
    jobjectArray *const pkg_data_info_list;
    jobjectArray *const whitelisted_data_info_list;
    jboolean    *const mount_data_dirs;
    jboolean    *const mount_storage_dirs;

    AppSpecializeArgs() = delete;
};

struct ServerSpecializeArgs {
    jint &uid;
    jint &gid;
    jintArray &gids;
    jint &runtime_flags;
    jlong &permitted_capabilities;
    jlong &effective_capabilities;

    ServerSpecializeArgs() = delete;
};

enum Option : int {
    FORCE_DENYLIST_UNMOUNT = 0,
    DLCLOSE_MODULE_LIBRARY = 1,
};

enum StateFlag : uint32_t {
    PROCESS_GRANTED_ROOT = (1u << 0),
    PROCESS_ON_DENYLIST  = (1u << 1),
};

namespace internal {
struct module_abi {
    long api_version;
    ModuleBase *impl;

    void (*preAppSpecialize)(ModuleBase *, AppSpecializeArgs *);
    void (*postAppSpecialize)(ModuleBase *, const AppSpecializeArgs *);
    void (*preServerSpecialize)(ModuleBase *, ServerSpecializeArgs *);
    void (*postServerSpecialize)(ModuleBase *, const ServerSpecializeArgs *);
};

template <class T>
void entry_impl(Api *api, JNIEnv *env);
} // namespace internal

/* ---------------------------------------------------------------------------
 * struct Api: cũng chính là layout của api_table mà loader truyền cho module.
 *   - Slot đầu tiên (`_this`) là context của loader.
 *   - Tiếp theo là các function pointer theo thứ tự cố định v4.
 * Module gọi method public; method nội bộ trampoline qua function pointer
 * tương ứng với `_this` làm tham số đầu.
 * ------------------------------------------------------------------------- */
struct Api {
    /* ---- API public dùng trong module ---- */
    void setOption(Option opt) {
        if (z_setOption) z_setOption(_this, opt);
    }
    uint32_t getFlags() {
        return z_getFlags ? z_getFlags(_this) : 0u;
    }
    int connectCompanion() {
        return z_connectCompanion ? z_connectCompanion(_this) : -1;
    }
    int getModuleDir() {
        return z_getModuleDir ? z_getModuleDir(_this) : -1;
    }
    void exemptFd(int fd) {
        if (z_exemptFd) z_exemptFd(fd);
    }
    void pltHookRegister(dev_t dev, ino_t inode, const char *symbol,
                         void *fn, void **backup) {
        if (z_pltHookRegister) z_pltHookRegister(dev, inode, symbol, fn, backup);
    }
    bool pltHookCommit() {
        return z_pltHookCommit && z_pltHookCommit();
    }

private:
    /* ----- Layout BẮT BUỘC khớp với loader. KHÔNG đổi thứ tự / kiểu. ----- */
    void *_this;
    bool (*z_registerModule)(Api *, internal::module_abi *);
    void (*z_hookJniNativeMethods)(JNIEnv *, const char *, JNINativeMethod *, int);
    void (*z_pltHookRegister)(dev_t, ino_t, const char *, void *, void **);
    void (*z_exemptFd)(int);
    void (*z_setOption)(void *, Option);
    uint32_t (*z_getFlags)(void *);
    int (*z_connectCompanion)(void *);
    int (*z_getModuleDir)(void *);
    bool (*z_pltHookCommit)();

    template <class T>
    friend void internal::entry_impl(Api *, JNIEnv *);
};

namespace internal {

template <class T>
void entry_impl(Api *api, JNIEnv *env) {
    /* Kiểm tra static để bắt sai layout sớm. */
    static_assert(sizeof(Api) >= sizeof(void *) * 10,
                  "Api struct layout không đủ slot");

    auto *m = new T();
    static module_abi abi{
        .api_version = ZYGISK_API_VERSION,
        .impl = m,
        .preAppSpecialize = [](ModuleBase *self, AppSpecializeArgs *a) {
            self->preAppSpecialize(a);
        },
        .postAppSpecialize = [](ModuleBase *self, const AppSpecializeArgs *a) {
            self->postAppSpecialize(a);
        },
        .preServerSpecialize = [](ModuleBase *self, ServerSpecializeArgs *a) {
            self->preServerSpecialize(a);
        },
        .postServerSpecialize = [](ModuleBase *self, const ServerSpecializeArgs *a) {
            self->postServerSpecialize(a);
        },
    };

    if (!api->z_registerModule(api, &abi)) {
        delete m;
        return;
    }
    m->onLoad(api, env);
}

} // namespace internal

} // namespace zygisk

/* ---------------------------------------------------------------------------
 * Macro export entrypoint. Loader dlsym(`zygisk_module_entry`).
 * Tham số đầu là Api* (đã được loader convert từ api_table* sang Api* cùng
 * layout — xem chú thích phía trên struct Api).
 * ------------------------------------------------------------------------- */
#define REGISTER_ZYGISK_MODULE(clazz)                                              \
    extern "C" [[gnu::visibility("default"), gnu::used]]                           \
    void zygisk_module_entry(zygisk::Api *api, JNIEnv *env) {                      \
        zygisk::internal::entry_impl<clazz>(api, env);                             \
    }

#define REGISTER_ZYGISK_COMPANION(func)                                            \
    extern "C" [[gnu::visibility("default"), gnu::used]]                           \
    void zygisk_companion_entry(int client_fd) { func(client_fd); }
