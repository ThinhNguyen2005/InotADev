#pragma once
#include <string>
#include <string_view>

namespace hdm::config {

/* Cờ tính năng đọc từ /data/adb/hide_devmode/features.conf. Tất cả default = true.
 * File format: key=value (1/0/true/false), # là comment. */
struct Features {
    bool spoof_props      = true;  // hook __system_property_*
    bool hide_dev_options = true;  // settings: development_settings_enabled
    bool hide_adb         = true;  // settings: adb_enabled
    bool hide_adb_wifi    = true;  // settings: adb_wifi_enabled
    bool master_enabled   = true;  // tắt hoàn toàn module
};

/**
 * Quyết định một process có nên bị cài hook hay không. Đọc:
 *   - /data/adb/hide_devmode/targets.txt   (ưu tiên, persistent path)
 *   - /system/etc/hide_devmode/targets.txt (fallback từ module mount)
 *
 * Cú pháp file targets.txt:
 *   *                  - hook tất cả non-system app
 *   com.example.app    - hook app này
 *   !com.example.app   - loại trừ (ưu tiên hơn *)
 *   #...               - comment
 */
bool should_hook(std::string_view package_name, int uid);

/** Trả về features đã load. Lazy load lần đầu. */
const Features &features();

} // namespace hdm::config
