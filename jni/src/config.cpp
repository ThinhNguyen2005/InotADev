#include "config.hpp"
#include "logging.hpp"

#include <atomic>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_set>

namespace hdm::config {

namespace {

/* Hai đường dẫn được thử lần lượt:
 *   1. /data/adb/hide_devmode/   - được service.sh khởi tạo, KHÔNG bị KSU
 *      overlay nên WebUI save vào đây sẽ persist ngay lập tức.
 *   2. /system/etc/hide_devmode/ - mount từ $MODPATH/system/etc/, bị overlay
 *      nên thay đổi cần reboot mới có hiệu lực. Dùng làm fallback nếu (1)
 *      chưa tồn tại (vd: app process khởi động trước khi service.sh chạy).
 */
constexpr const char *kConfigPaths[] = {
    "/data/adb/hide_devmode/targets.txt",
    "/system/etc/hide_devmode/targets.txt",
};
constexpr const char *kFeaturesPaths[] = {
    "/data/adb/hide_devmode/features.conf",
    "/system/etc/hide_devmode/features.conf",
};
constexpr int kFirstAppUid = 10000; // android.os.Process.FIRST_APPLICATION_UID

struct Rules {
    bool wildcard_all = false;
    std::unordered_set<std::string> includes;
    std::unordered_set<std::string> excludes;
};

/* Trim trắng đầu/cuối in-place. */
inline void trim(std::string &s) {
    auto b = s.find_first_not_of(" \t\r\n");
    auto e = s.find_last_not_of(" \t\r\n");
    if (b == std::string::npos) { s.clear(); return; }
    s = s.substr(b, e - b + 1);
}

/* Parse value sang bool. Chấp nhận: 1/0, true/false, yes/no, on/off. */
inline bool parse_bool(std::string v, bool def) {
    for (auto &c : v) c = static_cast<char>(tolower(c));
    if (v == "1" || v == "true" || v == "yes" || v == "on")  return true;
    if (v == "0" || v == "false" || v == "no"  || v == "off") return false;
    return def;
}

/* Mở file đầu tiên tồn tại trong array path. */
std::ifstream open_first(const char *const *paths, size_t n, const char *&out_path) {
    for (size_t i = 0; i < n; ++i) {
        std::ifstream f(paths[i]);
        if (f.is_open()) { out_path = paths[i]; return f; }
    }
    out_path = nullptr;
    return std::ifstream{};
}

/* ----- Lazy load với atomic flag (KHÔNG dùng std::call_once vì libc++
 * call_once có thể throw, conflict với -fno-exceptions). -------------------- */
struct LoadedState {
    Rules    rules;
    Features features;
};

std::atomic<bool> g_loaded{false};
std::mutex        g_load_mtx;
LoadedState       g_state;

void load_locked() {
    /* targets.txt */
    const char *used = nullptr;
    auto in = open_first(kConfigPaths,
                         sizeof(kConfigPaths) / sizeof(*kConfigPaths), used);
    if (!in.is_open()) {
        LOGW("targets.txt không tồn tại ở cả 2 path -> mặc định wildcard");
        g_state.rules.wildcard_all = true;
    } else {
        std::string line;
        while (std::getline(in, line)) {
            trim(line);
            if (line.empty() || line[0] == '#' || line.rfind("//", 0) == 0) continue;
            if (line == "*") {
                g_state.rules.wildcard_all = true;
            } else if (line[0] == '!') {
                g_state.rules.excludes.insert(line.substr(1));
            } else {
                g_state.rules.includes.insert(line);
            }
        }
        LOGI("Đã load targets.txt từ %s: wildcard=%d, includes=%zu, excludes=%zu",
             used, g_state.rules.wildcard_all,
             g_state.rules.includes.size(), g_state.rules.excludes.size());
    }

    /* features.conf */
    used = nullptr;
    auto fin = open_first(kFeaturesPaths,
                          sizeof(kFeaturesPaths) / sizeof(*kFeaturesPaths), used);
    if (!fin.is_open()) {
        LOGI("features.conf không có -> dùng default (mọi tính năng BẬT)");
    } else {
        std::string line;
        while (std::getline(fin, line)) {
            trim(line);
            if (line.empty() || line[0] == '#') continue;
            auto eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::string k = line.substr(0, eq);
            std::string v = line.substr(eq + 1);
            trim(k); trim(v);
            if      (k == "spoof_props")      g_state.features.spoof_props      = parse_bool(v, true);
            else if (k == "hide_dev_options") g_state.features.hide_dev_options = parse_bool(v, true);
            else if (k == "hide_adb")         g_state.features.hide_adb         = parse_bool(v, true);
            else if (k == "hide_adb_wifi")    g_state.features.hide_adb_wifi    = parse_bool(v, true);
            else if (k == "master_enabled" ||
                     k == "enabled")          g_state.features.master_enabled   = parse_bool(v, true);
        }
        LOGI("features từ %s: master=%d props=%d dev=%d adb=%d adb_wifi=%d",
             used, g_state.features.master_enabled, g_state.features.spoof_props,
             g_state.features.hide_dev_options, g_state.features.hide_adb,
             g_state.features.hide_adb_wifi);
    }
}

const LoadedState &state_once() {
    if (!g_loaded.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lk(g_load_mtx);
        if (!g_loaded.load(std::memory_order_relaxed)) {
            load_locked();
            g_loaded.store(true, std::memory_order_release);
        }
    }
    return g_state;
}

} // namespace

bool should_hook(std::string_view package_name, int uid) {
    if (package_name.empty()) return false;

    /* System server / system_app -> không can thiệp (tránh bootloop). */
    if (uid > 0 && uid < kFirstAppUid) return false;

    const auto &s = state_once();
    if (!s.features.master_enabled) return false;

    std::string pkg(package_name);
    if (s.rules.excludes.count(pkg)) return false;
    if (s.rules.includes.count(pkg)) return true;
    return s.rules.wildcard_all;
}

const Features &features() {
    return state_once().features;
}

} // namespace hdm::config
