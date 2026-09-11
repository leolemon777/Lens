//! Process DPI awareness setup.

use windows::core::Result;
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};

/// Enables Per-Monitor DPI Awareness V2 for the current process.
///
/// This must run before any display or window geometry API is queried;
/// otherwise Windows virtualizes monitor coordinates and the process observes
/// scaled logical values instead of physical capture pixels.
pub fn enable_per_monitor_v2() -> Result<()> {
    unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
}
