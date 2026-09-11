//! Top-level window enumeration for window capture.

use windows::core::{BOOL, BOOL as WinBool};
use windows::Win32::Foundation::{HWND, LPARAM, RECT};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowRect, GetWindowTextW, IsIconic, IsWindowVisible,
};

#[derive(Debug, Clone, serde::Serialize)]
pub struct TopLevelWindow {
    pub hwnd: isize,
    pub title: String,
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

struct EnumState {
    windows: Vec<TopLevelWindow>,
}

/// Visible, non-minimized top-level windows with a title.
pub fn enumerate_capturable_windows() -> windows::core::Result<Vec<TopLevelWindow>> {
    let mut state = EnumState {
        windows: Vec::new(),
    };
    unsafe {
        EnumWindows(
            Some(enum_proc),
            LPARAM(&mut state as *mut EnumState as isize),
        )?;
    }
    Ok(state.windows)
}

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> WinBool {
    let state = unsafe { &mut *(lparam.0 as *mut EnumState) };
    unsafe {
        if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() {
            return BOOL(1);
        }
        let mut title = [0_u16; 512];
        let len = GetWindowTextW(hwnd, &mut title);
        if len <= 0 {
            return BOOL(1);
        }
        let title = String::from_utf16_lossy(&title[..len as usize]);
        if title == "Program Manager" || title == "Lens" || title == "Lens 选区" {
            return BOOL(1);
        }
        let mut rect = RECT::default();
        if GetWindowRect(hwnd, &mut rect).is_err() {
            return BOOL(1);
        }
        if rect.right - rect.left < 80 || rect.bottom - rect.top < 80 {
            return BOOL(1);
        }
        state.windows.push(TopLevelWindow {
            hwnd: hwnd.0 as isize,
            title,
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
        });
    }
    BOOL(1)
}
