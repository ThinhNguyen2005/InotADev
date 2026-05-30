# InotADev — Ẩn Developer Mode & ADB cho Android

Dự án cung cấp giải pháp vượt qua cơ chế phát hiện **Developer Options** và **ADB** từ các ứng dụng ngân hàng, tài chính hoặc bảo mật cao trên thiết bị Android đã Root.

---

## Thành phần

Dự án gồm 3 thành phần **độc lập**, có thể dùng riêng lẻ hoặc kết hợp:

| | AutoToggle | AdbToggler |
|---|---|---|
| **Loại** | Magisk Module | Android APK |
| **Kích thước** | 7 KB | 16 KB |
| **Cơ chế** | Tự động bật/tắt ADB | Bật/tắt ADB thủ công |
| **Pin** | ~0% | 0% |
| **Root cần** | Magisk/KSU/APatch | Magisk/KSU/APatch |

---

## AdbToggler — Bật/tắt ADB 1-chạm

### Tính năng

- **Không có icon** — app ẩn hoàn toàn, không xuất hiện trên màn hình chính
- **Quick Settings Tile** — bật/tắt ADB trực tiếp từ Control Center
- **Live sync** — Tile tự cập nhật khi AutoToggle daemon thay đổi ADB
- **Hỗ trợ KernelSU / APatch / Magisk** — tự detect root method

### Cách sử dụng

**1. Thêm Quick Settings Tile**

1. Mở app (tìm trong Settings → Apps → ADB Toggle)
2. Cấp quyền **Root** khi được hỏi
3. Vuốt xuống mở Control Center
4. Nhấn **Chỉnh sửa** (biểu tượng bút)
5. Tìm **ADB Toggle** trong danh sách
6. Kéo vào vùng phím tắt đang hoạt động
7. Nhấn **Xong**

**2. Bật/tắt ADB**

Nhấn tile **ADB Toggle** trong Control Center.

**3. Thông báo**

- Bật: "Gỡ lỗi USB đã bật"
- Tắt: "Gỡ lỗi USB đã tắt"

**4. App ẩn hoàn toàn**

App không có icon trên màn hình chính. Muốn mở lại: **Settings → Apps → ADB Toggle**.

**5. Tắt quyền Root**

- **KernelSU:** Settings → KernelSU → Apps → ADB Toggle → Revoke
- **APatch:** Settings → APatch → Apps → ADB Toggle → Revoke
- **Magisk:** Magisk App → Superuser → ADB Toggle → Revoke

### Ưu nhược điểm

| Ưu điểm | Nhược điểm |
|---|---|
| Nhẹ 16 KB | Cần thao tác thủ công |
| Không chạy ngầm | Không tự động |
| Tile đồng bộ với daemon | |
| Không tốn pin | |

### Hỗ trợ Root

| Root Solution | Hỗ trợ | Ghi chú |
|---|---|---|
| **KernelSU** | Có | Tự detect qua `/data/adb/ksu/daemon_socket` |
| **APatch** | Có | Tự detect qua `/data/adb/apd/daemon_socket` |
| **Magisk** | Có | Tự detect via su binary |
| **Không có Root** | Không | Cần Root để toggle ADB |

---

## AutoToggle — Tự động bật/tắt ADB

Module Magisk tự động bật ADB khi cắm PC, tắt khi rút PC.

### Tính năng

- **USB detection < 3 giây** — PC detection window 3s, polling mỗi 0.5s (6 lần thử)
- **Pin ~0%/giờ** — inline sysfs read, không grep, không fork, batched logging
- **Xiaomi-optimized** — USBPD paths, typec data role, MIUI detection
- **Crash-loop protection** — tự halt sau >3 restart trong 60s
- **Watchdog** — restart daemon khi chết, heartbeat tracking
- **State persistence** — giữ trạng thái qua reboot

### Cách sử dụng

1. Flash `dist/auto_toggle.zip` qua KernelSU / APatch / Magisk Manager
2. Reboot
3. Không cần thao tác gì thêm

### Cơ chế hoạt động

```
Trạng thái pin (không sạc)
  → cắm sạc          → mở PC detection window (3s)
    → cắm PC            → Bật ADB, ngủ 15s
    → cắm sạc (không PC) → Tắt ADB, ngủ 60s
  → rút sạc           → Tắt ADB ngay lập tức
```

### Tối ưu pin

Module được thiết kế cho pin gần như bằng 0:

- **Idle (pin):** Ngủ 60s, chỉ đọc 1 file sysfs mỗi 60s
- **Charging (có thể PC):** Ngủ 1s, kiểm tra USB state
- **PC connected:** Ngủ 15s, monitor disconnect

So sánh: Daemon chạy trong ~1 giây mỗi phút khi charging → **CPU usage ≈ 1.7% trong 1 phút = ~0.03%/giờ**. Thực tế drain thấp hơn vì sysfs read rất nhẹ.

### Ưu nhược điểm

| Ưu điểm | Nhược điểm |
|---|---|
| Tự động hoàn toàn | Cần flash Magisk/KSU module |
| USB detection < 3s | Phụ thuộc sysfs paths (thiết bị khác nhau) |
| Không tốn pin đáng kể | |
| Works offline | |

### Debug

```bash
# Log daemon
cat /data/adb/auto_toggle/log.txt

# Daemon PID
cat /data/adb/auto_toggle/daemon_pid

# State
cat /data/adb/auto_toggle/state.sh

# Restart count (kiểm tra crash loop)
cat /data/adb/auto_toggle/restart_count

# Service errors
cat /data/adb/auto_toggle/service_error.txt

# Force kill daemon (watchdog sẽ restart)
killall auto_toggle.sh
```

---

## Build

### Yêu cầu

| Thành phần | AutoToggle | AdbToggler |
|---|---|---|
| Android NDK r25+ | Không | Không |
| Android SDK | Không | Có (build-tools + platform) |
| PowerShell | Có | Có |
| JDK 8+ | Không | Có |

### Lệnh

```powershell
# Build tất cả (cần NDK)
pwsh ./build.ps1

# Chỉ AutoToggle (không cần NDK)
pwsh ./build.ps1 -Only auto_toggle

# Chỉ AdbToggler (không cần NDK)
pwsh ./build.ps1 -Only adb_toggler

# Build nhanh (chỉ ARM64)
pwsh ./build.ps1 -Only auto_toggle,adb_toggler -ABIs arm64-v8a
```

### Output

```
dist/
├── AdbToggler.apk     # 16 KB — Android app
└── auto_toggle.zip    # 7 KB — Magisk module
```

---

## So sánh chi tiết

### AdbToggler vs AutoToggle

| Tiêu chí | AdbToggler | AutoToggle |
|---|---|---|
| **Tự động** | Không — cần nhấn | Có — bật khi cắm PC |
| **Pin tiêu hao** | 0% (chỉ khi nhấn) | ~0.03%/giờ |
| **Cần flash module** | Không | Có |
| **Phù hợp khi** | Muốn kiểm soát thủ công | Luôn cần ADB khi cắm PC |
| **Tương thích** | Mọi Android có Root | KernelSU / APatch / Magisk |

### Kết hợp tốt nhất

**AutoToggle + AdbToggler** — dùng đồng thời:
- AutoToggle: tự động bật ADB khi cắm PC
- AdbToggler: bật/tắt nhanh khi cần mà không cần cắm PC

---

## Changelog

### AdbToggler v2.0

- **KernelSU/APatch support** — tự detect root method, không hardcode su
- **Root timeout** — 5s timeout để tránh hang
- **AdbStateObserver** — Tile tự cập nhật khi daemon thay đổi ADB
- **Icon ẩn được** — launcher có thể gỡ, tile vẫn hoạt động
- **Thêm stop adbd** khi disable — tắt triệt để

### AutoToggle v1.3.0

- USB detection: 15s → 3s window, 1s → 0.5s polling
- Xiaomi paths: USBPD, typec, MIUI detection
- Pin: loại bỏ grep/fork, inline check, batched logging
- Daemon: PID tracking, heartbeat, crash-loop protection, watchdog

---

## Cấu trúc dự án

```
InotADev/
├── build.ps1
├── README.md
│
├── docs/
│   └── TEST_CHECKLIST.md       # Checklist test
│
├── modules/
│   └── auto_toggle/            # AutoToggle Magisk module
│       ├── auto_toggle.sh      # Daemon v1.3.0
│       ├── service.sh          # Boot service v1.3.0
│       ├── customize.sh
│       └── module.prop
│
├── external/
│   └── adbtoggler/             # AdbToggler Android app
│       ├── build_apk.ps1
│       ├── AndroidManifest.xml
│       ├── res/
│       │   ├── values/strings.xml
│       │   ├── values/styles.xml
│       │   └── drawable/
│       └── src/com/inotadev/adbtoggler/
│           ├── MainActivity.java      # Launcher toggle
│           ├── AdbTileService.java     # Quick Settings Tile
│           ├── AdbStateObserver.java   # ADB state watcher
│           └── AdbUtil.java           # Root + ADB operations
│
└── dist/                       # Output sau build
```
