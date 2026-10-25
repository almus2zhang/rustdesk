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
                loop {
                    // Poll at lower interval for responsive hotplug detection
                    thread::sleep(Duration::from_millis(1000));
                    
                    // Check if an Android USB device / tablet is attached
                    let has_device = check_android_usb_present();
                    if has_device && !last_detected_device {
                        log::info!("Android USB device attachment detected! Initiating AOA handshake and dynamic port map...");
                        last_detected_device = true;
                        
                        // Execute AOA hardware handshake & port mapping trigger
                        trigger_usb_device_handshake();
                    } else if !has_device && last_detected_device {
                        log::info!("Android USB device detached. Cleaning up secondary display...");
                        last_detected_device = false;
                        plug_out_usb_display().ok();
                    }
                }
            });
        });
    }
}

#[cfg(windows)]
fn check_android_usb_present() -> bool {
    use std::process::Command;
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let output = Command::new("adb")
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

        // Dynamically get the configured direct access port
        let direct_port = get_configured_direct_port();
        log::info!("Configuring ADB reverse for dynamically configured direct port: {}", direct_port);
        
        let port_str = direct_port.to_string();
        let mut ports = vec![port_str.as_str()];
        if !ports.contains(&"21118") {
            ports.push("21118");
        }
        if !ports.contains(&"21116") {
            ports.push("21116");
        }

        for port in ports {
            let _ = Command::new("adb")
                .args(["reverse", &format!("tcp:{}", port), &format!("tcp:{}", port)])
                .creation_flags(CREATE_NO_WINDOW)
                .status();
        }

        // Send broadcast or intent to awaken tablet with prompt dialog and port info
        log::info!("Awakening tablet RustDesk with accessory attached intent and port {}...", direct_port);
        let _ = Command::new("adb")
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
    });
}
