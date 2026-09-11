//! Physical display inventory, including DPI and desktop coordinates.

use windows::core::BOOL;
use windows::core::{Error, Result};
use windows::Win32::Foundation::{E_FAIL, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};

/// Runtime snapshot of one attached display.
///
/// The HMONITOR handle is a runtime correlation id only. It is not a stable
/// portable identity and must never be persisted in project files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayInfo {
    pub handle: isize,
    pub is_primary: bool,
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
    pub work_left: i32,
    pub work_top: i32,
    pub work_right: i32,
    pub work_bottom: i32,
    pub effective_dpi_x: u32,
    pub effective_dpi_y: u32,
}

impl DisplayInfo {
    pub fn width(&self) -> i32 {
        self.right - self.left
    }

    pub fn height(&self) -> i32 {
        self.bottom - self.top
    }

    pub fn geometry_is_valid(&self) -> bool {
        self.right > self.left
            && self.bottom > self.top
            && self.work_right >= self.work_left
            && self.work_bottom >= self.work_top
            && self.effective_dpi_x >= 96
            && self.effective_dpi_y >= 96
    }
}

/// Enumerates currently attached displays in physical desktop coordinates.
///
/// Negative coordinates are expected on multi-monitor layouts and are kept
/// as-is so callers can build capture geometry without re-anchoring.
pub fn enumerate_displays() -> Result<Vec<DisplayInfo>> {
    let mut displays: Vec<DisplayInfo> = Vec::new();
    let callback_data = LPARAM(&mut displays as *mut Vec<DisplayInfo> as isize);
    if !unsafe { EnumDisplayMonitors(None, None, Some(monitor_enum_proc), callback_data) }.as_bool()
    {
        return Err(Error::from(E_FAIL));
    }
    Ok(displays)
}

unsafe extern "system" fn monitor_enum_proc(
    handle: HMONITOR,
    _monitor_dc: HDC,
    _clip_rect: *mut RECT,
    data: LPARAM,
) -> BOOL {
    let displays = &mut *(data.0 as *mut Vec<DisplayInfo>);
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if !GetMonitorInfoW(handle, &mut info).as_bool() {
        return BOOL(1);
    }

    let mut dpi_x = 0_u32;
    let mut dpi_y = 0_u32;
    let dpi_known = GetDpiForMonitor(handle, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y).is_ok();
    displays.push(DisplayInfo {
        handle: handle.0 as isize,
        is_primary: (info.dwFlags & 1) != 0,
        left: info.rcMonitor.left,
        top: info.rcMonitor.top,
        right: info.rcMonitor.right,
        bottom: info.rcMonitor.bottom,
        work_left: info.rcWork.left,
        work_top: info.rcWork.top,
        work_right: info.rcWork.right,
        work_bottom: info.rcWork.bottom,
        effective_dpi_x: if dpi_known { dpi_x } else { 96 },
        effective_dpi_y: if dpi_known { dpi_y } else { 96 },
    });
    BOOL(1)
}

#[cfg(test)]
mod tests {
    use super::DisplayInfo;

    fn display(left: i32, top: i32, right: i32, bottom: i32) -> DisplayInfo {
        DisplayInfo {
            handle: 0,
            is_primary: false,
            left,
            top,
            right,
            bottom,
            work_left: left,
            work_top: top,
            work_right: right,
            work_bottom: bottom,
            effective_dpi_x: 144,
            effective_dpi_y: 144,
        }
    }

    #[test]
    fn accepts_primary_layout_with_positive_dimensions() {
        assert!(display(0, 0, 3840, 2160).geometry_is_valid());
    }

    #[test]
    fn accepts_negative_coordinates_without_reanchoring() {
        let secondary = display(-3840, -2160, 0, 0);
        assert!(secondary.geometry_is_valid());
        assert_eq!(secondary.width(), 3840);
        assert_eq!(secondary.height(), 2160);
    }

    #[test]
    fn rejects_empty_geometry() {
        assert!(!display(0, 0, 0, 2160).geometry_is_valid());
        assert!(!display(0, 0, 3840, 0).geometry_is_valid());
    }
}
