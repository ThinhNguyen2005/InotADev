#include "config.hpp"
#include "hook_properties.hpp"
#include "hook_settings.hpp"
#include "logging.hpp"

#include "zygisk.hpp"

#include <jni.h>
#include <string>

using zygisk::Api;
using zygisk::AppSpecializeArgs;

namespace {

class HideDevModeModule : public zygisk::ModuleBase {
public:
    void onLoad(Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
    }

    /* ---------------------------------------------------------------- *
     * preAppSpecialize: Zygote còn chưa drop privileges xuống app uid.
     * Chỉ làm các tác vụ rẻ và không I/O nặng:
     *   - Lấy package name + uid
     *   - Quyết định có hook hay không
     *   - Nếu KHÔNG hook: gọi DLCLOSE_MODULE_LIBRARY để Zygisk tự dlclose
     *     module sau khi specialize -> không để dấu vết .so trong /proc/.../maps
     * ---------------------------------------------------------------- */
    void preAppSpecialize(AppSpecializeArgs *args) override {
        std::string pkg = jstr_to_std(env_, args->nice_name);
        int uid = args->uid;

        should_hook_ = hdm::config::should_hook(pkg, uid);
        if (!should_hook_) {
            api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }
        package_ = std::move(pkg);
        uid_     = uid;
        LOGI("Sẽ ẩn DevMode cho %s (uid=%d)", package_.c_str(), uid_);
    }

    /* ---------------------------------------------------------------- *
     * postAppSpecialize: process đã fork và drop xuống uid của app. JNIEnv
     * giờ thuộc app context. Đây là điểm cài hook an toàn nhất.
     * ---------------------------------------------------------------- */
    void postAppSpecialize(const AppSpecializeArgs * /*args*/) override {
        if (!should_hook_) return;
        try_install_hooks();
    }

    /* Không can thiệp system_server. */
    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override {
        api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
    }

private:
    static std::string jstr_to_std(JNIEnv *env, jstring s) {
        if (!s || !env) return {};
        const char *c = env->GetStringUTFChars(s, nullptr);
        if (!c) return {};
        std::string out(c);
        env->ReleaseStringUTFChars(s, c);
        return out;
    }

    void try_install_hooks() {
        /* Bọc trong khối try-catch không khả dụng (đã -fno-exceptions),
         * nên chia làm 2 bước: log thận trọng + idempotent. */
        hdm::hooks::install_property_hooks(api_);
        hdm::hooks::install_settings_hooks(env_);

        /* Sau khi hook xong, KHÔNG dlclose module: PLT entries trỏ về function
         * trong .so này, unload sẽ dẫn đến SIGSEGV ở caller tiếp theo. */
    }

    Api     *api_         = nullptr;
    JNIEnv  *env_         = nullptr;
    bool     should_hook_ = false;
    int      uid_         = -1;
    std::string package_;
};

} // namespace

REGISTER_ZYGISK_MODULE(HideDevModeModule)
