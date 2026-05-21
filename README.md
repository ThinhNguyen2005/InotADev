# HideDevMode & AutoToggle — Giải pháp ẩn Developer Mode & ADB toàn diện cho Android

Dự án này cung cấp hai giải pháp độc lập nhằm hỗ trợ các nhà phát triển (Developers) và người dùng nâng cao vượt qua cơ chế phát hiện **Chế độ nhà phát triển (Developer Options)** và **USB Debugging (ADB)** từ các ứng dụng ngân hàng, tài chính hoặc bảo mật cao trên thiết bị Android đã Root.

---

## 📊 1. So sánh các giải pháp

| Tiêu chí | 🚀 Module **AutoToggle** (Khuyên dùng) | 🛡️ Module **HideDevMode (Zygisk)** | 📱 Ứng dụng **AdbToggler** (Phím tắt) |
| :--- | :--- | :--- | :--- |
| **Mô tả** | Tự động hóa ADB dựa trên sạc phần cứng. | Hook ẩn Developer Options / ADB đối với các app được chọn. | Bật/tắt ADB chủ động bằng 1-chạm hoặc Control Center Tile. |
| **Cơ chế hoạt động** | Tắt thật ADB khi không kết nối PC (Daemon). | Nói dối bộ nhớ qua libc hook. | Tắt/Bật thật ADB theo lệnh thủ công qua Root (`su`). |
| **Độ tin cậy** | **100% Tuyệt đối** (Do ADB thật bị tắt, app quét sẽ thấy bằng `0`). | Rất cao (Có thể bị lọt nếu app dùng các cơ chế quét phức tạp đi qua Binder). | **100% Tuyệt đối** (Tắt thật bằng hệ thống). |
| **Tiêu hao Pin** | **0.000%** (Cực thấp, ngủ sâu). | **0%** (Không chạy ngầm). | **0%** (Chỉ hoạt động khi nhấn nút). |
| **Tính tiện dụng** | Cắm PC: Tự động BẬT.<br>Rút PC: Tự động TẮT. | Luôn bật 24/7 mà không ảnh hưởng tới app ngân hàng. | Nhấn icon màn hình chính hoặc nhấn Tile trên Control Center. |
| **Giao diện WebUI** | **Có Dashboard** (Hiển thị PID, trạng thái sạc, logs trực tiếp). | **Không cần thiết** (Tự động 100%). | **Không cần thiết** (Tự động cập nhật trạng thái trên Tile). |

---

## 🛠️ 2. Cấu trúc Dự án

```
InotADev/
├── build.ps1                # Script PowerShell tự động biên dịch và đóng gói (.zip & .apk)
├── jni/                     # Mã nguồn C++ của module Zygisk (HideDevMode)
│   ├── CMakeLists.txt
│   └── src/
│       ├── main.cpp             # Entrypoint module Zygisk
│       └── hook_properties.cpp  # Hook libc __system_property_get, _read, _read_callback
├── modules/
│   ├── hide_devmode/        # Bản thô của module HideDevMode Magisk
│   └── auto_toggle/         # Bản thô của module AutoToggle Magisk
├── external/
│   └── adbtoggler/          # Mã nguồn ứng dụng AdbToggler.apk
└── dist/                    # Chứa thành phẩm dạng .zip và .apk sau khi build
```

---

## 🚀 3. Hướng dẫn Biên dịch & Đóng gói (Build)

### 3.1 Yêu cầu môi trường
* **Android NDK** (khuyên dùng bản r25c trở lên) và **CMake** (cài đặt qua Android Studio).
* Đặt biến môi trường `ANDROID_NDK_HOME` trỏ tới thư mục cài đặt NDK.

### 3.2 Lệnh build tự động
### 3.2 Lệnh build tự động
Chạy lệnh PowerShell tại thư mục gốc của dự án để đóng gói cả ba thành phần:
```powershell
pwsh ./build.ps1
```
*(Nếu muốn build riêng lẻ, bạn có thể dùng `-Only auto_toggle`, `-Only hide_devmode` hoặc `-Only adb_toggler`)*

Thành phẩm sẽ xuất hiện trong thư mục `dist/` bao gồm:
* `dist/auto_toggle.zip` (Module tự động hóa ADB dựa trên sạc phần cứng)
* `dist/hide_devmode.zip` (Module Zygisk ẩn Dev Mode)
* `dist/AdbToggler.apk` (Ứng dụng phím tắt Control Center & Launcher siêu nhẹ - chỉ 12.8 KB)

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

1. **Đối với Module Magisk (.zip):**
   * Flash file zip tương ứng (`auto_toggle.zip` hoặc `hide_devmode.zip`) thông qua ứng dụng quản lý Root (KernelSU / APatch / Magisk Manager).
   * Khởi động lại thiết bị.
2. **Đối với Ứng dụng AdbToggler (.apk):**
   * Cài đặt file [AdbToggler.apk](file:///d:/Root/InotADev/dist/AdbToggler.apk) có trong thư mục `dist/`.
   * Cấp quyền **Root (Superuser)** khi mở ứng dụng lần đầu tiên ngoài Màn hình chính.

---

## 📱 6. Hướng dẫn sử dụng AdbToggler (Phím tắt bật/tắt nhanh)

**AdbToggler** cung cấp hai cách điều khiển cực kỳ linh hoạt:

1. **Màn hình chính (Launcher Icon):**
   * Khi bạn nhấn vào biểu tượng ứng dụng ngoài màn hình chính, nó sẽ tự động chạy ngầm dưới giao diện trong suốt hoàn toàn, đổi ngược trạng thái ADB hiện tại và kết thúc ngay tức khắc (không hiển thị cửa sổ hay gây giật nháy màn hình).
   * Thông báo Toast dạng `Gỡ lỗi USB: ĐÃ BẬT` hoặc `Gỡ lỗi USB: ĐÃ TẮT` sẽ hiện lên tức thì.

2. **Thanh Trung tâm điều khiển (Quick Settings / Control Center Tile):**
   * Mở rộng thanh trạng thái / Trung tâm điều khiển trên điện thoại của bạn.
   * Nhấn vào biểu tượng **Chỉnh sửa phím tắt (Edit)**.
   * Tìm phím tắt có tên **ADB Toggle** (hình con bọ robot Android màu xanh lá cây) và kéo nó lên khu vực các phím tắt đang hoạt động.
   * Nhấn **Lưu (Done)**.
   * Từ bây giờ, bạn có thể bật/tắt nhanh ADB trực tiếp chỉ với 1-chạm từ Control Center. Trạng thái bật/tắt (sáng/tối) sẽ tự động đồng bộ theo thời gian thực.
