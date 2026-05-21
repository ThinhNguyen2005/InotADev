# HideDevMode & AutoToggle — Giải pháp ẩn Developer Mode & ADB toàn diện cho Android Rooted

Bộ giải pháp tối cao giúp ẩn **Chế độ nhà phát triển (Developer Options)** và **USB/Wireless Debugging** đối với các ứng dụng có tính bảo mật cực cao (như App ngân hàng, App doanh nghiệp) trên thiết bị Android đã Root, trong khi các tính năng này vẫn bật bình thường ở hệ thống ngoài để bạn thoải mái phát triển phần mềm.

Dự án bao gồm 2 module độc lập, phục vụ cho các nhu cầu sử dụng và cấu hình thiết bị khác nhau:

---

## 📊 So sánh hai Module

| Tiêu chí | 🚀 Module **AutoToggle** (Khuyên dùng) | 🛡️ Module **HideDevMode (Zygisk)** |
|:---|:---|:---|
| **Loại hình** | **System-level (Event-driven Daemon)** | **In-process (Zygisk Hook)** |
| **Cơ chế** | Tắt ADB và Developer Options thật của hệ thống ngay khi app chạy. | "Nói dối" trong bộ nhớ của app ngân hàng bằng cách hook lệnh hệ thống. |
| **Độ tin cậy** | **100% Tuyệt đối** (Do ADB thật bị tắt, app ngân hàng quét database hệ thống sẽ thấy bằng `0`). | Rất cao (Có thể bị lọt nếu app dùng các API Java phức tạp đi qua Binder). |
| **Tiêu thụ pin** | **0% Tuyệt đối khi rảnh/tắt màn hình** (Sử dụng cơ chế Binder Event-driven thay vì polling). | **0% Tuyệt đối** (Không chạy ngầm). |
| **Tiện ích Dev** | Bạn cắm cáp debug bình thường. ADB chỉ tạm tắt khi bạn đang mở app ngân hàng, đóng app sẽ tự bật lại. | ADB luôn luôn bật 24/7 ở mọi nơi, kể cả khi bạn đang mở app ngân hàng. |
| **Khuyên dùng** | Dành cho dev cần bypass các app ngân hàng khó tính nhất có cơ chế quét Java phức tạp. | Dành cho các dòng máy cũ hoặc nhu cầu bypass cơ bản, không muốn động vào cài đặt hệ thống. |

---

## 🛠️ 1. Cấu trúc Dự án

```
InotADev/
├── build.ps1                # Script build tự động & đóng gói thành file Zip
├── jni/                     # Mã nguồn C++ của Zygisk Module
│   ├── CMakeLists.txt
│   ├── include/zygisk.hpp   # Zygisk API v4
│   └── src/
│       ├── main.cpp             # Entrypoint module
│       ├── hook_properties.cpp  # Hook libc __system_property_get, _read, _read_callback
│       └── hook_settings.cpp    # Hook JNI Settings.getInt
├── modules/
│   ├── hide_devmode/        # File gốc đóng gói module Zygisk + WebUI
│   └── auto_toggle/         # File gốc đóng gói module AutoToggle + WebUI
└── dist/                    # Thư mục chứa đầu ra dạng Zip sau khi Build
```

---

## 🚀 2. Chuẩn bị & Biên dịch (Build)

### 2.1 Chuẩn bị Môi trường
* Cài đặt **Android NDK** (Khuyến cáo bản NDK r25c trở lên) và **CMake** qua Android Studio.
* Đặt biến môi trường `ANDROID_NDK_HOME` trỏ tới thư mục NDK của bạn.
* Cài đặt **Dobby** (Inline-hook engine) bằng lệnh:
  ```powershell
  git clone --depth=1 https://github.com/jmpews/Dobby.git external/Dobby
  ```
  *(Nếu chưa cài, script build.ps1 sẽ tự động clone hộ bạn).*

### 2.2 Biên dịch tự động
Chạy lệnh PowerShell sau tại thư mục gốc của dự án để đóng gói cả 2 module:
```powershell
pwsh ./build.ps1
```
Đầu ra sẽ xuất hiện trong thư mục `dist/` bao gồm:
* `dist/auto_toggle.zip`
* `dist/hide_devmode.zip`

---

## 🤖 3. Chi tiết kỹ thuật & Cơ chế hoạt động

### 3.1 Module AutoToggle (Cơ chế Đón đầu Logcat & Binder)
Các app ngân hàng hiện đại (như Vietcombank, Techcombank, VCB...) thường quét trạng thái ADB thông qua lệnh Java thuần `Settings.Global.getInt()`. Nhằm giải quyết triệt để và khắc phục điểm yếu hao pin của các Daemon thông thường, AutoToggle tích hợp 2 cơ chế siêu việt:

#### A. Triệt tiêu Race Condition (Đón đầu Logcat START)
* **Vấn đề cũ:** Khi bạn mở app ngân hàng, tiến trình của app khởi động siêu nhanh và quét ADB ngay lập tức trong `10ms` đầu. Daemon cũ dùng loop mất `50ms - 150ms` để phát hiện và tắt ADB $\rightarrow$ bị phát hiện trước.
* **Giải pháp mới:** Lắng nghe luồng logcat hệ thống lọc riêng tag `ActivityTaskManager` ở mức `Info`. Ngay khi bạn vừa chạm tay vào icon app, hệ thống phát log `START u0 { ... cmp=com.package.name/...}` **trước khi tiến trình app ngân hàng kịp fork (khởi tạo)** khoảng `200ms - 400ms`.
* Trigger của chúng ta sẽ tắt ADB thành công **trước cả khi app ngân hàng kịp khởi chạy**!

#### B. Tiết kiệm pin 100% khi rảnh (Event-driven Binder)
* Lắng nghe chuyển đổi app qua lệnh `am monitor` của Android (kết nối Binder hệ thống). Khi không chuyển app hoặc khi tắt màn hình, tiến trình shell **ngủ đông hoàn toàn (0% CPU, 0% pin)**.
* Chỉ khi màn hình bật và có sự thay đổi Activity, trigger mới thức dậy xử lý trong $\approx 0.05$ giây rồi đi ngủ tiếp. 
* Khi màn hình tắt, loop tự động chuyển sang ngủ dài hơn để điện thoại đi vào trạng thái **Deep Sleep** hoàn hảo.

---

### 3.2 Module HideDevMode (Native Property Hooking)
Mã nguồn C++ trong `hook_properties.cpp` thực hiện can thiệp sâu vào tầng hệ thống (Bionic Libc) trong không gian bộ nhớ của app mục tiêu:

Hook thành công 3 hàm native nhạy cảm nhất của Android Libc:
1. `__system_property_get` (Cách đọc property cổ điển).
2. `__system_property_read_callback` (Cách đọc mới của Android Framework).
3. `__system_property_read` (Chặn đứng hành vi đọc trực tiếp từ cấu trúc `prop_info` - cách các bộ bảo mật mạnh như DexGuard/Promon hay dùng để qua mặt Zygisk).

Khi các hàm này bị gọi để đọc các thuộc tính nhạy cảm, module sẽ tự động ghi đè giá trị giả định:
* `ro.debuggable` = `0`
* `ro.secure` = `1`
* `init.svc.adbd` = `stopped`
* `sys.usb.state` = `mtp`

---

## ⚙️ 4. Cấu hình & Sử dụng

Cả hai module đều đi kèm với **giao diện quản lý WebUI tuyệt đẹp** được tích hợp trực tiếp. 

1. Flash file zip (`auto_toggle.zip` hoặc `hide_devmode.zip`) thông qua ứng dụng quản lý Root của bạn (KernelSU / APatch / Magisk).
2. Reboot điện thoại.
3. Nhấp vào nút **WebUI** (hoặc Trang quản lý) hiển thị ngay bên cạnh module để:
   * Thêm/bớt các app ngân hàng cần ẩn vào danh sách (Danger Apps).
   * Bật/tắt các chế độ (USB Trigger, App Trigger).
   * Xem trực tiếp log trạng thái hoạt động theo thời gian thực.

---

## ⚖️ 5. Tuyên bố từ chối trách nhiệm

Dự án này được tạo ra cho mục đích nghiên cứu, học tập cá nhân về kỹ thuật can thiệp runtime trên hệ điều hành Android. Tác giả không chịu trách nhiệm cho bất kỳ hành vi lạm dụng hay tổn thất nào phát sinh từ việc sử dụng công cụ này. Khuyến cáo không sử dụng để vượt qua các cơ chế an toàn trên các hệ thống mà bạn không sở hữu hoặc không được cấp quyền hợp pháp.
