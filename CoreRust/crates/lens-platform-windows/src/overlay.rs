//! Overlay geometry, CSS-to-physical mapping, and capture-exclusion helpers.
//!
//! These functions are called by the Tauri desktop host. They must stay free of
//! Tauri/React types so unit tests can cover negative-origin and mixed-DPI
//! layouts without spinning WebView2.

use std::sync::atomic::{AtomicBool, Ordering};

use windows::core::{Error, Result as WinResult};
use windows::Win32::Foundation::{E_FAIL, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, IsWindow, RegisterClassExW,
    SetWindowDisplayAffinity, WDA_EXCLUDEFROMCAPTURE, WINDOW_EX_STYLE, WNDCLASSEXW, WS_OVERLAPPED,
};

use crate::display::DisplayInfo;

/// Physical desktop rectangle that the region overlay must cover.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OverlayBounds {
    pub left: i32,
    pub top: i32,
    pub width: u32,
    pub height: u32,
}

impl OverlayBounds {
    pub fn right(&self) -> i32 {
        self.left.saturating_add(self.width as i32)
    }

    pub fn bottom(&self) -> i32 {
        self.top.saturating_add(self.height as i32)
    }
}

/// Physical desktop selection after mapping overlay-local CSS pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PhysicalRegion {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// Magnetic guide lines after snapping a selection to nearby edges.
///
/// `x` is a vertical line in physical desktop pixels; `y` is a horizontal line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnapGuide {
    pub x: Option<i32>,
    pub y: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SelectionError {
    #[error("device pixel ratio must be a finite positive number")]
    InvalidDevicePixelRatio,
    #[error("selection must have positive physical dimensions")]
    EmptySelection,
}

/// Where to return focus after the overlay closes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusRestore {
    Main,
    Tray,
}

/// Outcome of requesting `WDA_EXCLUDEFROMCAPTURE` on a window.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum CaptureExclusion {
    Excluded,
    Fallback { reason: String },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CaptureExclusionError {
    #[error("window handle is invalid")]
    InvalidHandle,
}

/// Union of attached displays in physical desktop coordinates.
///
/// Negative origins are kept. The overlay must be positioned at `left/top`,
/// not re-anchored to `(0, 0)`.
pub fn virtual_desktop_union(displays: &[DisplayInfo]) -> Option<OverlayBounds> {
    let mut iter = displays.iter().filter(|item| item.geometry_is_valid());
    let first = iter.next()?;
    let mut left = first.left;
    let mut top = first.top;
    let mut right = first.right;
    let mut bottom = first.bottom;
    for display in iter {
        left = left.min(display.left);
        top = top.min(display.top);
        right = right.max(display.right);
        bottom = bottom.max(display.bottom);
    }
    let width = (right - left).max(1) as u32;
    let height = (bottom - top).max(1) as u32;
    Some(OverlayBounds {
        left,
        top,
        width,
        height,
    })
}

/// Maps an overlay-local CSS-pixel drag into a physical desktop rectangle.
///
/// `device_pixel_ratio` is the overlay WebView scale (mixed-DPI layouts still
/// use the single DPR the overlay reports). Overlay origin may be negative.
pub fn map_css_drag_to_physical(
    overlay: OverlayBounds,
    origin_css_x: f64,
    origin_css_y: f64,
    current_css_x: f64,
    current_css_y: f64,
    device_pixel_ratio: f64,
) -> Result<PhysicalRegion, SelectionError> {
    if !device_pixel_ratio.is_finite() || device_pixel_ratio <= 0.0 {
        return Err(SelectionError::InvalidDevicePixelRatio);
    }
    let first = css_to_physical_point(overlay, origin_css_x, origin_css_y, device_pixel_ratio)?;
    let second = css_to_physical_point(overlay, current_css_x, current_css_y, device_pixel_ratio)?;
    let x = first.0.min(second.0);
    let y = first.1.min(second.1);
    let width = (first.0 - second.0).abs();
    let height = (first.1 - second.1).abs();
    if width <= 0 || height <= 0 {
        return Err(SelectionError::EmptySelection);
    }
    Ok(PhysicalRegion {
        x,
        y,
        width,
        height,
    })
}

/// Snaps a selection to nearby display or window edges.
///
/// `edges` are rectangles `(left, top, right, bottom)` in physical desktop
/// pixels. Left/right snap independently to the nearest vertical edge within
/// `threshold`; top/bottom snap to horizontal edges. `bypass` (Alt held)
/// returns the region unchanged with empty guides. Width and height stay
/// positive; snaps that would invert the rectangle are ignored.
pub fn snap_region(
    region: PhysicalRegion,
    edges: &[(i32, i32, i32, i32)],
    threshold: i32,
    bypass: bool,
) -> (PhysicalRegion, SnapGuide) {
    if bypass {
        return (region, SnapGuide { x: None, y: None });
    }

    let left = region.x;
    let top = region.y;
    let right = region.x.saturating_add(region.width);
    let bottom = region.y.saturating_add(region.height);

    let (new_left, new_right, guide_x) = snap_axis(left, right, edges, threshold, true);
    let (new_top, new_bottom, guide_y) = snap_axis(top, bottom, edges, threshold, false);

    (
        PhysicalRegion {
            x: new_left,
            y: new_top,
            width: new_right - new_left,
            height: new_bottom - new_top,
        },
        SnapGuide {
            x: guide_x,
            y: guide_y,
        },
    )
}

/// Translates a selection by `dx`/`dy` physical pixels without changing size.
///
/// Used for arrow-key 1px and Shift+arrow 10px fine-tune while dragging.
pub fn nudge_region(region: PhysicalRegion, dx: i32, dy: i32) -> PhysicalRegion {
    PhysicalRegion {
        x: region.x.saturating_add(dx),
        y: region.y.saturating_add(dy),
        width: region.width,
        height: region.height,
    }
}

/// Restore the main window when it was visible; otherwise leave the app in the tray.
pub fn focus_restore_target(main_was_visible: bool) -> FocusRestore {
    if main_was_visible {
        FocusRestore::Main
    } else {
        FocusRestore::Tray
    }
}

/// Requests Windows capture exclusion on `hwnd` and returns a determinate result.
///
/// A failed API call is `Ok(Fallback)` — never a swallowed ignore. An invalid
/// handle is `Err`.
pub fn request_exclude_from_capture(
    hwnd: isize,
) -> Result<CaptureExclusion, CaptureExclusionError> {
    if hwnd == 0 || !unsafe { IsWindow(Some(HWND(hwnd as *mut std::ffi::c_void))) }.as_bool() {
        return Err(CaptureExclusionError::InvalidHandle);
    }
    let handle = HWND(hwnd as *mut std::ffi::c_void);
    match unsafe { SetWindowDisplayAffinity(handle, WDA_EXCLUDEFROMCAPTURE) } {
        Ok(()) => Ok(CaptureExclusion::Excluded),
        Err(err) => Ok(CaptureExclusion::Fallback {
            reason: format!("SetWindowDisplayAffinity failed: {err}"),
        }),
    }
}

fn css_to_physical_point(
    overlay: OverlayBounds,
    css_x: f64,
    css_y: f64,
    device_pixel_ratio: f64,
) -> Result<(i32, i32), SelectionError> {
    let x = scale_css(css_x, device_pixel_ratio)?;
    let y = scale_css(css_y, device_pixel_ratio)?;
    Ok((
        overlay.left.saturating_add(x),
        overlay.top.saturating_add(y),
    ))
}

fn scale_css(css: f64, device_pixel_ratio: f64) -> Result<i32, SelectionError> {
    let physical = css * device_pixel_ratio;
    if !physical.is_finite() {
        return Err(SelectionError::EmptySelection);
    }
    Ok(physical.round() as i32)
}

fn snap_axis(
    start: i32,
    end: i32,
    edges: &[(i32, i32, i32, i32)],
    threshold: i32,
    vertical: bool,
) -> (i32, i32, Option<i32>) {
    let snap_start = nearest_on_axis(start, edges, threshold, vertical);
    let snap_end = nearest_on_axis(end, edges, threshold, vertical);
    let cand_start = snap_start.unwrap_or(start);
    let cand_end = snap_end.unwrap_or(end);

    if cand_end > cand_start {
        let guide = match (snap_start, snap_end) {
            (Some(s), Some(e)) => {
                if abs_delta(start, s) <= abs_delta(end, e) {
                    Some(s)
                } else {
                    Some(e)
                }
            }
            (s, e) => s.or(e),
        };
        return (cand_start, cand_end, guide);
    }

    let dist_start = snap_start.map(|value| abs_delta(start, value));
    let dist_end = snap_end.map(|value| abs_delta(end, value));
    match (snap_start, snap_end, dist_start, dist_end) {
        (Some(s), Some(_), Some(ds), Some(de)) if ds < de && s < end => (s, end, Some(s)),
        (Some(_), Some(e), Some(ds), Some(de)) if de < ds && e > start => (start, e, Some(e)),
        (Some(s), None, _, _) if s < end => (s, end, Some(s)),
        (None, Some(e), _, _) if e > start => (start, e, Some(e)),
        _ => (start, end, None),
    }
}

fn nearest_on_axis(
    value: i32,
    edges: &[(i32, i32, i32, i32)],
    threshold: i32,
    vertical: bool,
) -> Option<i32> {
    let mut best_dist = i32::MAX;
    let mut best = None;
    for &(left, top, right, bottom) in edges {
        let candidates = if vertical {
            [left, right]
        } else {
            [top, bottom]
        };
        for edge in candidates {
            let dist = abs_delta(value, edge);
            if dist <= threshold && dist < best_dist {
                best_dist = dist;
                best = Some(edge);
            }
        }
    }
    best
}

fn abs_delta(a: i32, b: i32) -> i32 {
    a.saturating_sub(b).saturating_abs()
}

static PROBE_WINDOW_CLASS_REGISTERED: AtomicBool = AtomicBool::new(false);

/// Hidden overlapped window used by tests to exercise the real Win32 call.
pub fn create_hidden_probe_window() -> WinResult<HWND> {
    unsafe {
        let instance = GetModuleHandleW(None)?;
        let class_name = windows::core::w!("LensOverlayExclusionProbe");
        if !PROBE_WINDOW_CLASS_REGISTERED.load(Ordering::SeqCst) {
            let window_class = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(probe_wnd_proc),
                hInstance: instance.into(),
                lpszClassName: class_name,
                ..Default::default()
            };
            let atom = RegisterClassExW(&window_class);
            if atom == 0 {
                return Err(Error::from(E_FAIL));
            }
            PROBE_WINDOW_CLASS_REGISTERED.store(true, Ordering::SeqCst);
        }
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class_name,
            windows::core::w!("Lens overlay exclusion probe"),
            WS_OVERLAPPED,
            0,
            0,
            64,
            64,
            None,
            None,
            Some(instance.into()),
            None,
        )
    }
}

pub fn destroy_hidden_probe_window(hwnd: HWND) {
    let _ = unsafe { DestroyWindow(hwnd) };
}

unsafe extern "system" fn probe_wnd_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
}

#[cfg(test)]
mod tests {
    use super::{
        create_hidden_probe_window, destroy_hidden_probe_window, focus_restore_target,
        map_css_drag_to_physical, nudge_region, request_exclude_from_capture, snap_region,
        virtual_desktop_union, CaptureExclusion, CaptureExclusionError, FocusRestore,
        OverlayBounds, PhysicalRegion, SelectionError, SnapGuide,
    };
    use crate::display::DisplayInfo;

    fn display(
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
        dpi: u32,
        is_primary: bool,
    ) -> DisplayInfo {
        DisplayInfo {
            handle: 0,
            is_primary,
            left,
            top,
            right,
            bottom,
            work_left: left,
            work_top: top,
            work_right: right,
            work_bottom: bottom,
            effective_dpi_x: dpi,
            effective_dpi_y: dpi,
        }
    }

    #[test]
    fn union_keeps_negative_origin_from_secondary_display() {
        let primary = display(0, 0, 3840, 2160, 96, true);
        let secondary = display(-2560, -1440, 0, 0, 144, false);
        let union = virtual_desktop_union(&[primary, secondary]).expect("union");
        assert_eq!(union.left, -2560);
        assert_eq!(union.top, -1440);
        assert_eq!(union.width, 6400);
        assert_eq!(union.height, 3600);
    }

    #[test]
    fn union_uses_true_minima_when_primary_is_not_first() {
        let secondary = display(-1920, 0, 0, 1080, 144, false);
        let primary = display(0, 0, 1920, 1080, 96, true);
        let union = virtual_desktop_union(&[secondary, primary]).expect("union");
        assert_eq!(union.left, -1920);
        assert_eq!(union.top, 0);
        assert_eq!(union.width, 3840);
        assert_eq!(union.height, 1080);
    }

    #[test]
    fn empty_display_list_has_no_union() {
        assert!(virtual_desktop_union(&[]).is_none());
    }

    #[test]
    fn mixed_dpr_css_drag_maps_through_overlay_origin() {
        let overlay = OverlayBounds {
            left: -1920,
            top: 0,
            width: 3840,
            height: 1080,
        };
        // 150% scale (144 DPI overlay on a 96+144 mixed layout).
        let region = map_css_drag_to_physical(overlay, 10.0, 20.0, 110.0, 80.0, 1.5)
            .expect("mapped selection");
        assert_eq!(region.x, -1920 + 15);
        assert_eq!(region.y, 30);
        assert_eq!(region.width, 150);
        assert_eq!(region.height, 90);
    }

    #[test]
    fn zero_size_css_drag_is_rejected() {
        let overlay = OverlayBounds {
            left: 0,
            top: 0,
            width: 1920,
            height: 1080,
        };
        let err = map_css_drag_to_physical(overlay, 40.0, 40.0, 40.0, 40.0, 1.0).unwrap_err();
        assert_eq!(err, SelectionError::EmptySelection);
    }

    #[test]
    fn non_positive_device_pixel_ratio_is_rejected() {
        let overlay = OverlayBounds {
            left: 0,
            top: 0,
            width: 800,
            height: 600,
        };
        assert_eq!(
            map_css_drag_to_physical(overlay, 0.0, 0.0, 10.0, 10.0, 0.0).unwrap_err(),
            SelectionError::InvalidDevicePixelRatio
        );
    }

    #[test]
    fn focus_returns_to_main_or_tray() {
        assert_eq!(focus_restore_target(true), FocusRestore::Main);
        assert_eq!(focus_restore_target(false), FocusRestore::Tray);
    }

    #[test]
    fn capture_exclusion_rejects_invalid_handle() {
        let err = request_exclude_from_capture(0).unwrap_err();
        assert_eq!(err, CaptureExclusionError::InvalidHandle);
    }

    #[test]
    fn capture_exclusion_on_real_window_is_determinate() {
        let hwnd = create_hidden_probe_window().expect("hidden probe window");
        let result = request_exclude_from_capture(hwnd.0 as isize);
        destroy_hidden_probe_window(hwnd);
        let outcome = result.expect("exclusion request must return ok or recorded fallback");
        assert!(
            matches!(
                outcome,
                CaptureExclusion::Excluded | CaptureExclusion::Fallback { .. }
            ),
            "unexpected exclusion outcome: {outcome:?}"
        );
    }

    #[test]
    fn snap_aligns_to_display_edge() {
        let region = PhysicalRegion {
            x: 8,
            y: 12,
            width: 100,
            height: 80,
        };
        let display = (0, 0, 1920, 1080);
        let (snapped, guide) = snap_region(region, &[display], 16, false);
        assert_eq!(snapped.x, 0);
        assert_eq!(snapped.y, 0);
        assert_eq!(snapped.width, 108);
        assert_eq!(snapped.height, 92);
        assert_eq!(guide.x, Some(0));
        assert_eq!(guide.y, Some(0));

        let secondary = PhysicalRegion {
            x: -1912,
            y: 6,
            width: 120,
            height: 90,
        };
        let (snapped, guide) = snap_region(secondary, &[(-1920, 0, 0, 1080)], 16, false);
        assert_eq!(snapped.x, -1920);
        assert_eq!(snapped.y, 0);
        assert_eq!(snapped.width, 128);
        assert_eq!(guide.x, Some(-1920));
        assert_eq!(guide.y, Some(0));
    }

    #[test]
    fn snap_bypass_leaves_region_unchanged() {
        let region = PhysicalRegion {
            x: 8,
            y: 12,
            width: 100,
            height: 80,
        };
        let (snapped, guide) = snap_region(region, &[(0, 0, 1920, 1080)], 16, true);
        assert_eq!(snapped, region);
        assert_eq!(guide, SnapGuide { x: None, y: None });
    }

    #[test]
    fn snap_x_and_y_are_independent() {
        let near_left = PhysicalRegion {
            x: 5,
            y: 400,
            width: 50,
            height: 50,
        };
        let (snapped, guide) = snap_region(near_left, &[(0, 0, 1920, 1080)], 10, false);
        assert_eq!(snapped.x, 0);
        assert_eq!(snapped.y, 400);
        assert_eq!(snapped.width, 55);
        assert_eq!(snapped.height, 50);
        assert_eq!(guide.x, Some(0));
        assert_eq!(guide.y, None);

        let near_top = PhysicalRegion {
            x: 400,
            y: 5,
            width: 50,
            height: 50,
        };
        let (snapped, guide) = snap_region(near_top, &[(0, 0, 1920, 1080)], 10, false);
        assert_eq!(snapped.x, 400);
        assert_eq!(snapped.y, 0);
        assert_eq!(snapped.width, 50);
        assert_eq!(snapped.height, 55);
        assert_eq!(guide.x, None);
        assert_eq!(guide.y, Some(0));

        let near_right = PhysicalRegion {
            x: 1810,
            y: 400,
            width: 100,
            height: 50,
        };
        let (snapped, guide) = snap_region(near_right, &[(0, 0, 1920, 1080)], 16, false);
        assert_eq!(snapped.x, 1810);
        assert_eq!(snapped.y, 400);
        assert_eq!(snapped.width, 110);
        assert_eq!(guide.x, Some(1920));
        assert_eq!(guide.y, None);
    }

    #[test]
    fn snap_with_empty_edges_is_noop() {
        let region = PhysicalRegion {
            x: 40,
            y: 50,
            width: 80,
            height: 60,
        };
        let (snapped, guide) = snap_region(region, &[], 16, false);
        assert_eq!(snapped, region);
        assert_eq!(guide, SnapGuide { x: None, y: None });
    }

    #[test]
    fn nudge_moves_region_without_resizing() {
        let region = PhysicalRegion {
            x: 100,
            y: 200,
            width: 50,
            height: 60,
        };
        assert_eq!(
            nudge_region(region, 1, 0),
            PhysicalRegion {
                x: 101,
                y: 200,
                width: 50,
                height: 60,
            }
        );
        assert_eq!(
            nudge_region(region, 0, -1),
            PhysicalRegion {
                x: 100,
                y: 199,
                width: 50,
                height: 60,
            }
        );
        assert_eq!(
            nudge_region(region, 10, -10),
            PhysicalRegion {
                x: 110,
                y: 190,
                width: 50,
                height: 60,
            }
        );
        assert_eq!(
            nudge_region(
                PhysicalRegion {
                    x: -10,
                    y: 0,
                    width: 20,
                    height: 20,
                },
                -1,
                0
            )
            .x,
            -11
        );
    }
}
