#pragma once
#include <string>
#include <string_view>

namespace hdm::config {

/**
 * Quyết định xem một package có nằm trong danh sách cần ẩn Developer/Debug hay
 * không. Logic:
 *   - Đọc /system/etc/hide_devmode/targets.txt (do module copy vào).
 *   - Mỗi dòng là 1 package; '#' hoặc '//' là comment; bỏ qua dòng trống.
 *   - "*" áp dụng cho TẤT CẢ ứng dụng non-system.
 *   - Tiền tố '!' loại trừ một package khỏi danh sách (ưu tiên cao hơn '*').
 *
 * @param package_name  Tên package được Zygote truyền vào appSpecializePre.
 * @param uid           UID của tiến trình. <10000 được coi là system app và
 *                      mặc định không hook (trừ khi liệt kê tường minh).
 * @return true nếu nên cài hooks cho process này.
 */
bool should_hook(std::string_view package_name, int uid);

} // namespace hdm::config
