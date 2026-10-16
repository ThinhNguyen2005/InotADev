# AutoToggle ADB — Giải pháp Tự động hóa & Bảo mật ADB Toàn diện cho Android

**AutoToggle ADB v2.1.0** là giải pháp tối ưu dành cho các thiết bị Android đã Root (**KernelSU / KernelSU Next / APatch / Magisk**), giúp tự động hóa hoàn toàn trạng thái bật/tắt **Gỡ lỗi USB (ADB)** và **Wireless ADB** dựa trên kết nối phần cứng thực tế và trạng thái màn hình.

Mục tiêu cốt lõi: **ADB chỉ mở khi bạn thực sự cắm cáp kết nối với Máy tính (PC)** và tự động tắt ngay lập tức khi rút cáp hoặc khóa máy. Nhờ đó, thiết bị vượt qua **100% cơ chế quét kiểm tra ADB** từ các ứng dụng ngân hàng, ví điện tử, tài chính và ứng dụng định danh bảo mật cao (VNeID, Techcombank, Vietcombank, Momo, Viettel Money...) mà không cần "nói dối" hay hook can thiệp nguy hiểm vào hệ thống.

---

## 🌟 Điểm nổi bật ở phiên bản v2.1.0

- 🦀 **Rust Daemon Native (ARM64)**: Viết lại toàn bộ daemon cốt lõi bằng Rust 2021, chạy với quyền root qua socket Linux `NETLINK_KOBJECT_UEVENT` + `inotify` + `poll(-1)`. Tiêu thụ CPU và pin ở chế độ chờ đạt mức **0.00%**.
- 🎨 **WebUI Material You (M3)**: Giao diện trực quan tích hợp sẵn trong trình quản lý KernelSU Next / KernelSU / APatch / Magisk. Hỗ trợ đầy đủ **Tiếng Việt** và Tiếng Anh (i18n), thiết kế chuẩn Material 3 với biểu tượng vector SVG, không sử dụng emoji đồ họa.
- 📱 **Companion APK Siêu Nhẹ (~33 KB)**: Ứng dụng đồng hành viết bằng **Kotlin thuần** kèm Quick Settings Tile (Phím tắt Cài đặt nhanh) 1-chạm, tối ưu kích thước bằng R8 Tree-Shaking.
- 🛡️ **Kiến trúc Single Source of Truth**: Loại bỏ hoàn toàn xung đột race-condition giữa UI và Daemon. WebUI và Quick Tile chỉ ghi nhận ý định người dùng (`MODE`), Daemon là đơn vị duy nhất điều khiển hệ thống.
- 🔒 **Khóa đơn tiến trình (`flock`) & Chống Crash-Loop**: Bảo vệ bằng `libc::flock(LOCK_EX | LOCK_NB)` chống chạy đè tiến trình; giám sát watchdog dựa trên đồng hồ monotonic uptime (`/proc/uptime`), chống sai lệch giờ do đồng bộ NTP.
- 🔄 **Khôi phục an toàn khi gỡ module (`uninstall.sh`)**: Tự động trả `development_settings_enabled` và `adb_enabled` về trạng thái an toàn ban đầu, đảm bảo không bị ẩn menu Cài đặt nhà phát triển sau khi gỡ module.

---

## 📊 So sánh các cơ chế bảo vệ ADB

| Tiêu chí | 🚀 **AutoToggle ADB v2.1** (Khuyên dùng) | ⚠️ Hook Zygisk (Nói dối bộ nhớ) | 📱 Bật/Tắt Thủ công |
| :--- | :--- | :--- | :--- |
| **Bản chất kỹ thuật** | **Tắt thật ADB cấp hệ điều hành** khi không cắm PC. | Hook API libc / JNI để trả về `adb_enabled = 0`. | Người dùng tự vào Cài đặt để bật/tắt thủ công. |
| **Khả năng qua mặt App** | **100% Tuyệt đối** (Vì ADB thực sự tắt, app quét bằng bất kỳ hàm nào cũng thấy = `0`). | Dễ bị phát hiện nếu app quét qua Binder, IPC hoặc kiểm tra tamper bộ nhớ. | 100% (nếu người dùng nhớ tắt). |
| **Tiêu hao Pin / CPU** | **0.00%** (Sử dụng `poll(-1)` ngủ sâu ở kernel, chỉ thức dậy khi có uevent USB). | 0% (nhưng có nguy cơ xung đột zygote/app). | 0%. |
| **Sạc pin thông thường** | Tự động nhận biết củ sạc thường / sạc dự phòng để **giữ ADB TẮT**. | Không phân biệt được loại sạc. | Phải tự nhớ tắt. |
| **Giao diện quản lý** | **WebUI M3** trong KSU Manager + **Quick Tile** thanh trạng thái. | Cần app cấu hình danh sách DenyList riêng. | Menu Settings Android. |

---

## 🛠️ Cấu trúc Mã nguồn Dự án

```
InotADev/
├── daemon-rs/                      # Mã nguồn Rust Daemon (aarch64-linux-android)
│   ├── Cargo.toml
│   └── src/
│       └── main.rs                 # Netlink uevent filter + inotify + flock + watchdog
├── modules/
│   └── auto_toggle/                # Module Root (KernelSU / APatch / Magisk)
│       ├── action.sh               # Nút hành động nhanh trong KSU Manager
│       ├── customize.sh            # Script cài đặt & phân quyền module
│       ├── module.prop             # Metadata module (chuẩn Magisk/KSU)
│       ├── service.sh              # Service late_start giám sát daemon bằng monotonic uptime
│       ├── uninstall.sh            # Dọn dẹp & khôi phục an toàn hệ thống khi gỡ
│       ├── webroot/                # Bundle WebUI tĩnh đã build
│       └── webui/                  # Mã nguồn React + TypeScript + Material Web M3
│           ├── src/
│           └── public/locales/     # Bộ từ điển i18n (vi.xml, en.xml)
├── external/
│   └── adbtoggler/                 # Companion App & Quick Settings Tile
│       ├── AndroidManifest.xml
│       ├── build_apk.ps1           # Pipeline build APK bằng Android SDK + kotlinc + R8
│       ├── res/                    # Layout Material 3, colors, strings (EN/VI)
│       └── src/com/inotadev/adbtoggler/
│           ├── MainActivity.kt     # Dashboard giao diện Hero Card Material 3
│           ├── AdbTileService.kt   # Quick Settings Tile Service
│           └── Constants.kt        # Hằng số hệ thống & Enum DaemonMode
├── build.ps1                       # Script tổng tự động build toàn bộ dự án
└── dist/                           # Thư mục chứa thành phẩm sau khi build
    ├── auto_toggle_v2.1.zip        # Module flash qua KernelSU / APatch / Magisk
    └── AdbToggler.apk              # Ứng dụng phím tắt Tile siêu nhẹ (~33 KB)
```

---

## 🚀 Hướng dẫn Biên dịch (Build)

### 1. Yêu cầu môi trường
1. **Android SDK**: `build-tools` (aapt2, d8/r8, zipalign, apksigner) và `platforms` (android.jar).
2. **Android NDK**: Toolchain LLVM Clang cho kiến trúc `aarch64-linux-android` (API 26+).
3. **Rust & Cargo**:
   ```powershell
   rustup target add aarch64-linux-android
   ```
4. **Node.js & pnpm**: Để biên dịch WebUI (React + Vite).

### 2. Biên dịch toàn bộ chỉ với 1 lệnh
Mở PowerShell tại thư mục gốc dự án và chạy:
```powershell
.\build.ps1
```

Quy trình tự động thực hiện:
1. **Build Rust Daemon**: Biên dịch `daemon-rs` sang nhị phân `auto_toggle_d` (ARM64 release).
2. **Build WebUI**: Biên dịch TypeScript + Vite xuất bundle tĩnh ra `modules/auto_toggle/webroot/`.
3. **Đóng gói Module Zip**: Tạo file `dist/auto_toggle_v2.1.zip` theo chuẩn Magisk/KSU (định dạng đường dẫn Unix `/`).
4. **Build AdbToggler APK**: Biên dịch `R.java`, mã nguồn Kotlin bằng `kotlinc`, tối ưu hóa bằng `R8 Tree-Shaking`, zipalign và ký APK thành `dist/AdbToggler.apk`.

> **Lưu ý về chữ ký APK**: Script build sử dụng `apksigner` với tùy chọn `--v4-signing-enabled false` để xuất ra duy nhất file `.apk` độc lập hoàn chỉnh, không phát sinh file rác `.idsig`.

---

## ⚙️ Hướng dẫn Cài đặt & Sử dụng

### Bước 1: Flash Module Root
1. Mở ứng dụng **KernelSU / KernelSU Next / APatch / Magisk**.
2. Chọn mục **Module** -> **Cài đặt từ bộ nhớ**.
3. Chọn file `dist/auto_toggle_v2.1.zip` và tiến hành flash.
4. Khởi động lại thiết bị.

### Bước 2: Cài đặt Companion App & Thêm Quick Settings Tile (Tùy chọn)
1. Cài đặt file `dist/AdbToggler.apk`.
2. Vuốt mở thanh **Cài đặt nhanh (Quick Settings / Control Center)** trên điện thoại.
3. Nhấn nút **Sửa / Chỉnh sửa phím tắt (Edit Tiles)**.
4. Kéo phím tắt **ADB Toggle** lên danh sách các ô hoạt động.
5. Giờ đây bạn có thể xem trạng thái `[BẬT]` / `[TẮT]` trực tiếp trên thanh thông báo và chạm để chuyển đổi nhanh bất kỳ lúc nào.

### Bước 3: Truy cập WebUI cấu hình nâng cao
- Đối với **KernelSU / KernelSU Next / APatch**: Mở ứng dụng quản lý root -> Chọn module **AutoToggle ADB** -> Nhấn **WebUI**.
- Giao diện cho phép:
  - Xem trạng thái kết nối phần cứng và lý do kích hoạt theo thời gian thực.
  - Chọn chế độ: **Tự động (Auto)**, **Luôn bật (Always ON)** hoặc **Luôn tắt (Always OFF)**.
  - Điều chỉnh thời gian trễ ngắt kết nối (Debounce delay 1 - 15 giây) để tránh chập chờn khi cắm rút cáp.
  - Tự động tắt Wireless ADB hoặc ẩn Developer Settings khi rút cáp.
  - Xem trực tiếp Terminal Logs từ daemon.

---

## 📜 Giấy phép & Tác giả
- **Tác giả**: [ThinhNguyen2005](https://github.com/ThinhNguyen2005)
- **Giấy phép**: Mã nguồn mở phục vụ mục đích học tập và phát triển cá nhân.
