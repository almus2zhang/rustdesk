// USB Secondary Display Auto-Detector and Virtual Monitor Manager
// Detects USB connected Android tablets/devices, automatically reads direct IP access port
// from configuration, performs AOA protocol switching, and triggers tablet accessory intent.

use hbb_common::{config::Config, log, ResultType};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

#[cfg(windows)]
use crate::virtual_display_manager;

lazy_static::lazy_static! {
    static ref USB_DISPLAY_ACTIVE: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
    static ref USB_DISPLAY_INDEX: Arc<Mutex<Option<u32>>> = Arc::new(Mutex::new(None));
    static ref USB_DISPLAY_DEVICE_NAME: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
}

/// Check if USB secondary display is currently active
pub fn is_usb_display_active() -> bool {
    USB_DISPLAY_ACTIVE.load(Ordering::SeqCst)
}

/// Get the device name (e.g. \\.\DISPLAY3) of the active USB virtual display
pub fn get_usb_display_device_name() -> Option<String> {
    USB_DISPLAY_DEVICE_NAME.lock().unwrap().clone()
}

/// Check whether a given monitor display name is the USB virtual display
pub fn is_this_usb_display(name: &str) -> bool {
    if let Some(dev_name) = USB_DISPLAY_DEVICE_NAME.lock().unwrap().as_ref() {
        if name == dev_name || dev_name.contains(name) || name.contains(dev_name) {
            return true;
        }
    }
    #[cfg(windows)]
    {
        crate::virtual_display_manager::is_virtual_display(name)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Read configured direct access port dynamically from config (fallback to 21118)
pub fn get_configured_direct_port() -> i32 {
    let mut port = Config::get_option("direct-access-port")
        .parse::<i32>()
        .unwrap_or(0);
    if port <= 0 {
        port = hbb_common::config::RENDEZVOUS_PORT + 2; // Default 21118
    }
    port
}

/// Request to plug in a virtual display specifically configured for USB tablet
pub fn plug_in_usb_display(width: u32, height: u32) -> ResultType<u32> {
    #[cfg(windows)]
    {
        let mut idx_lock = USB_DISPLAY_INDEX.lock().unwrap();
        if let Some(idx) = *idx_lock {
            log::info!("USB display already plugged in with index {}", idx);
            if let Some(dev_name) = USB_DISPLAY_DEVICE_NAME.lock().unwrap().as_ref() {
                virtual_display_manager::rustdesk_idd::change_resolution_if_is_virtual_display(dev_name, width, height);
                crate::platform::change_resolution(dev_name, width as usize, height as usize).ok();
            }
            return Ok(idx);
        }

        log::info!("Plugging in USB secondary display with mode {}x{}", width, height);
        let modes = vec![vec![
            virtual_display::MonitorMode {
                width,
                height,
                sync: 60,
            },
            virtual_display::MonitorMode {
                width,
                height,
                sync: 120,
            },
            virtual_display::MonitorMode {
                width: 1920,
                height: 1080,
                sync: 60,
            },
        ]];

        let indices = virtual_display_manager::plug_in_peer_request(modes)?;
        if let Some(&first_idx) = indices.first() {
            *idx_lock = Some(first_idx);
            USB_DISPLAY_ACTIVE.store(true, Ordering::SeqCst);
            if let Some(dev_name) = virtual_display_manager::get_device_name_by_peer_index(first_idx) {
                *USB_DISPLAY_DEVICE_NAME.lock().unwrap() = Some(dev_name.clone());
                crate::platform::change_resolution(&dev_name, width as usize, height as usize).ok();
            }
            log::info!("Successfully plugged in USB secondary display (index: {})", first_idx);
            return Ok(first_idx);
        } else {
            hbb_common::bail!("Failed to acquire virtual display index for USB display");
        }
    }
    #[cfg(not(windows))]
    {
        hbb_common::bail!("USB secondary display only supported on Windows host");
    }
}

/// Request to plug out the virtual display when USB disconnected
pub fn plug_out_usb_display() -> ResultType<()> {
    #[cfg(windows)]
    {
        let mut idx_lock = USB_DISPLAY_INDEX.lock().unwrap();
        if let Some(idx) = idx_lock.take() {
            log::info!("Plugging out USB secondary display (index: {})", idx);
            virtual_display_manager::plug_out_monitor_indices(&[idx], false, true)?;
        }
        USB_DISPLAY_DEVICE_NAME.lock().unwrap().take();
        USB_DISPLAY_ACTIVE.store(false, Ordering::SeqCst);
        Ok(())
    }
    #[cfg(not(windows))]
    {
        Ok(())
    }
}

/// Start background listener loop for USB secondary display status and auto-probing
pub fn start_usb_display_service() {
    #[cfg(windows)]
    {
        use std::sync::Once;
        static START_ONCE: Once = Once::new();
        START_ONCE.call_once(|| {
            thread::spawn(|| {
                log::info!("USB secondary display monitor service started");
                let mut last_detected_device = false;
                let mut missed_counts = 0;
                loop {
                    // Poll at 2-second interval
                    thread::sleep(Duration::from_millis(2000));

                    let has_device = check_android_usb_present();
                    if has_device {
                        missed_counts = 0;
                        if !last_detected_device {
                            log::info!("Android USB device attachment detected! Initiating handshake and reverse port map...");
                            last_detected_device = true;
                            trigger_usb_device_handshake();
                        }
                    } else if last_detected_device {
                        missed_counts += 1;
                        // Debounce disconnect: require 3 consecutive misses (6 seconds) before treating as detached
                        if missed_counts >= 3 {
                            log::info!("Android USB device detached. Cleaning up secondary display...");
                            last_detected_device = false;
                            missed_counts = 0;
                            plug_out_usb_display().ok();
                        }
                    }
                }
            });
        });
    }
}

#[cfg(windows)]
fn get_adb_path() -> Option<PathBuf> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    // 0. Explicit user config or environment variable
    let cfg_adb = Config::get_option("adb-path");
    if !cfg_adb.is_empty() {
        let p = PathBuf::from(&cfg_adb);
        if p.is_file() {
            return Some(p);
        } else if p.join("adb.exe").is_file() {
            return Some(p.join("adb.exe"));
        }
    }
    if let Ok(env_adb) = std::env::var("ADB_PATH") {
        let p = PathBuf::from(&env_adb);
        if p.is_file() {
            return Some(p);
        } else if p.join("adb.exe").is_file() {
            return Some(p.join("adb.exe"));
        }
    }

    // 1. Common custom directories (including C:\adbtool)
    let custom_paths = [
        "C:\\adbtool\\adb.exe",
        "C:\\adbtools\\adb.exe",
        "C:\\adb\\adb.exe",
        "D:\\adbtool\\adb.exe",
        "D:\\adbtools\\adb.exe",
        "D:\\adb\\adb.exe",
    ];
    for &p in &custom_paths {
        let path = PathBuf::from(p);
        if path.exists() {
            log::info!("Found adb at custom path: {}", p);
            return Some(path);
        }
    }

    // 2. Try PATH
    if let Ok(out) = Command::new("adb")
        .arg("version")
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    {
        if out.status.success() {
            return Some(PathBuf::from("adb"));
        }
    }

    // 3. Try common Android SDK platform-tools locations
    if let Ok(local_app_data) = std::env::var("LOCALAPPDATA") {
        let p = Path::new(&local_app_data)
            .join("Android")
            .join("Sdk")
            .join("platform-tools")
            .join("adb.exe");
        if p.exists() {
            return Some(p);
        }
    }
    if let Ok(user_profile) = std::env::var("USERPROFILE") {
        let p = Path::new(&user_profile)
            .join("AppData")
            .join("Local")
            .join("Android")
            .join("Sdk")
            .join("platform-tools")
            .join("adb.exe");
        if p.exists() {
            return Some(p);
        }
    }
    None
}

#[derive(Debug, Clone)]
struct AdbDevice {
    serial: String,
    state: String,
}

#[cfg(windows)]
fn get_adb_devices(adb: &Path) -> Vec<AdbDevice> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let mut list = Vec::new();
    if let Ok(out) = Command::new(adb)
        .arg("devices")
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines().skip(1) {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 {
                list.push(AdbDevice {
                    serial: parts[0].to_string(),
                    state: parts[1].to_string(),
                });
            }
        }
    }
    list
}

#[cfg(windows)]
fn check_android_usb_present() -> bool {
    let adb = match get_adb_path() {
        Some(p) => p,
        None => return false,
    };
    let devices = get_adb_devices(&adb);
    // Any attached device line in adb devices (including offline or unauthorized) indicates physical connection
    !devices.is_empty()
}

#[cfg(windows)]
fn execute_usb_handshake(adb: &PathBuf) -> Result<String, String> {
    use std::io::Write;
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    // 0. Ensure adb server is running
    let _ = Command::new(adb)
        .arg("start-server")
        .creation_flags(CREATE_NO_WINDOW)
        .status();

    // 1. Kick offline devices if any
    let _ = Command::new(adb)
        .args(["reconnect", "offline"])
        .creation_flags(CREATE_NO_WINDOW)
        .status();

    // 2. Perform interactive shell kick (spawning adb shell with stdin writing exit\n).
    // This is crucial: entering an adb shell requests the 'shell:' service from adbd,
    // which prompts Android to wake the transport, negotiate auth, and transition out of offline state.
    if let Ok(mut child) = Command::new(adb)
        .arg("shell")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
    {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(b"echo rustdesk_awake\nexit\n");
            let _ = stdin.flush();
        }
        let start = Instant::now();
        while start.elapsed() < Duration::from_millis(2000) {
            if let Ok(Some(_)) = child.try_wait() {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        let _ = child.kill();
    }

    // 3. Wait for device to become online ('device' state) (up to 8 seconds)
    let mut online_serial: Option<String> = None;
    let mut is_unauthorized = false;
    let mut last_devices = Vec::new();
    let poll_start = Instant::now();

    while poll_start.elapsed() < Duration::from_millis(8000) {
        last_devices = get_adb_devices(adb);
        for dev in &last_devices {
            if dev.state == "device" {
                online_serial = Some(dev.serial.clone());
                break;
            } else if dev.state == "unauthorized" {
                is_unauthorized = true;
            }
        }
        if online_serial.is_some() {
            break;
        }
        thread::sleep(Duration::from_millis(400));
    }

    let serial = match online_serial {
        Some(s) => s,
        None => {
            if is_unauthorized {
                return Err("检测到平板设备未授权 (unauthorized)，请在平板屏幕上勾选【始终允许此计算机进行调试】并点击【确定】".to_string());
            } else if !last_devices.is_empty() {
                return Err(format!("检测到设备但状态异常 ({:?})，请在平板上重新插拔 USB 或重新开启【USB 调试】", last_devices[0].state));
            } else {
                return Err("未检测到已连接的 Android 设备，请检查 USB 数据线并确保平板已开启【USB 调试】".to_string());
            }
        }
    };

    log::info!("ADB online device confirmed: {}", serial);

    let run_adb = |args: &[&str]| {
        let mut full_args = vec!["-s", &serial];
        full_args.extend_from_slice(args);
        Command::new(adb)
            .args(&full_args)
            .creation_flags(CREATE_NO_WINDOW)
            .status()
    };

    // 4. Wake screen if asleep and dismiss keyguard
    let _ = run_adb(&["shell", "input", "keyevent", "224"]);
    let _ = run_adb(&["shell", "wm", "dismiss-keyguard"]);

    // 5. Configure ADB reverse mappings
    let direct_port = get_configured_direct_port();
    log::info!("Configuring ADB reverse on {} for direct port: {}", serial, direct_port);
    let port_str = direct_port.to_string();
    let mut ports = vec![port_str.as_str()];
    for p in ["21118", "34567", "21116"] {
        if !ports.contains(&p) {
            ports.push(p);
        }
    }

    for port in ports {
        let tcp_str = format!("tcp:{}", port);
        let status = run_adb(&["reverse", &tcp_str, &tcp_str]);
        match status {
            Ok(s) if s.success() => {
                log::info!("ADB reverse tcp:{} -> tcp:{} succeeded on {}", port, port, serial);
            }
            Ok(s) => {
                log::warn!("ADB reverse tcp:{} returned exit code: {:?}", port, s.code());
            }
            Err(e) => {
                log::error!("Failed to execute adb reverse for tcp:{}: {}", port, e);
                return Err(format!("ADB 端口反向映射 tcp:{} 失败: {}", port, e));
            }
        }
    }

    // 6. Send intent to awaken tablet with prompt dialog and port info
    log::info!("Awakening tablet RustDesk via intent with port {}...", direct_port);
    let start_status = Command::new(adb)
        .args([
            "-s",
            &serial,
            "shell",
            "am",
            "start",
            "-a",
            "com.rustdesk.ACTION_USB_DISPLAY",
            "-n",
            "com.carriez.flutter_hbb/.MainActivity",
            "--es",
            "port",
            &direct_port.to_string(),
            "-f",
            "0x10000000",
            "-W",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .status();

    match start_status {
        Ok(s) if s.success() => {
            log::info!("Tablet activity launched successfully via ADB");
            Ok("已成功向 USB 平板发送唤醒与副屏连接请求！".to_string())
        }
        Ok(s) => {
            log::warn!("am start returned code: {:?}", s.code());
            Ok("已发送副屏连接指令，但启动响应异常，请检查平板".to_string())
        }
        Err(e) => {
            Err(format!("启动平板应用失败: {}", e))
        }
    }
}

#[cfg(windows)]
fn trigger_usb_device_handshake() {
    thread::spawn(|| {
        if let Some(adb) = get_adb_path() {
            if let Err(e) = execute_usb_handshake(&adb) {
                log::error!("USB device handshake failed: {}", e);
            }
        } else {
            log::warn!("adb executable not found; skipping USB device handshake");
        }
    });
}

#[cfg(windows)]
pub fn manual_wake_usb_device() -> String {
    let adb = match get_adb_path() {
        Some(p) => p,
        None => {
            return "未找到 ADB 工具。请确认 C:\\adbtool\\adb.exe 存在，或设置环境变量 ADB_PATH".to_string();
        }
    };

    match execute_usb_handshake(&adb) {
        Ok(msg) => msg,
        Err(err) => err,
    }
}

#[cfg(windows)]
pub fn restart_adb_service() -> String {
    let adb = match get_adb_path() {
        Some(p) => p,
        None => return "未找到 ADB 工具".to_string(),
    };
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let _ = Command::new(&adb)
        .arg("kill-server")
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    let _ = Command::new(&adb)
        .arg("start-server")
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    let devices = get_adb_devices(&adb);
    if devices.is_empty() {
        "ADB 服务已强制重启，当前未检测到已连接的设备".to_string()
    } else {
        let dev_summary = devices
            .iter()
            .map(|d| format!("{}: {}", d.serial, d.state))
            .collect::<Vec<_>>()
            .join(", ");
        format!("ADB 服务重启成功！在线设备: {}", dev_summary)
    }
}

#[cfg(not(windows))]
pub fn manual_wake_usb_device() -> String {
    "当前系统不支持 USB 平板唤醒".to_string()
}

#[cfg(not(windows))]
pub fn restart_adb_service() -> String {
    "当前系统不支持重启 ADB 服务".to_string()
}
