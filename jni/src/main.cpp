#include "config.hpp"
#include "hook_properties.hpp"
#include "hook_settings.hpp"
#include "logging.hpp"

#include "zygisk.hpp"

#include <jni.h>
#include <string>
#include <unistd.h>
#include <sys/system_properties.h>

using zygisk::Api;
using zygisk::AppSpecializeArgs;

/* ---------------------------------------------------------------------------
 * Constructor log: chạy NGAY khi loader dlopen() module .so. Nếu thấy log này
 * trong logcat tức là Zygisk đã tìm và nạp được module - giúp khoanh vùng vấn
 * đề "module không hiện trong list" (sai tên file vs sai ABI vs symbol miss).
 * ------------------------------------------------------------------------- */
__attribute__((constructor))
static void on_module_loaded() {
    LOGI(".so loaded into process pid=%d", getpid());
}

namespace {

class HideDevModeModule : public zygisk::ModuleBase {
public:
    void onLoad(Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
        LOGI("onLoad() ok, api=%p env=%p", api, env);
    }

    /* preAppSpecialize: lấy package_name + uid, quyết định có hook hay không. */
    void preAppSpecialize(AppSpecializeArgs *args) override {
        package_     = jstr_to_std(env_, args->nice_name);
        uid_         = args->uid;
        should_hook_ = hdm::config::should_hook(package_, uid_);

        LOGD("preAppSpecialize pkg=%s uid=%d hook=%d",
             package_.c_str(), uid_, should_hook_);

        if (!should_hook_) {
            api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }
        LOGI("Sẽ ẩn DevMode cho %s (uid=%d)", package_.c_str(), uid_);
    }

    /* postAppSpecialize: process đã fork và drop xuống uid của app, JNIEnv giờ
     * thuộc app context - điểm an toàn để cài hook. */
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
        const auto &f = hdm::config::features();

        if (f.spoof_props) {
            hdm::hooks::install_property_hooks(api_);
        } else {
            LOGI("[%s] spoof_props=off, bỏ qua property hooks", package_.c_str());
        }

        /* Settings hook luôn cần JNIEnv vtable patch, nhưng việc spoof từng key
         * được điều khiển trong hook_settings.cpp dựa vào features. */
        if (f.hide_dev_options || f.hide_adb || f.hide_adb_wifi) {
            hdm::hooks::install_settings_hooks(env_);
        } else {
            LOGI("[%s] settings hooks tắt toàn bộ", package_.c_str());
        }

        /* KHÔNG dlclose: PLT entries trỏ về functions trong .so này, unload sẽ
         * SIGSEGV ở caller tiếp theo. */
    }

    Api     *api_         = nullptr;
    JNIEnv  *env_         = nullptr;
    bool     should_hook_ = false;
    int      uid_         = -1;
    std::string package_;
};

} // namespace

REGISTER_ZYGISK_MODULE(HideDevModeModule)
