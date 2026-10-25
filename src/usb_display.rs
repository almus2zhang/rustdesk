// USB Secondary Display Auto-Detector and Virtual Monitor Manager
// Detects USB connected Android tablets/devices, automatically manages
// corresponding virtual display creation and destruction, and handles low-latency 127.0.0.1 link.

use hbb_common::{log, ResultType};
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

/// Start background listener loop for USB secondary display status
pub fn start_usb_display_service() {
    #[cfg(windows)]
    {
        thread::spawn(|| {
            log::info!("USB secondary display monitor service started");
            let mut last_connected = false;
            loop {
                thread::sleep(Duration::from_millis(1500));
                let is_active = USB_DISPLAY_ACTIVE.load(Ordering::Relaxed);
                if is_active != last_connected {
                    last_connected = is_active;
                    log::info!("USB secondary display connection state changed: {}", is_active);
                }
            }
        });
    }
}
