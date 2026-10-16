use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const DATA_DIR: &str = "/data/adb/auto_toggle";
const CONF_FILE: &str = "/data/adb/auto_toggle/config.sh";
const RUNTIME_FILE: &str = "/data/adb/auto_toggle/runtime_state";
const LOG_FILE: &str = "/data/adb/auto_toggle/daemon.log";
const PROP_FILE: &str = "/data/adb/modules/auto_toggle/module.prop";
const LOCK_FILE: &str = "/dev/auto_toggle.lock";

#[derive(PartialEq, Clone, Copy, Debug)]
enum Mode {
    Auto,
    On,
    Off,
}

impl Mode {
    fn as_str(&self) -> &'static str {
        match self {
            Mode::Auto => "auto",
            Mode::On => "on",
            Mode::Off => "off",
        }
    }
}

#[derive(Clone, Debug)]
struct Config {
    mode: Mode,
    hide_dev_settings: bool,
    turn_off_wifi_adb: bool,
    only_unlocked: bool,
    notify: bool,
    debounce_ms: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            mode: Mode::Auto,
            // Sửa #1: Mặc định false để không làm mất menu Developer Options của dev
            hide_dev_settings: false,
            turn_off_wifi_adb: true,
            only_unlocked: false,
            notify: true,
            debounce_ms: 4000,
        }
    }
}

// -----------------------------------------------------------------------------
// 1. SINGLE-INSTANCE LOCK, ATOMIC WRITE & LOGGING (Sửa #2, #6)
// -----------------------------------------------------------------------------
fn acquire_instance_lock() -> Option<File> {
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(LOCK_FILE)
        .ok()?;

    let ret = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if ret != 0 {
        return None;
    }

    let _ = file.set_len(0);
    let _ = (&file).write_all(format!("{}\n", std::process::id()).as_bytes());
    Some(file)
}

fn atomic_write(target_path: &str, content: &str) -> io::Result<()> {
    let tmp_path = format!("{}.tmp.{}", target_path, std::process::id());
    {
        let mut f = File::create(&tmp_path)?;
        f.write_all(content.as_bytes())?;
        f.sync_all()?;
    }
    fs::rename(&tmp_path, target_path)
}

fn log_msg(msg: &str) {
    if let Ok(meta) = fs::metadata(LOG_FILE) {
        if meta.len() > 65536 {
            let _ = fs::rename(LOG_FILE, format!("{}.old", LOG_FILE));
        }
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(LOG_FILE) {
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(file, "[{}] [PID:{}] {}", ts, std::process::id(), msg);
    }
}

// -----------------------------------------------------------------------------
// 2. QUẢN LÝ CONFIG (Sửa #1)
// -----------------------------------------------------------------------------
fn ensure_default_config() {
    let _ = fs::create_dir_all(DATA_DIR);
    if !Path::new(CONF_FILE).exists() {
        let default_content = "\
# Chế độ: auto | on | off
MODE=auto

# 0 = Giữ nguyên menu Tùy chọn nhà phát triển (khuyên dùng cho Dev)
# 1 = Ẩn luôn menu Tùy chọn nhà phát triển mỗi khi tắt ADB
HIDE_DEV_SETTINGS=0

# 1 = Tắt luôn ADB Wi-Fi khi tắt ADB
TURN_OFF_WIFI_ADB=1

# 1 = Chỉ bật ADB khi màn hình đã mở khóa
ONLY_UNLOCKED=0

# 1 = Hiển thị thông báo khi chuyển trạng thái
NOTIFY=1

# Thời gian trễ (ms) trước khi tắt ADB lúc mất tín hiệu USB (chống USB re-enumerate)
DEBOUNCE_MS=4000
";
        if let Err(e) = atomic_write(CONF_FILE, default_content) {
            log_msg(&format!("Không thể tạo config mặc định: {}", e));
        }
    }
}

fn load_config() -> Config {
    let mut cfg = Config::default();
    if let Ok(content) = fs::read_to_string(CONF_FILE) {
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                let key = k.trim();
                let val = v.trim().trim_matches('"').trim_matches('\'');
                match key {
                    "MODE" => {
                        cfg.mode = match val {
                            "on" => Mode::On,
                            "off" => Mode::Off,
                            _ => Mode::Auto,
                        }
                    }
                    "HIDE_DEV_SETTINGS" => cfg.hide_dev_settings = val == "1",
                    "TURN_OFF_WIFI_ADB" => cfg.turn_off_wifi_adb = val == "1",
                    "ONLY_UNLOCKED" => cfg.only_unlocked = val == "1",
                    "NOTIFY" => cfg.notify = val == "1",
                    "DEBOUNCE_MS" => {
                        if let Ok(ms) = val.parse::<u64>() {
                            cfg.debounce_ms = ms;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    cfg
}

// -----------------------------------------------------------------------------
// 3. PHÁT HIỆN KẾT NỐI PC QUA SYSFS
// -----------------------------------------------------------------------------
fn read_trimmed(path: &Path) -> Option<String> {
    let mut s = String::with_capacity(64);
    File::open(path).ok()?.read_to_string(&mut s).ok()?;
    Some(s.trim().to_string())
}

fn is_usb_pc() -> bool {
    // 1. Kiểm tra UDC state (/sys/class/udc/*/state)
    if let Ok(entries) = fs::read_dir("/sys/class/udc") {
        for entry in entries.flatten() {
            let state_path = entry.path().join("state");
            if let Some(st) = read_trimmed(&state_path) {
                if st == "configured" || st == "addressed" {
                    return true;
                }
            }
        }
    }

    // 2. Kiểm tra power_supply real_type
    if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
        for entry in entries.flatten() {
            let rt_path = entry.path().join("real_type");
            if let Some(rt) = read_trimmed(&rt_path) {
                if matches!(rt.as_str(), "USB" | "USB_CDP" | "SDP" | "CDP") {
                    return true;
                }
            }
        }
    }

    // 3. Kiểm tra Type-C data_role khớp chính xác "[device]" + nguồn USB online
    if let Ok(entries) = fs::read_dir("/sys/class/typec") {
        for entry in entries.flatten() {
            let role_path = entry.path().join("data_role");
            if let Some(role) = read_trimmed(&role_path) {
                if role.contains("[device]") {
                    let usb_online = read_trimmed(Path::new("/sys/class/power_supply/usb/online"))
                        .unwrap_or_default();
                    if usb_online == "1" {
                        return true;
                    }
                }
            }
        }
    }

    false
}

fn is_device_unlocked(only_unlocked: bool) -> bool {
    if !only_unlocked {
        return true;
    }
    match Command::new("dumpsys").args(["window", "policy"]).output() {
        Ok(out) if out.status.success() => {
            let s = String::from_utf8_lossy(&out.stdout);
            !(s.contains("mShowingLockscreen=true") || s.contains("isStatusBarKeyguard=true"))
        }
        Ok(out) => {
            log_msg(&format!(
                "Cảnh báo: dumpsys window policy trả về mã lỗi {:?}",
                out.status.code()
            ));
            true
        }
        Err(e) => {
            log_msg(&format!("Cảnh báo: không chạy được dumpsys: {}", e));
            true
        }
    }
}

// -----------------------------------------------------------------------------
// 4. THỰC THI LỆNH CÓ KIỂM TRA LỖI & ATOMIC UPDATE (Sửa #5, #6)
// -----------------------------------------------------------------------------
fn run_cmd(prog: &str, args: &[&str]) -> bool {
    match Command::new(prog).args(args).output() {
        Ok(out) => {
            if !out.status.success() {
                let stderr = String::from_utf8_lossy(&out.stderr);
                log_msg(&format!(
                    "LỖI lệnh `{} {}` (exit={:?}): {}",
                    prog,
                    args.join(" "),
                    out.status.code(),
                    stderr.trim()
                ));
                return false;
            }
            true
        }
        Err(e) => {
            log_msg(&format!(
                "LỖI thực thi `{} {}`: {}",
                prog,
                args.join(" "),
                e
            ));
            false
        }
    }
}

fn put_global_setting(key: &str, val: &str) -> bool {
    run_cmd("settings", &["put", "global", key, val])
}

fn get_prop(key: &str) -> String {
    Command::new("getprop")
        .arg(key)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn send_notification(enable: bool, msg: &str) {
    if !enable {
        return;
    }
    if let Err(e) = Command::new("cmd")
        .args([
            "notification",
            "post",
            "-S",
            "bigtext",
            "-t",
            "AutoToggle ADB",
            "adbtoggle_rust",
            msg,
        ])
        .spawn()
    {
        log_msg(&format!("Không thể gửi thông báo: {}", e));
    }
}

fn update_module_status(state_on: bool, mode: Mode, reason: &str) {
    let state_str = if state_on { "on" } else { "off" };
    let runtime_data = format!(
        "STATE={}\nMODE={}\nREASON={}\n",
        state_str,
        mode.as_str(),
        reason
    );
    if let Err(e) = atomic_write(RUNTIME_FILE, &runtime_data) {
        log_msg(&format!("Lỗi ghi runtime_state: {}", e));
    }

    if let Ok(content) = fs::read_to_string(PROP_FILE) {
        let badge = if state_on { "ADB: [BẬT]" } else { "ADB: [TẮT]" };
        let new_desc = format!(
            "description={} ({}) · Chế độ: {}",
            badge,
            reason,
            mode.as_str()
        );
        let updated: Vec<String> = content
            .lines()
            .map(|line| {
                if line.starts_with("description=") {
                    new_desc.clone()
                } else {
                    line.to_string()
                }
            })
            .collect();
        if let Err(e) = atomic_write(PROP_FILE, &(updated.join("\n") + "\n")) {
            log_msg(&format!("Lỗi cập nhật module.prop: {}", e));
        }
    }
}

/// Trả về `true` nếu chuyển trạng thái thành công, `false` nếu lệnh cốt lõi bị lỗi cần retry
fn apply_state(turn_on: bool, cfg: &Config, reason: &str) -> bool {
    if turn_on {
        log_msg(&format!(
            "Đang BẬT ADB (Lý do: {}, Mode: {})",
            reason,
            cfg.mode.as_str()
        ));
        if cfg.hide_dev_settings {
            let _ = put_global_setting("development_settings_enabled", "1");
        }
        if !put_global_setting("adb_enabled", "1") {
            log_msg("BẬT ADB thất bại (settings put trả lỗi), sẽ thử lại ở chu kỳ sau.");
            return false;
        }

        std::thread::sleep(Duration::from_millis(800));
        if get_prop("init.svc.adbd") != "running" {
            let _ = run_cmd("start", &["adbd"]);
        }
        update_module_status(true, cfg.mode, reason);
        send_notification(cfg.notify, &format!("ADB: Đã BẬT ({})", reason));
        true
    } else {
        log_msg(&format!(
            "Đang TẮT ADB (Lý do: {}, Mode: {})",
            reason,
            cfg.mode.as_str()
        ));
        if !put_global_setting("adb_enabled", "0") {
            log_msg("TẮT ADB thất bại (settings put trả lỗi), sẽ thử lại ở chu kỳ sau.");
            return false;
        }
        if cfg.turn_off_wifi_adb {
            let _ = put_global_setting("adb_wifi_enabled", "0");
        }
        if cfg.hide_dev_settings {
            let _ = put_global_setting("development_settings_enabled", "0");
        }

        std::thread::sleep(Duration::from_millis(800));
        if get_prop("init.svc.adbd") == "running" {
            let _ = run_cmd("stop", &["adbd"]);
        }
        update_module_status(false, cfg.mode, reason);
        send_notification(cfg.notify, &format!("ADB: Đã TẮT ({})", reason));
        true
    }
}

// -----------------------------------------------------------------------------
// 5. NETLINK UEVENT FILTERING & INOTIFY (Sửa #4, #7)
// -----------------------------------------------------------------------------
fn open_uevent_socket() -> RawFd {
    unsafe {
        let fd = libc::socket(
            libc::AF_NETLINK,
            libc::SOCK_DGRAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            libc::NETLINK_KOBJECT_UEVENT,
        );
        if fd < 0 {
            log_msg(&format!(
                "CẢNH BÁO: Không thể mở Netlink socket (errno={}). Chuyển sang fallback polling 2s.",
                io::Error::last_os_error()
            ));
            return -1;
        }

        let mut addr: libc::sockaddr_nl = std::mem::zeroed();
        addr.nl_family = libc::AF_NETLINK as libc::sa_family_t;
        addr.nl_pid = std::process::id();
        addr.nl_groups = 1;

        if libc::bind(
            fd,
            &addr as *const _ as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
        ) < 0
        {
            log_msg(&format!(
                "CẢNH BÁO: Không thể bind Netlink socket (errno={}). Có thể bị SELinux chặn. Chuyển sang fallback polling 2s.",
                io::Error::last_os_error()
            ));
            libc::close(fd);
            return -1;
        }
        fd
    }
}

fn open_config_inotify() -> RawFd {
    unsafe {
        let fd = libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC);
        if fd < 0 {
            log_msg(&format!(
                "CẢNH BÁO: inotify_init1 thất bại (errno={})",
                io::Error::last_os_error()
            ));
            return -1;
        }
        if let Ok(c_path) = std::ffi::CString::new(DATA_DIR) {
            if libc::inotify_add_watch(
                fd,
                c_path.as_ptr(),
                libc::IN_MODIFY | libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO | libc::IN_CREATE,
            ) < 0
            {
                log_msg(&format!(
                    "CẢNH BÁO: inotify_add_watch thất bại trên {} (errno={})",
                    DATA_DIR,
                    io::Error::last_os_error()
                ));
            }
        }
        fd
    }
}

/// Kiểm tra một gói tin uevent có thực sự liên quan tới cổng USB / cáp sạc hay không.
/// Loại bỏ các sự kiện gây nhiễu như pin tụt %, nhiệt độ, đèn nền, wifi...
fn is_usb_relevant_packet(pkt: &[u8]) -> bool {
    let mut is_usb_subsys = false;
    let mut is_power_supply = false;
    let mut is_battery_gauge = false;

    for field in pkt.split(|&b| b == 0) {
        if field.is_empty() {
            continue;
        }
        if matches!(
            field,
            b"SUBSYSTEM=usb"
                | b"SUBSYSTEM=typec"
                | b"SUBSYSTEM=udc"
                | b"SUBSYSTEM=android_usb"
                | b"SUBSYSTEM=dual_role_usb"
        ) {
            is_usb_subsys = true;
        } else if field == b"SUBSYSTEM=power_supply" {
            is_power_supply = true;
        } else if field == b"POWER_SUPPLY_NAME=battery" || field == b"POWER_SUPPLY_NAME=bms" {
            is_battery_gauge = true;
        }
    }

    is_usb_subsys || (is_power_supply && !is_battery_gauge)
}

/// Đọc cạn buffer uevent và trả về `true` nếu có ít nhất 1 gói tin liên quan tới USB
fn drain_and_filter_uevent(fd: RawFd) -> bool {
    let mut buf = [0u8; 4096];
    let mut found_usb_event = false;
    unsafe {
        loop {
            let n = libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len());
            if n <= 0 {
                break;
            }
            if !found_usb_event && is_usb_relevant_packet(&buf[..n as usize]) {
                found_usb_event = true;
            }
        }
    }
    found_usb_event
}

fn drain_fd(fd: RawFd) {
    let mut buf = [0u8; 2048];
    unsafe {
        while libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) > 0 {}
    }
}

// -----------------------------------------------------------------------------
// 6. VÒNG LẶP CHÍNH
// -----------------------------------------------------------------------------
fn main() {
    // 1. Giữ khóa flock suốt thời gian chạy để chống trùng tiến trình (Sửa #2)
    let _lock_guard = match acquire_instance_lock() {
        Some(f) => f,
        None => {
            eprintln!("AutoToggle Daemon đã có tiến trình khác đang chạy. Thoát.");
            std::process::exit(0);
        }
    };

    ensure_default_config();
    log_msg("Khởi chạy AutoToggle Rust Daemon v2.1");

    let uevent_fd = open_uevent_socket();
    let inotify_fd = open_config_inotify();

    let mut current_state: Option<bool> = None;
    let mut last_mode: Option<Mode> = None;
    let mut disconnect_deadline: Option<Instant> = None;
    let mut retry_needed = false;

    loop {
        let cfg = load_config();
        let usb_connected = is_usb_pc();

        let (want_on, reason) = match cfg.mode {
            Mode::On => {
                disconnect_deadline = None;
                (true, "Thủ công: Luôn bật")
            }
            Mode::Off => {
                disconnect_deadline = None;
                (false, "Thủ công: Luôn tắt")
            }
            Mode::Auto => {
                if usb_connected {
                    disconnect_deadline = None;
                    if is_device_unlocked(cfg.only_unlocked) {
                        (true, "Đang cắm PC")
                    } else {
                        (current_state.unwrap_or(false), "Chờ mở khóa màn hình")
                    }
                } else if current_state == Some(true) {
                    let now = Instant::now();
                    let deadline = *disconnect_deadline
                        .get_or_insert_with(|| now + Duration::from_millis(cfg.debounce_ms));
                    if now >= deadline {
                        disconnect_deadline = None;
                        (false, "Đã rút cáp PC")
                    } else {
                        (true, "Giữ kết nối (Debounce)")
                    }
                } else {
                    disconnect_deadline = None;
                    (false, "Không cắm PC")
                }
            }
        };

        if current_state != Some(want_on) {
            if apply_state(want_on, &cfg, reason) {
                current_state = Some(want_on);
                last_mode = Some(cfg.mode);
                retry_needed = false;
            } else {
                // Lệnh settings put thất bại (VD: binder chưa sẵn sàng lúc mới boot), hẹn thử lại sau 2s
                retry_needed = true;
            }
        } else if last_mode != Some(cfg.mode) {
            update_module_status(want_on, cfg.mode, reason);
            last_mode = Some(cfg.mode);
        }

        // Vòng chờ sự kiện: bỏ qua hoàn toàn các uevent rác mà không quét lại sysfs (Sửa #4)
        loop {
            let timeout_ms: libc::c_int = if retry_needed {
                2000
            } else if let Some(deadline) = disconnect_deadline {
                let now = Instant::now();
                if deadline > now {
                    (deadline - now).as_millis() as libc::c_int + 50
                } else {
                    break;
                }
            } else if uevent_fd < 0 {
                2000
            } else {
                -1
            };

            let mut fds = [
                libc::pollfd {
                    fd: uevent_fd,
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: inotify_fd,
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];

            let ret = unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout_ms) };
            if ret == 0 {
                // Hết thời gian chờ (Debounce hoặc Retry hoặc Fallback 2s) -> Ra ngoài đánh giá lại
                break;
            } else if ret > 0 {
                let mut should_rescan = false;

                if fds[0].revents & libc::POLLIN != 0 {
                    if drain_and_filter_uevent(uevent_fd) {
                        // Chỉ sleep 150ms khi đúng là sự kiện USB/Sạc để chờ node sysfs ổn định
                        std::thread::sleep(Duration::from_millis(150));
                        should_rescan = true;
                    }
                }
                if fds[1].revents & libc::POLLIN != 0 {
                    drain_fd(inotify_fd);
                    should_rescan = true;
                }

                if should_rescan {
                    break;
                }
                // Nếu chỉ là uevent rác (pin tụt %, nhiệt độ, đèn nền) -> Tiếp tục nằm trong poll()!
            } else {
                // Khi poll() bị ngắt bởi signal (EINTR)
                std::thread::sleep(Duration::from_millis(200));
                break;
            }
        }
    }
}