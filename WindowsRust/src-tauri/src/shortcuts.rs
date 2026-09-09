//! Two explicit global shortcuts only. No keyboard hook or ordinary text logging.
use std::sync::Arc;
use lens_core::Phase;
use crate::service::Service;
use windows::Win32::UI::{
    Input::KeyboardAndMouse::{RegisterHotKey, UnregisterHotKey, MOD_CONTROL, MOD_SHIFT, MOD_NOREPEAT},
    WindowsAndMessaging::{GetMessageW, MSG, WM_HOTKEY},
};

pub fn start(service: Arc<Service>) {
    let weak = Arc::downgrade(&service);
    let spawned = std::thread::Builder::new().name("lens-hotkeys".into()).spawn(move || unsafe {
        // These registrations belong to this message-loop thread and are released on exit.
        let pause = RegisterHotKey(None, 0x4c01, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 0x78).is_ok(); // F9
        let stop = RegisterHotKey(None, 0x4c02, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 0x79).is_ok(); // F10
        if !pause || !stop {
            if let Some(service) = weak.upgrade() { service.notify("部分全局快捷键被其他程序占用，请使用窗口内的录制按钮"); }
        }
        if !pause && !stop { return; }
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).0 > 0 {
            if message.message != WM_HOTKEY { continue; }
            let Some(service) = weak.upgrade() else { break; };
            let id = message.wParam.0;
            std::thread::spawn(move || {
                let result = if id == 0x4c02 {
                    if service.status().phase.may_stop() { service.stop().map(|_| ()) } else { Ok(()) }
                } else {
                    match service.status().phase {
                        Phase::Recording => service.pause(),
                        Phase::Paused => service.resume(),
                        _ => Ok(()),
                    }
                };
                if let Err(error) = result { service.notify(error); }
            });
        }
        if pause { let _ = UnregisterHotKey(None, 0x4c01); }
        if stop { let _ = UnregisterHotKey(None, 0x4c02); }
    });
    if let Err(error) = spawned { service.notify(format!("快捷键线程启动失败：{error}")); }
}
