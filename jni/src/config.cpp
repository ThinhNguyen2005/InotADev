#include "config.hpp"
#include "logging.hpp"

#include <fstream>
#include <string>
#include <unordered_set>
#include <mutex>

namespace hdm::config {

namespace {

constexpr const char *kConfigPath = "/system/etc/hide_devmode/targets.txt";
constexpr int kFirstAppUid        = 10000; // android.os.Process.FIRST_APPLICATION_UID

struct Rules {
    bool          wildcard_all = false;
    std::unordered_set<std::string> includes;
    std::unordered_set<std::string> excludes;
};

const Rules &load_once() {
    static Rules rules;
    static std::once_flag flag;
    std::call_once(flag, [] {
        std::ifstream in(kConfigPath);
        if (!in.is_open()) {
            LOGW("Không mở được config %s, mặc định hook toàn bộ non-system app", kConfigPath);
            rules.wildcard_all = true;
            return;
        }
        std::string line;
        while (std::getline(in, line)) {
            // trim trái-phải khoảng trắng
            size_t b = line.find_first_not_of(" \t\r\n");
            size_t e = line.find_last_not_of(" \t\r\n");
            if (b == std::string::npos) continue;
            line = line.substr(b, e - b + 1);
            if (line.empty()) continue;
            if (line[0] == '#' || line.rfind("//", 0) == 0) continue;

            if (line == "*") {
                rules.wildcard_all = true;
            } else if (line[0] == '!') {
                rules.excludes.insert(line.substr(1));
            } else {
                rules.includes.insert(line);
            }
        }
        LOGI("Config loaded: wildcard=%d, includes=%zu, excludes=%zu",
             rules.wildcard_all, rules.includes.size(), rules.excludes.size());
    });
    return rules;
}

} // namespace

bool should_hook(std::string_view package_name, int uid) {
    if (package_name.empty()) return false;

    // System server / system_app uid -> không can thiệp để tránh bootloop.
    if (uid > 0 && uid < kFirstAppUid) return false;

    const auto &r = load_once();
    std::string pkg(package_name);

    if (r.excludes.count(pkg)) return false;
    if (r.includes.count(pkg)) return true;
    return r.wildcard_all;
}

} // namespace hdm::config
