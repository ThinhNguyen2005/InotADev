# HideDevMode & AutoToggle — Giải pháp ẩn Developer Mode & ADB toàn diện cho Android

Dự án này cung cấp hai giải pháp độc lập nhằm hỗ trợ các nhà phát triển (Developers) và người dùng nâng cao vượt qua cơ chế phát hiện **Chế độ nhà phát triển (Developer Options)** và **USB Debugging (ADB)** từ các ứng dụng ngân hàng, tài chính hoặc bảo mật cao trên thiết bị Android đã Root.

---

## 📊 1. So sánh hai giải pháp

| Tiêu chí | 🚀 Module **AutoToggle** (Khuyên dùng) | 🛡️ Module **HideDevMode (Zygisk)** |
| :--- | :--- | :--- |
| **Cơ chế hoạt động** | **Tắt thật ADB/Dev Options** của hệ thống ở cấp độ gốc (System-level Daemon). | **Nói dối bộ nhớ** (In-process Hook) bằng cách hook API libc hệ thống trong không gian của app mục tiêu. |
| **Độ tin cậy** | **100% Tuyệt đối** (Do ADB thật bị tắt, app quét dữ liệu hệ thống sẽ thấy bằng `0`). | Rất cao (Có thể bị lọt nếu app dùng các cơ chế quét phức tạp đi qua Binder). |
| **Tiêu hao Pin** | **0.000% tuyệt đối** nhờ cơ chế theo dõi sạc thông minh mới. | **0% tuyệt đối** (Không chạy ngầm). |
| **Tính tiện dụng** | Cắm cáp vào PC: ADB tự động BẬT.<br>Rút cáp ra: ADB tự động TẮT ngay lập tức. | ADB luôn luôn bật 24/7 ở mọi nơi, kể cả khi đang dùng app ngân hàng. |
| **Giao diện WebUI** | **Không cần thiết** (Hoạt động tự động hoàn hảo dựa trên kết nối phần cứng). | **Không cần thiết** (Ẩn tự động cho toàn bộ ứng dụng ngoài hệ thống). |

---

## 🛠️ 2. Cấu trúc Dự án

```
InotADev/
├── build.ps1                # Script PowerShell tự động biên dịch và đóng gói (.zip)
├── jni/                     # Mã nguồn C++ của module Zygisk (HideDevMode)
│   ├── CMakeLists.txt
│   └── src/
│       ├── main.cpp             # Entrypoint module Zygisk
│       └── hook_properties.cpp  # Hook libc __system_property_get, _read, _read_callback
├── modules/
│   ├── hide_devmode/        # Bản thô của module HideDevMode Magisk
│   └── auto_toggle/         # Bản thô của module AutoToggle Magisk
└── dist/                    # Chứa thành phẩm dạng .zip sau khi chạy build
```

---

## 🚀 3. Hướng dẫn Biên dịch & Đóng gói (Build)

### 3.1 Yêu cầu môi trường
* **Android NDK** (khuyên dùng bản r25c trở lên) và **CMake** (cài đặt qua Android Studio).
* Đặt biến môi trường `ANDROID_NDK_HOME` trỏ tới thư mục cài đặt NDK.

### 3.2 Lệnh build tự động
Chạy lệnh PowerShell tại thư mục gốc của dự án để đóng gói cả hai module:
```powershell
pwsh ./build.ps1
```
*(Nếu chỉ muốn build riêng AutoToggle, hãy dùng: `pwsh ./build.ps1 -Only auto_toggle`)*

Thành phẩm sẽ xuất hiện trong thư mục `dist/` bao gồm:
* `dist/auto_toggle.zip` (Chỉ ~2.8 KB)
* `dist/hide_devmode.zip`

---

## 🤖 4. Chi tiết kỹ thuật & Cơ chế hoạt động của AutoToggle

Module **AutoToggle** được thiết kế lại hoàn toàn để loại bỏ các logic giám sát phức tạp trước đây (như Logcat, Binder Monitor hay WebUI). Script hoạt động dựa trên cơ chế **Kiểm tra sạc một lần duy nhất** để triệt tiêu hoàn toàn điện năng tiêu thụ:

1. **Khi thiết bị không sạc (Chạy bằng pin):**
   * ADB được giữ ở trạng thái **TẮT** (Disabled).
   * Daemon ngủ đông và chỉ đọc một file sysfs cực kỳ nhẹ (`/sys/class/power_supply/...`) để phát hiện nguồn điện cắm vào. Lượng CPU sử dụng bằng **0%**.
2. **Khi phát hiện cắm sạc (Power Connected):**
   * Hệ thống sẽ chạy một vòng lặp nhỏ trong tối đa 5 giây đầu (mỗi giây thử lại 1 lần) để chờ quá trình **bắt tay USB (USB Handshake)** hoàn tất.
   * Nếu nhận diện thấy trạng thái `CONFIGURED` (được cắm vào Máy tính/PC): Tự động **BẬT** ADB.
   * Nếu chỉ cắm vào **củ sạc thường hoặc sạc dự phòng**: Giữ ADB **TẮT** và ngừng hoàn toàn việc kiểm tra USB trong suốt phiên sạc đó.
3. **Khi phát hiện rút sạc (Power Disconnected):**
   * Ngay lập tức tắt ADB và quay lại chế độ ngủ đông tiết kiệm pin.

---

## ⚙️ 5. Cài đặt & Sử dụng

1. Flash file zip thành phẩm (`auto_toggle.zip` hoặc `hide_devmode.zip`) thông qua trình quản lý Root (KernelSU / APatch / Magisk Manager).
2. Khởi động lại thiết bị.
3. Tận hưởng giải pháp bypass hoàn hảo mà không cần bất kỳ thao tác cấu hình thủ công nào!
