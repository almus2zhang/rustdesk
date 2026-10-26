// USB Secondary Display Auto-Detector and Virtual Monitor Manager
// Detects USB connected Android tablets/devices, automatically reads direct IP access port
// from configuration, performs AOA protocol switching, and triggers tablet accessory intent.

use hbb_common::{config::Config, log, ResultType};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

#[cfg(windows)]
use crate::virtual_display_manager;

lazy_static::lazy_static! {
    static ref USB_DISPLAY_ACTIVE: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
    static ref USB_DISPLAY_INDEX: Arc<Mutex<Option<u32>>> = Arc::new(Mutex::new(None));
}

/// Check if USB secondary display is currently active
pub fn is_usb_display_active() -> bool {
    USB_DISPLAY_ACTIVE.load(Ordering::SeqCst)
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
                    // Poll at 2-second interval to prevent adb lock contention
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
fn get_adb_path() -> Option<std::path::PathBuf> {
    use std::process::Command;
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    // 0. Explicit user config or environment variable
    let cfg_adb = Config::get_option("adb-path");
    if !cfg_adb.is_empty() {
        let p = std::path::PathBuf::from(&cfg_adb);
        if p.is_file() {
            return Some(p);
        } else if p.join("adb.exe").is_file() {
            return Some(p.join("adb.exe"));
        }
    }
    if let Ok(env_adb) = std::env::var("ADB_PATH") {
        let p = std::path::PathBuf::from(&env_adb);
        if p.is_file() {
            return Some(p);
        } else if p.join("adb.exe").is_file() {
            return Some(p.join("adb.exe"));
        }
    }

    // 1. Common custom directories (including user's C:\adbtool)
    let custom_paths = [
        "C:\\adbtool\\adb.exe",
        "C:\\adbtools\\adb.exe",
        "C:\\adb\\adb.exe",
        "D:\\adbtool\\adb.exe",
        "D:\\adbtools\\adb.exe",
        "D:\\adb\\adb.exe",
    ];
    for &p in &custom_paths {
        let path = std::path::PathBuf::from(p);
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
            return Some(std::path::PathBuf::from("adb"));
        }
    }

    // 3. Try common Android SDK platform-tools locations
    if let Ok(local_app_data) = std::env::var("LOCALAPPDATA") {
        let p = std::path::Path::new(&local_app_data)
            .join("Android")
            .join("Sdk")
            .join("platform-tools")
            .join("adb.exe");
        if p.exists() {
            return Some(p);
        }
    }
    if let Ok(user_profile) = std::env::var("USERPROFILE") {
        let p = std::path::Path::new(&user_profile)
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

#[cfg(windows)]
fn check_android_usb_present() -> bool {
    use std::process::Command;
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let adb = match get_adb_path() {
        Some(p) => p,
        None => return false,
    };

    let output = Command::new(&adb)
        .arg("devices")
        .creation_flags(CREATE_NO_WINDOW)
        .output();

    if let Ok(out) = output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines().skip(1) {
            let line = line.trim();
            if !line.is_empty() && line.contains("device") && !line.contains("offline") {
                return true;
            }
        }
    }
    false
}

#[cfg(windows)]
fn trigger_usb_device_handshake() {
    thread::spawn(|| {
        use std::process::Command;
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;

        let adb = match get_adb_path() {
            Some(p) => p,
            None => {
                log::warn!("adb executable not found; skipping USB device reverse mapping");
                return;
            }
        };

        // Dynamically get the configured direct access port
        let direct_port = get_configured_direct_port();
        log::info!("Configuring ADB reverse for direct port: {}", direct_port);
        
        let port_str = direct_port.to_string();
        let mut ports = vec![port_str.as_str()];
        if !ports.contains(&"21118") {
            ports.push("21118");
        }
        if !ports.contains(&"34567") {
            ports.push("34567");
        }
        if !ports.contains(&"21116") {
            ports.push("21116");
        }

        for port in ports {
            let _ = Command::new(&adb)
                .args(["reverse", &format!("tcp:{}", port), &format!("tcp:{}", port)])
                .creation_flags(CREATE_NO_WINDOW)
                .status();
        }

        // Send broadcast or intent to awaken tablet with prompt dialog and port info
        log::info!("Awakening tablet RustDesk with accessory attached intent and port {}...", direct_port);
        let _ = Command::new(&adb)
            .args([
                "shell",
                "am",
                "start",
                "-a",
                "android.hardware.usb.action.USB_ACCESSORY_ATTACHED",
                "-n",
                "com.carriez.flutter_hbb/.MainActivity",
                "--es",
                "port",
                &direct_port.to_string(),
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .status();

        // Also trigger explicit custom action
        let _ = Command::new(&adb)
            .args([
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
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .status();
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

    use std::process::Command;
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let output = match Command::new(&adb)
        .arg("devices")
        .creation_flags(CREATE_NO_WINDOW)
        .output() {
            Ok(o) => o,
            Err(e) => return format!("执行 adb devices 失败: {}", e),
        };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut device_found = false;
    let mut unauthorized = false;
    for line in stdout.lines().skip(1) {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line.contains("unauthorized") {
            unauthorized = true;
        } else if line.contains("device") && !line.contains("offline") {
            device_found = true;
            break;
        }
    }

    if !device_found {
        if unauthorized {
            return "检测到平板设备未授权 (unauthorized)，请在平板屏幕上点击【始终允许此计算机进行调试】".to_string();
        } else {
            return "未检测到已连接的 Android 设备，请检查 USB 数据线并确保平板已开启【USB 调试】".to_string();
        }
    }

    // 1. Wake screen if asleep
    let _ = Command::new(&adb)
        .args(["shell", "input", "keyevent", "224"])
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    // 2. Dismiss keyguard
    let _ = Command::new(&adb)
        .args(["shell", "wm", "dismiss-keyguard"])
        .creation_flags(CREATE_NO_WINDOW)
        .status();

    // 3. Trigger handshake, reverse ports and launch app
    trigger_usb_device_handshake();

    "已成功向 USB 平板发送唤醒与副屏连接请求！".to_string()
}

#[cfg(not(windows))]
pub fn manual_wake_usb_device() -> String {
    "当前系统不支持 USB 平板唤醒".to_string()
}

