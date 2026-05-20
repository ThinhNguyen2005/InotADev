#pragma once
#include "zygisk.hpp"

namespace hdm::hooks {

/**
 * Cài PLT hook lên __system_property_get và __system_property_read_callback
 * trên TẤT CẢ shared object trong tiến trình hiện tại, sử dụng PLT-hook engine
 * builtin của Zygisk API (pltHookRegister + pltHookCommit).
 *
 * @param api  Con trỏ Api* được loader truyền vào onLoad. Phải hợp lệ trong
 *             suốt vòng đời tiến trình (Zygisk đảm bảo điều này).
 *
 * Hàm idempotent: gọi nhiều lần chỉ thực thi một lần.
 */
void install_property_hooks(zygisk::Api *api);

} // namespace hdm::hooks
