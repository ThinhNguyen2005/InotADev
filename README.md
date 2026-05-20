# HideDevMode — Zygisk Module

Module Zygisk ẩn cục bộ **Chế độ nhà phát triển** (Developer Options) và
**USB / Wireless Debugging** đối với một danh sách ứng dụng do bạn chỉ định,
trong khi các tính năng đó vẫn bật bình thường ở phần còn lại của hệ thống.

Tương thích:

| Loader        | Trạng thái |
|---------------|------------|
| Magisk Zygisk (≥ 26.0) | ✔ |
| KernelSU + zygisk‑next | ✔ |
| APatch + zygisk‑next   | ✔ |

Yêu cầu Android 8.0 (API 26) trở lên, kiến trúc `arm64-v8a` / `armeabi-v7a` /
`x86_64` / `x86`.

> [!WARNING]
> Module này chỉ làm thay đổi giá trị **trả về** từ trong tiến trình app. Nó
> KHÔNG vô hiệu hóa thực sự ADB hay Developer Options trên hệ thống. Nếu một
> app dùng các kênh không bị hook (ví dụ đọc thẳng `/proc/sys`, dùng JVMTI,
> hoặc native-code self-check riêng) thì kết quả có thể vẫn lộ.

---

## 1. Cấu trúc dự án

```
InotADev/
├── build.ps1                # build & đóng gói cho Windows / PowerShell
├── jni/
│   ├── CMakeLists.txt
│   ├── include/zygisk.hpp   # API v4 chính thức của topjohnwu
│   └── src/
│       ├── main.cpp             # entrypoint module (preApp/postApp specialize)
│       ├── config.{hpp,cpp}     # đọc /system/etc/hide_devmode/targets.txt
│       ├── hook_properties.*    # hook __system_property_get/__read_callback (Dobby)
│       ├── hook_settings.*      # hook Settings.{Global,Secure}.getInt qua JNIEnv vtable
│       └── logging.hpp
├── module/                  # nội dung copy thẳng vào /data/adb/modules/<id>/
│   ├── module.prop
│   ├── customize.sh
│   ├── service.sh
│   └── sepolicy.rule
└── external/Dobby/          # phải clone bằng tay - xem bên dưới
```

---

## 2. Chuẩn bị môi trường

### 2.1 Cài NDK (qua Android Studio)

Trong Android Studio → *SDK Manager* → tab **SDK Tools** → bật **NDK (Side by side)**
và **CMake**. Phiên bản tối thiểu khuyến nghị: NDK r25c, CMake 3.22.

Sau khi cài, đặt biến môi trường (PowerShell):

```powershell
[Environment]::SetEnvironmentVariable(
    'ANDROID_NDK_HOME',
    "$env:LOCALAPPDATA\Android\Sdk\ndk\26.1.10909125",
    'User')
```

### 2.2 Clone Dobby

Module dùng [Dobby](https://github.com/jmpews/Dobby) làm engine inline‑hook.

```powershell
git clone --depth=1 https://github.com/jmpews/Dobby.git external/Dobby
```

Nếu bỏ qua bước này, `build.ps1` sẽ tự clone giúp bạn.

---

## 3. Build

### Một lệnh duy nhất

```powershell
pwsh ./build.ps1                 # release, full 4 ABI
pwsh ./build.ps1 -BuildType Debug -ABIs arm64-v8a
```

Output: `dist\hide_devmode.zip` — flash bằng Magisk Manager / KernelSU Manager.

### Build qua Android Studio (tùy chọn)

Mở `jni/` như một dự án C++ (File → Open → chọn folder `jni`). Android Studio
sẽ nhận diện `CMakeLists.txt` và biên dịch đúng. Bạn có thể chỉnh **ABI Filters**
trong `Build Variants` để rút bớt thời gian.

---

## 4. Cài đặt & cấu hình

1. Flash `dist\hide_devmode.zip` qua Magisk hoặc KernelSU Manager.
2. Reboot.
3. Sửa danh sách app cần ẩn tại `/data/adb/modules/hide_devmode/system/etc/hide_devmode/targets.txt`
   (hoặc `/system/etc/hide_devmode/targets.txt` sau khi mount):

```
# Wildcard: áp dụng cho mọi app non-system
*
# Loại trừ một số app hệ thống / dev
!com.android.settings
!com.android.systemui
!com.google.android.gms

# Hoặc whitelist tường minh thay vì '*'
# com.example.bank
# com.example.game
```

4. Force‑stop các app đã liệt kê hoặc reboot để Zygote spawn lại tiến trình
   sạch và áp dụng hook.

---

## 5. Cách hoạt động

### 5.1 Vòng đời module trong Zygisk

```
Zygote fork()
   │
   ├── preAppSpecialize        ← lấy package_name, uid → quyết định có hook
   │      ├─ KHÔNG hook?       → setOption(DLCLOSE_MODULE_LIBRARY)  → .so bị
   │      │                       Zygisk dlclose ngay sau specialize
   │      └─ CÓ hook?          → giữ .so trong process
   │
   └── postAppSpecialize       ← cài hooks (libc + JNIEnv)
```

### 5.2 Tầng `libc`

Hook hai symbol export của bionic:

| Symbol | Vai trò |
|--------|---------|
| `__system_property_get`         | API cũ, hầu hết native code dùng |
| `__system_property_read_callback` | API mới, framework + libsystemproperties dùng |

Khi key trùng với `kOverrides[]` trong `hook_properties.cpp`, hàm trả về giá
trị giả định trong bảng. Bao gồm:

```
ro.debuggable                = 0
ro.secure                    = 1
init.svc.adbd                = stopped
sys.usb.state                = mtp
sys.usb.config               = mtp
sys.usb.ffs.ready            = 0
persist.sys.usb.config       = mtp
persist.sys.usb.reboot.func  = mtp
persist.adb.tls_server.enable = 0
... (xem mã nguồn để bổ sung)
```

### 5.3 Tầng Java/JNI

Settings DB API không phải method native, không thể `RegisterNatives` đè
trực tiếp. Vì vậy chúng ta chọn **patch JNIEnv vtable**:

- JNIEnv là pointer → `JNINativeInterface*` (≈ 230 con trỏ hàm).
- Index 141 = `CallStaticIntMethodV`, 142 = `CallStaticIntMethodA`.
- Cache jmethodID của `Settings$Global.getInt`, `Settings$Secure.getInt`,
  `Settings$System.getInt` (đủ 2/3 đối số).
- Khi `CallStaticIntMethodV/A` được gọi với một trong các jmethodID đó **và**
  `name` ∈ `{development_settings_enabled, adb_enabled, adb_wifi_enabled, …}`,
  trả về `0` ngay lập tức mà không gọi original.
- Mọi trường hợp khác forward nguyên si → không sai lệch hành vi.

Cách này:
- Bắt được **mọi caller native**, kể cả app gọi qua reflection thông qua
  `JNIEnv->CallStaticIntMethod*`.
- Java→Java direct (không qua JNI) sẽ không qua vtable này. Trong thực tế
  framework `Settings.getInt` luôn rơi xuống `ContentResolver.call` → JNI →
  `binder` nên hook tầng Java thuần không cần thiết, và chúng ta tránh được
  rủi ro patch ArtMethod (offset thay đổi theo từng phiên bản Android).

### 5.4 Hardening đã áp dụng

- `-fvisibility=hidden`, `--exclude-libs,ALL`, strip symbol release → giảm
  symbol leak.
- `LOG_TAG="zn_hdm"`, có thể tắt log với `-DMODULE_VERBOSE=0`.
- Không alloc trong hot path (bảng key dùng array static, so sánh `strcmp`).
- Hook idempotent (`std::atomic` guard) → tránh cài đôi nếu có cơ chế
  re‑initialize.
- Không bao giờ `DLCLOSE_MODULE_LIBRARY` ở nhánh có hook để tránh unmap
  trampoline → SIGSEGV.

---

## 6. Gỡ lỗi

```powershell
# Kết nối thiết bị qua adb (cần USB debugging trên thiết bị test)
adb logcat -s zn_hdm:V
```

Nếu không thấy log:
- Kiểm tra Zygisk đã bật (Magisk Manager) hoặc zygisk-next đã cài (KSU).
- `dmesg | grep zygisk` để xác nhận loader nạp module.
- Force‑stop ứng dụng hoặc reboot.

---

## 7. Mở rộng

- Thêm key vào `kOverrides[]` (thuộc tính) hoặc `kSpoofedKeys[]` (Settings DB)
  rồi rebuild.
- Để hỗ trợ thêm `Build.TAGS`, `Build.TYPE`, hook `__system_property_find` và
  `android.os.Build` static field.
- Để spoof `getprop` từ `Runtime.exec("getprop ...")`, cần thêm hook
  `execve`/`posix_spawn` — không bao gồm trong bản này.

---

## 8. Cảnh báo pháp lý

Module dùng cho mục đích nghiên cứu cá nhân, học tập về kỹ thuật runtime
hooking trên Android. KHÔNG sử dụng để vượt qua các kiểm tra an toàn của
ứng dụng tài chính, ngân hàng, hoặc các hệ thống bạn không sở hữu / không
có quyền hợp pháp truy cập. Tác giả không chịu trách nhiệm về hậu quả phát
sinh từ việc lạm dụng.
