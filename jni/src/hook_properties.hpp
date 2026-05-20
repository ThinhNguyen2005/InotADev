#pragma once

namespace hdm::hooks {

/**
 * Cài inline hook lên __system_property_get và __system_property_read_callback
 * trong libc.so của process hiện tại bằng Dobby.
 *
 * Hàm này idempotent: gọi nhiều lần chỉ thực thi một lần. An toàn để gọi từ
 * postAppSpecialize.
 */
void install_property_hooks();

} // namespace hdm::hooks
