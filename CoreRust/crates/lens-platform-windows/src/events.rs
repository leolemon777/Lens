//! Pointer and click sampling during WGC recording.
//!
//! Polls `GetCursorPos` on a worker thread at ~60 Hz and records left-button
//! down edges via `GetAsyncKeyState`. Keyboard text is never captured.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde::Serialize;
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

const POLL_INTERVAL: Duration = Duration::from_micros(16_667);
const MOVE_THRESHOLD_SQ: i64 = 4;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PointerSample {
    pub t_seconds: f64,
    pub x: f64,
    pub y: f64,
    pub normalized_x: f64,
    pub normalized_y: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClickSample {
    pub t_seconds: f64,
    pub x: f64,
    pub y: f64,
    pub button: String,
    pub normalized_x: f64,
    pub normalized_y: f64,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct EventTrack {
    pub pointer: Vec<PointerSample>,
    pub clicks: Vec<ClickSample>,
}

impl EventTrack {
    /// Writes `pointer.jsonl` and `clicks.jsonl` under `events_dir`.
    pub fn write_jsonl(&self, events_dir: &Path) -> std::io::Result<()> {
        std::fs::create_dir_all(events_dir)?;
        write_jsonl_file(&events_dir.join("pointer.jsonl"), &self.pointer)?;
        write_jsonl_file(&events_dir.join("clicks.jsonl"), &self.clicks)?;
        Ok(())
    }
}

pub struct EventRecorder {
    stop: Arc<AtomicBool>,
    worker: JoinHandle<EventTrack>,
}

impl EventRecorder {
    /// Starts a ~60 Hz cursor poller. `bounds` is capture geometry
    /// `(left, top, right, bottom)` in global desktop pixels.
    pub fn start(
        bounds: (i32, i32, i32, i32),
        paused: Arc<AtomicBool>,
        stop: Arc<AtomicBool>,
    ) -> Self {
        Self::start_with_window(bounds, None, paused, stop)
    }

    /// Starts poller with optional window tracking to adapt bounds on move/resize.
    pub fn start_with_window(
        bounds: (i32, i32, i32, i32),
        tracking_hwnd: Option<isize>,
        paused: Arc<AtomicBool>,
        stop: Arc<AtomicBool>,
    ) -> Self {
        let worker_stop = Arc::clone(&stop);
        let worker = thread::spawn(move || record_loop(bounds, tracking_hwnd, paused, worker_stop));
        Self { stop, worker }
    }

    pub fn join(self) -> EventTrack {
        self.stop.store(true, Ordering::SeqCst);
        self.worker.join().unwrap_or_default()
    }
}

/// Maps a global desktop point into capture-normalized 0..1 coordinates.
///
/// Negative `left`/`top` origins are preserved (multi-monitor layouts). Points
/// outside the rectangle are clamped. Degenerate bounds map to `(0, 0)`.
pub fn normalize_point(x: i32, y: i32, bounds: (i32, i32, i32, i32)) -> (f64, f64) {
    let (left, top, right, bottom) = bounds;
    let width = f64::from(right.saturating_sub(left));
    let height = f64::from(bottom.saturating_sub(top));
    let nx = if width <= 0.0 {
        0.0
    } else {
        ((f64::from(x) - f64::from(left)) / width).clamp(0.0, 1.0)
    };
    let ny = if height <= 0.0 {
        0.0
    } else {
        ((f64::from(y) - f64::from(top)) / height).clamp(0.0, 1.0)
    };
    (nx, ny)
}

/// Media time in seconds: wall elapsed minus accumulated pause.
pub fn media_time_seconds(elapsed: Duration, paused_total: Duration) -> f64 {
    elapsed.saturating_sub(paused_total).as_secs_f64()
}

/// Accumulates pause duration from a `(elapsed_from_start, is_paused)` trace.
///
/// Used by tests as a fake clock: inject times instead of waiting on Instant.
pub fn paused_total_from_trace(trace: &[(Duration, bool)]) -> Duration {
    let mut paused_total = Duration::ZERO;
    let mut pause_started: Option<Duration> = None;
    let mut last = Duration::ZERO;
    for &(elapsed, is_paused) in trace {
        last = elapsed;
        if is_paused {
            if pause_started.is_none() {
                pause_started = Some(elapsed);
            }
        } else if let Some(started) = pause_started.take() {
            paused_total += elapsed.saturating_sub(started);
        }
    }
    if let Some(started) = pause_started {
        paused_total += last.saturating_sub(started);
    }
    paused_total
}

fn record_loop(
    initial_bounds: (i32, i32, i32, i32),
    tracking_hwnd: Option<isize>,
    paused: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) -> EventTrack {
    let started = Instant::now();
    let mut current_bounds = initial_bounds;
    let hwnd_val = tracking_hwnd.map(|h| windows::Win32::Foundation::HWND(h as *mut std::ffi::c_void));
    let mut pause_started: Option<Instant> = None;
    let mut paused_total = Duration::ZERO;
    let mut last_pos: Option<(i32, i32)> = None;
    let mut left_was_down = read_left_button_down();
    let mut pointer = Vec::new();
    let mut clicks = Vec::new();

    while !stop.load(Ordering::SeqCst) {
        if let Some(hwnd) = hwnd_val {
            let mut rect = windows::Win32::Foundation::RECT::default();
            if unsafe { windows::Win32::UI::WindowsAndMessaging::GetWindowRect(hwnd, &mut rect).is_ok() } {
                if rect.right > rect.left && rect.bottom > rect.top {
                    current_bounds = (rect.left, rect.top, rect.right, rect.bottom);
                }
            }
        }
        let bounds = current_bounds;
        let now = Instant::now();
        let is_paused = paused.load(Ordering::SeqCst);
        let pos = read_cursor_pos();
        let left_down = read_left_button_down();

        if is_paused {
            if pause_started.is_none() {
                pause_started = Some(now);
            }
            if let Some(pos) = pos {
                last_pos = Some(pos);
            }
            left_was_down = left_down;
            thread::sleep(POLL_INTERVAL);
            continue;
        }

        if let Some(pause_at) = pause_started.take() {
            paused_total += now.saturating_duration_since(pause_at);
        }

        let t_seconds = media_time_seconds(now.saturating_duration_since(started), paused_total);

        if let Some((x, y)) = pos {
            if should_record_pointer(last_pos, (x, y)) {
                last_pos = Some((x, y));
                let (normalized_x, normalized_y) = normalize_point(x, y, bounds);
                pointer.push(PointerSample {
                    t_seconds,
                    x: f64::from(x),
                    y: f64::from(y),
                    normalized_x,
                    normalized_y,
                });
            }

            if left_button_down_edge(left_was_down, left_down) {
                let (normalized_x, normalized_y) = normalize_point(x, y, bounds);
                clicks.push(ClickSample {
                    t_seconds,
                    x: f64::from(x),
                    y: f64::from(y),
                    button: "left".into(),
                    normalized_x,
                    normalized_y,
                });
            }
        }

        left_was_down = left_down;
        thread::sleep(POLL_INTERVAL);
    }

    EventTrack { pointer, clicks }
}

fn should_record_pointer(last: Option<(i32, i32)>, current: (i32, i32)) -> bool {
    match last {
        None => true,
        Some((px, py)) => {
            let dx = i64::from(current.0) - i64::from(px);
            let dy = i64::from(current.1) - i64::from(py);
            dx * dx + dy * dy >= MOVE_THRESHOLD_SQ
        }
    }
}

fn left_button_down_edge(was_down: bool, is_down: bool) -> bool {
    is_down && !was_down
}

fn read_cursor_pos() -> Option<(i32, i32)> {
    let mut point = POINT::default();
    unsafe { GetCursorPos(&mut point) }.ok()?;
    Some((point.x, point.y))
}

fn read_left_button_down() -> bool {
    // High-order bit is set while the button is currently down.
    (unsafe { GetAsyncKeyState(i32::from(VK_LBUTTON.0)) } as u16) & 0x8000 != 0
}

fn write_jsonl_file<T: Serialize>(path: &Path, samples: &[T]) -> std::io::Result<()> {
    let mut body = String::new();
    for sample in samples {
        body.push_str(&serde_json::to_string(sample).map_err(std::io::Error::other)?);
        body.push('\n');
    }
    std::fs::write(path, body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_point_maps_corners_and_center() {
        let bounds = (0, 0, 1920, 1080);
        assert_eq!(normalize_point(0, 0, bounds), (0.0, 0.0));
        assert_eq!(normalize_point(1920, 1080, bounds), (1.0, 1.0));
        let (nx, ny) = normalize_point(960, 540, bounds);
        assert!((nx - 0.5).abs() < 1e-9);
        assert!((ny - 0.5).abs() < 1e-9);
    }

    #[test]
    fn normalize_point_keeps_negative_desktop_origin() {
        let bounds = (-1920, -100, 0, 980);
        assert_eq!(normalize_point(-1920, -100, bounds), (0.0, 0.0));
        assert_eq!(normalize_point(0, 980, bounds), (1.0, 1.0));
        let (nx, ny) = normalize_point(-960, 440, bounds);
        assert!((nx - 0.5).abs() < 1e-9);
        assert!((ny - 0.5).abs() < 1e-9);
    }

    #[test]
    fn normalize_point_clamps_outside_and_handles_empty_bounds() {
        let bounds = (2000, -100, 2800, 400);
        assert_eq!(normalize_point(2400, 150, bounds), (0.5, 0.5));
        assert_eq!(normalize_point(1999, 150, bounds), (0.0, 0.5));
        assert_eq!(
            normalize_point(10, 10, (0, 0, 0, 1080)),
            (0.0, 10.0 / 1080.0)
        );
        assert_eq!(normalize_point(10, 10, (0, 0, 0, 0)), (0.0, 0.0));
    }

    #[test]
    fn pause_time_is_excluded_from_media_clock() {
        let trace = [
            (Duration::from_secs(0), false),
            (Duration::from_millis(2500), false),
            (Duration::from_secs(3), true),
            (Duration::from_secs(8), true),
            (Duration::from_secs(8), false),
            (Duration::from_secs(10), false),
        ];
        let paused_total = paused_total_from_trace(&trace);
        assert_eq!(paused_total, Duration::from_secs(5));
        let media = media_time_seconds(Duration::from_secs(10), paused_total);
        assert!((media - 5.0).abs() < 1e-9);
    }

    #[test]
    fn pause_still_open_at_end_of_trace_is_counted() {
        let trace = [
            (Duration::from_secs(1), false),
            (Duration::from_secs(2), true),
            (Duration::from_secs(4), true),
        ];
        assert_eq!(paused_total_from_trace(&trace), Duration::from_secs(2));
        assert_eq!(
            media_time_seconds(Duration::from_secs(4), Duration::from_secs(2)),
            2.0
        );
    }

    #[test]
    fn pointer_records_first_sample_then_two_pixel_moves() {
        assert!(should_record_pointer(None, (10, 10)));
        assert!(!should_record_pointer(Some((10, 10)), (11, 10)));
        assert!(!should_record_pointer(Some((10, 10)), (11, 11)));
        assert!(should_record_pointer(Some((10, 10)), (12, 10)));
        assert!(should_record_pointer(Some((10, 10)), (12, 12)));
    }

    #[test]
    fn click_records_left_button_down_edge_only() {
        assert!(left_button_down_edge(false, true));
        assert!(!left_button_down_edge(true, true));
        assert!(!left_button_down_edge(true, false));
        assert!(!left_button_down_edge(false, false));
    }

    #[test]
    fn start_join_without_gui_returns_a_track() {
        let stop = Arc::new(AtomicBool::new(false));
        let paused = Arc::new(AtomicBool::new(false));
        let recorder = EventRecorder::start((0, 0, 1920, 1080), paused, Arc::clone(&stop));
        thread::sleep(Duration::from_millis(40));
        stop.store(true, Ordering::SeqCst);
        let track = recorder.join();
        let _ = track.pointer.len();
        let _ = track.clicks.len();
    }

    #[test]
    fn jsonl_roundtrip_writes_pointer_and_clicks() {
        let dir = std::env::temp_dir().join(format!(
            "lens-events-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let track = EventTrack {
            pointer: vec![PointerSample {
                t_seconds: 1.25,
                x: -100.0,
                y: 40.0,
                normalized_x: 0.25,
                normalized_y: 0.5,
            }],
            clicks: vec![ClickSample {
                t_seconds: 1.5,
                x: -100.0,
                y: 40.0,
                button: "left".into(),
                normalized_x: 0.25,
                normalized_y: 0.5,
            }],
        };
        track.write_jsonl(&dir).expect("write jsonl");
        let pointer = std::fs::read_to_string(dir.join("pointer.jsonl")).unwrap();
        let clicks = std::fs::read_to_string(dir.join("clicks.jsonl")).unwrap();
        assert!(pointer.contains("\"tSeconds\":1.25"));
        assert!(pointer.contains("\"normalizedX\":0.25"));
        assert!(clicks.contains("\"button\":\"left\""));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
