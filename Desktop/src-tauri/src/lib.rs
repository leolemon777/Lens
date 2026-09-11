use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lens_core::edit::{
    cues_to_vtt, make_auto_edit_plan, organize_insights, plan_captions, split_timeline,
    vtt_to_cues, CaptionCue, LensPoint, TranscriptDocument, VideoEditTimeline,
};
use lens_core::interop;
use lens_core::manifest::LensRect;
use lens_core::screenshot_edit::ScreenshotEditPlan;
use lens_platform_windows::audio::{self, AudioCaptureConfig};
use lens_platform_windows::camera::{self, CameraTrackOutcome};
use lens_platform_windows::capture::CapturedFrame;
use lens_platform_windows::clipboard;
use lens_platform_windows::disk;
use lens_platform_windows::display;
use lens_platform_windows::dpi;
use lens_platform_windows::encode as media_encode;
use lens_platform_windows::ocr;
use lens_platform_windows::overlay::{self, CaptureExclusion, FocusRestore, OverlayBounds};
use lens_platform_windows::screenshot;
use lens_platform_windows::scrolling;
use lens_platform_windows::session::{LiveRecording, SessionRecordingConfig, VideoSource};
use lens_platform_windows::transcript;
use lens_platform_windows::windows as win_windows;
use lens_project::{self, AppSettings, LibraryItem, RecordingSourceMeta};
use serde::{Deserialize, Serialize};
use tauri::menu::{MenuBuilder, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{
    AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, Position, Size, WebviewUrl,
    WebviewWindow, WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, ShortcutState};

mod frontend_server;

const OVERLAY_LABEL: &str = "overlay";
const SCREENSHOT_SHORTCUT: &str = "Control+Alt+1";
const CENTER_SHORTCUT: &str = "Control+Alt+2";

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum OverlayMode {
    Screenshot,
    Record,
    Scrolling,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
struct OverlayDrag {
    origin_x: f64,
    origin_y: f64,
    current_x: f64,
    current_y: f64,
    device_pixel_ratio: f64,
    confirmed_at_ms: u64,
    #[serde(default)]
    alt_held: bool,
}

#[derive(Debug, Clone, Serialize)]
struct AppSnapshot {
    library_root: String,
    dpi_awareness: String,
    recording: bool,
    recording_paused: bool,
    recording_elapsed_ms: u64,
    capture_exclusion: Option<CaptureExclusion>,
    last_item: Option<LibraryItem>,
    items: Vec<LibraryItem>,
    scrolling: bool,
    scroll_frames: u32,
    camera_count: usize,
    camera_message: String,
    disk_free_bytes: u64,
    disk_status: String,
    audio_peak_system: f32,
    audio_peak_mic: f32,
    recording_fps: u32,
    audio_system_enabled: bool,
    audio_mic_enabled: bool,
    camera_enabled: bool,
    audio_system_device_id: Option<String>,
    audio_mic_device_id: Option<String>,
    camera_device_link: Option<String>,
}

struct ScrollingSession {
    region: overlay::PhysicalRegion,
    frames: Vec<CapturedFrame>,
}

struct MediaTaskControl {
    package: String,
    cancel: Arc<AtomicBool>,
}

struct HostState {
    overlay_mode: OverlayMode,
    main_was_visible: Option<bool>,
    capture_exclusion: Option<CaptureExclusion>,
    last_item: Option<LibraryItem>,
    recording: Option<LiveRecording>,
    recording_id: Option<(std::path::PathBuf, String)>,
    recording_activity_guard: Option<lens_project::RecordingActivityGuard>,
    recording_fps: u32,
    recording_source_meta: Option<RecordingSourceMeta>,
    audio_system_enabled: bool,
    audio_mic_enabled: bool,
    camera_enabled: bool,
    audio_system_device_id: Option<String>,
    audio_mic_device_id: Option<String>,
    camera_device_link: Option<String>,
    scrolling: Option<ScrollingSession>,
    media_tasks: HashMap<String, MediaTaskControl>,
}

impl Default for HostState {
    fn default() -> Self {
        Self {
            overlay_mode: OverlayMode::Screenshot,
            main_was_visible: None,
            capture_exclusion: None,
            last_item: None,
            recording: None,
            recording_id: None,
            recording_activity_guard: None,
            recording_fps: 30,
            recording_source_meta: None,
            audio_system_enabled: true,
            audio_mic_enabled: true,
            camera_enabled: false,
            audio_system_device_id: None,
            audio_mic_device_id: None,
            camera_device_link: None,
            scrolling: None,
            media_tasks: HashMap::new(),
        }
    }
}

impl HostState {
    fn audio_capture_config(&self) -> AudioCaptureConfig {
        AudioCaptureConfig {
            enable_system: self.audio_system_enabled,
            enable_mic: self.audio_mic_enabled,
            system_device_id: self.audio_system_device_id.clone(),
            mic_device_id: self.audio_mic_device_id.clone(),
        }
    }

    fn session_recording_config(&self) -> SessionRecordingConfig {
        SessionRecordingConfig {
            audio: self.audio_capture_config(),
            enable_camera: self.camera_enabled,
            camera_device_link: self.camera_device_link.clone(),
            fps: self.recording_fps,
        }
    }
}

#[derive(Clone, Serialize)]
struct DpiAwareness(String);

pub fn print_inventory() {
    let dpi = match dpi::enable_per_monitor_v2() {
        Ok(()) => "Per-Monitor V2 enabled".to_string(),
        Err(err) => format!("Per-Monitor V2 failed: {}", err.message()),
    };
    let settings = lens_project::load_settings().ok();
    let displays = display::enumerate_displays().unwrap_or_default();
    println!("dpi_awareness={dpi}");
    println!(
        "library_root={}",
        settings
            .as_ref()
            .map(|item| item.library_root.as_str())
            .unwrap_or("")
    );
    println!("displays={}", displays.len());
    for item in displays {
        println!(
            "  {} {}x{} origin=({}, {}) dpi={}x{}",
            if item.is_primary {
                "primary"
            } else {
                "display"
            },
            item.width(),
            item.height(),
            item.left,
            item.top,
            item.effective_dpi_x,
            item.effective_dpi_y
        );
    }
}

pub fn run() {
    let dpi_awareness = match dpi::enable_per_monitor_v2() {
        Ok(()) => "Per-Monitor V2 enabled".to_string(),
        Err(err) => format!("Per-Monitor V2 failed: {}", err.message()),
    };
    let frontend_port = frontend_server::start().unwrap_or(0);
    let log_path = std::env::temp_dir().join("lens-startup.log");
    let _ = std::fs::write(
        &log_path,
        format!("frontend_port={frontend_port} dpi={dpi_awareness}\n"),
    );

    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    let app = app.clone();
                    if shortcut.matches(Modifiers::CONTROL | Modifiers::ALT, Code::Digit1) {
                        std::thread::spawn(move || {
                            let _ = open_overlay(&app, OverlayMode::Screenshot);
                        });
                    } else {
                        std::thread::spawn(move || {
                            let recording = app
                                .state::<Mutex<HostState>>()
                                .lock()
                                .ok()
                                .map(|state| state.recording.is_some())
                                .unwrap_or(false);
                            if recording {
                                let _ = open_record_bar(&app);
                            } else {
                                let _ = open_island(&app);
                            }
                        });
                    }
                })
                .build(),
        )
        .manage(Mutex::new(HostState::default()))
        .setup(move |app| {
            let log_path = std::env::temp_dir().join("lens-startup.log");
            let _ = std::fs::write(
                &log_path,
                format!("Lens setup starting, dpi={dpi_awareness}\n"),
            );
            let _ = app.global_shortcut().register(SCREENSHOT_SHORTCUT);
            let _ = app.global_shortcut().register(CENTER_SHORTCUT);
            if let Err(err) = setup_tray(app) {
                let _ = std::fs::write(&log_path, format!("tray failed: {err}\n"));
            }
            if let Ok(settings) = lens_project::load_settings() {
                recover_incomplete_recordings(std::path::Path::new(&settings.library_root));
            }
            keep_main_window_in_tray(app);
            let page = frontend_server::frontend_url("");
            if let Some(main) = app.get_webview_window("main") {
                if let Ok(url) = url::Url::parse(&page) {
                    let _ = main.navigate(url);
                }
                let _ = main.hide();
                let _ = std::fs::write(
                    &log_path,
                    format!("navigated to {page}, hidden for tray/hotkey shell\n"),
                );
            }
            app.manage(DpiAwareness(dpi_awareness));
            open_island(app.handle()).map_err(std::io::Error::other)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_app_state,
            set_library_root,
            open_region_overlay,
            capture_display,
            complete_region_selection,
            cancel_region_selection,
            start_display_recording,
            start_window_recording,
            stop_recording,
            pause_recording,
            list_windows,
            list_snap_edges,
            capture_window,
            scrolling_tick,
            cancel_scrolling,
            finish_scrolling,
            recognize_ocr,
            delete_item,
            cancel_media_task,
            media_task_status,
            export_video,
            export_screenshot,
            reveal_in_explorer,
            pin_last,
            save_timeline,
            render_edit,
            preview_src,
            save_annotation,
            save_screenshot_plan,
            load_screenshot_plan,
            load_captions,
            load_transcription_status,
            save_captions,
            load_timeline,
            inspect_package,
            capture_windows_composite,
            discard_recording,
            set_recording_fps,
            split_at,
            open_library,
            open_quick_access,
            open_record_bar_cmd,
            list_audio_devices,
            list_camera_devices,
            set_recording_audio_config,
            set_recording_camera_config,
            load_auto_edit_plan,
            save_auto_edit_plan
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Lens");
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "打开 Lens", true, None::<&str>)?;
    let shot = MenuItem::with_id(app, "shot", "截图", true, None::<&str>)?;
    let rec = MenuItem::with_id(app, "rec", "录制屏幕", true, None::<&str>)?;
    let exit = MenuItem::with_id(app, "exit", "退出", true, None::<&str>)?;
    let menu = MenuBuilder::new(app)
        .item(&show)
        .item(&shot)
        .item(&rec)
        .separator()
        .item(&exit)
        .build()?;
    let icon = app
        .default_window_icon()
        .cloned()
        .ok_or_else(|| tauri::Error::AssetNotFound("default window icon".into()))?;
    TrayIconBuilder::with_id("lens")
        .icon(icon)
        .tooltip("Lens")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                let _ = open_island(app);
            }
            "shot" => {
                let app = app.clone();
                std::thread::spawn(move || {
                    let _ = open_overlay(&app, OverlayMode::Screenshot);
                });
            }
            "rec" => {
                let app = app.clone();
                std::thread::spawn(move || {
                    let _ = start_recording_now(&app);
                    let _ = app.emit("lens-changed", ());
                });
            }
            "exit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn keep_main_window_in_tray(app: &tauri::App) {
    if let Some(main) = app.get_webview_window("main") {
        let handle = app.handle().clone();
        main.on_window_event(move |event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                if let Some(main) = handle.get_webview_window("main") {
                    let _ = main.hide();
                }
            }
        });
    }
}

fn show_main(app: &AppHandle) {
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.show();
        let _ = main.unminimize();
        let _ = main.set_focus();
    }
}

fn main_is_visible(app: &AppHandle) -> bool {
    app.get_webview_window("main")
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false)
}

fn restore_focus(app: &AppHandle, target: FocusRestore) {
    match target {
        FocusRestore::Main => show_main(app),
        FocusRestore::Tray => {
            if let Some(main) = app.get_webview_window("main") {
                let _ = main.hide();
            }
        }
    }
}

fn overlay_hwnd_value(overlay: &WebviewWindow) -> Result<isize, String> {
    overlay
        .hwnd()
        .map(|hwnd| hwnd.0 as isize)
        .map_err(|err| err.to_string())
}

fn apply_capture_exclusion(overlay: &WebviewWindow, state: &Mutex<HostState>) {
    let outcome = match overlay_hwnd_value(overlay) {
        Ok(hwnd) => match overlay::request_exclude_from_capture(hwnd) {
            Ok(result) => result,
            Err(err) => CaptureExclusion::Fallback {
                reason: err.to_string(),
            },
        },
        Err(err) => CaptureExclusion::Fallback { reason: err },
    };
    if let Ok(mut state) = state.lock() {
        state.capture_exclusion = Some(outcome);
    }
}

fn remember_focus(app: &AppHandle) {
    let visible = main_is_visible(app);
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.main_was_visible = Some(visible);
    }
}

fn close_overlay_and_restore(app: &AppHandle) -> Result<(), String> {
    let main_was_visible = app
        .state::<Mutex<HostState>>()
        .lock()
        .map(|state| state.main_was_visible.unwrap_or(true))
        .unwrap_or(true);
    if let Some(overlay) = app.get_webview_window(OVERLAY_LABEL) {
        overlay.close().map_err(|err| err.to_string())?;
    }
    restore_focus(app, overlay::focus_restore_target(main_was_visible));
    Ok(())
}

fn overlay_bounds() -> Result<OverlayBounds, String> {
    let displays = display::enumerate_displays().map_err(|err| err.to_string())?;
    overlay::virtual_desktop_union(&displays).ok_or_else(|| "没有可用显示器".to_string())
}

fn open_overlay(app: &AppHandle, mode: OverlayMode) -> tauri::Result<()> {
    remember_focus(app);
    if let Some(island) = app.get_webview_window("island") {
        let _ = island.hide();
    }
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.overlay_mode = mode;
    }
    if let Some(existing) = app.get_webview_window(OVERLAY_LABEL) {
        apply_capture_exclusion(&existing, &app.state::<Mutex<HostState>>());
        let _ = existing.show();
        let _ = existing.set_focus();
        return Ok(());
    }
    let bounds = overlay_bounds().map_err(|err| tauri::Error::Anyhow(anyhow::anyhow!(err)))?;
    let mode_name = match mode {
        OverlayMode::Screenshot => "screenshot",
        OverlayMode::Record => "record",
        OverlayMode::Scrolling => "scrolling",
    };
    let overlay_url = url::Url::parse(&frontend_server::frontend_url(&format!("window=overlay&mode={mode_name}")))
        .map_err(|err| tauri::Error::Anyhow(anyhow::anyhow!(err)))?;
    let overlay = WebviewWindowBuilder::new(app, OVERLAY_LABEL, WebviewUrl::External(overlay_url))
        .title("Lens 选区")
        .decorations(false)
        .transparent(true)
        .background_color(tauri::window::Color(0, 0, 0, 0))
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .shadow(false)
        .focused(true)
        .disable_drag_drop_handler()
        .inner_size(bounds.width as f64, bounds.height as f64)
        .build()?;
    overlay.set_position(Position::Physical(PhysicalPosition::new(
        bounds.left,
        bounds.top,
    )))?;
    overlay.set_size(Size::Physical(PhysicalSize::new(
        bounds.width,
        bounds.height,
    )))?;
    apply_capture_exclusion(&overlay, &app.state::<Mutex<HostState>>());
    Ok(())
}

fn library_root() -> Result<std::path::PathBuf, String> {
    Ok(std::path::PathBuf::from(
        lens_project::load_settings()
            .map_err(|err| err.to_string())?
            .library_root,
    ))
}

fn snapshot(app: &AppHandle, dpi: &str) -> Result<AppSnapshot, String> {
    let settings = lens_project::load_settings().map_err(|err| err.to_string())?;
    let items = lens_project::scan_library(std::path::Path::new(&settings.library_root))
        .unwrap_or_default();
    let cameras = std::thread::spawn(camera::enumerate_video_capture_devices)
        .join()
        .ok()
        .and_then(Result::ok)
        .map(|list| list.len())
        .unwrap_or(0);
    let camera_message = if cameras == 0 {
        "无摄像头，摄像头轨已降级".to_string()
    } else {
        format!("已发现 {cameras} 个摄像头")
    };
    let disk_free = disk::free_bytes(std::path::Path::new(&settings.library_root)).unwrap_or(0);
    let levels = lens_platform_windows::audio::current_levels();
    let state = app.state::<Mutex<HostState>>();
    let guard = state.lock().map_err(|_| "state poisoned".to_string())?;
    Ok(AppSnapshot {
        library_root: settings.library_root,
        dpi_awareness: dpi.to_string(),
        recording: guard.recording.is_some(),
        recording_paused: guard
            .recording
            .as_ref()
            .map(|session| session.is_paused())
            .unwrap_or(false),
        recording_elapsed_ms: guard
            .recording
            .as_ref()
            .map(|session| session.elapsed().as_millis() as u64)
            .unwrap_or(0),
        scrolling: guard.scrolling.is_some(),
        scroll_frames: guard
            .scrolling
            .as_ref()
            .map(|session| session.frames.len() as u32)
            .unwrap_or(0),
        capture_exclusion: guard.capture_exclusion.clone(),
        last_item: guard.last_item.clone(),
        items,
        camera_count: cameras,
        camera_message,
        disk_free_bytes: disk_free,
        disk_status: disk::status(disk_free).as_str().into(),
        audio_peak_system: levels.0,
        audio_peak_mic: levels.1,
        recording_fps: guard.recording_fps,
        audio_system_enabled: guard.audio_system_enabled,
        audio_mic_enabled: guard.audio_mic_enabled,
        camera_enabled: guard.camera_enabled,
        audio_system_device_id: guard.audio_system_device_id.clone(),
        audio_mic_device_id: guard.audio_mic_device_id.clone(),
        camera_device_link: guard.camera_device_link.clone(),
    })
}

fn take_screenshot(region: overlay::PhysicalRegion, mode: &str) -> Result<LibraryItem, String> {
    let shot = screenshot::capture_region(region).map_err(|err| err.to_string())?;
    let _ = clipboard::copy_png(&shot.png, shot.width, shot.height, &shot.bgra);
    let root = library_root()?;
    lens_project::save_screenshot_package(
        &root,
        &shot.png,
        shot.width as i64,
        shot.height as i64,
        LensRect {
            x: region.x as f64,
            y: region.y as f64,
            width: region.width as f64,
            height: region.height as f64,
        },
        mode,
    )
    .map_err(|err| err.to_string())
}

fn recover_incomplete_recordings(root: &std::path::Path) {
    lens_project::recover_incomplete_recordings(root);
}

fn start_recording_now(app: &AppHandle) -> Result<LibraryItem, String> {
    start_display_recording(app.clone())
}

fn start_recording_session_with_meta<F>(
    app: &AppHandle,
    meta: RecordingSourceMeta,
    factory: F,
) -> Result<LibraryItem, String>
where
    F: FnOnce(std::path::PathBuf) -> LiveRecording,
{
    let host = app.state::<Mutex<HostState>>();
    let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
    if state.recording.is_some() {
        return Err("已经在录制".to_string());
    }
    let root = library_root()?;
    let free = disk::free_bytes(&root).unwrap_or(0);
    if disk::status(free) == disk::DiskStatus::Stop {
        return Err("磁盘剩余不足 1 GiB，已停止新捕获。请清理空间或更换素材库目录。".into());
    }
    let (package, id) =
        lens_project::create_recording_package_with_source(&root, Some(meta.clone()))
            .map_err(|err| err.to_string())?;
    let activity_guard =
        lens_project::create_recording_activity_guard(&package).map_err(|err| err.to_string())?;
    let session = factory(package.clone());
    state.recording = Some(session);
    state.recording_id = Some((package.clone(), id.clone()));
    state.recording_activity_guard = Some(activity_guard);
    state.recording_source_meta = Some(meta);
    drop(state);
    if let Some(island) = app.get_webview_window("island") {
        let _ = island.hide();
    }
    let _ = open_record_bar(app);
    Ok(LibraryItem {
        id,
        kind: "recording".into(),
        title: "录制中".into(),
        state: "capturing".into(),
        created_at: String::new(),
        package_path: package.to_string_lossy().into_owned(),
        preview_path: None,
        duration_seconds: None,
        width: None,
        height: None,
        search_text: String::new(),
    })
}

fn finish_recording(app: &AppHandle) -> Result<LibraryItem, String> {
    let (session, package, id, mut source_meta, activity_guard) = {
        let host = app.state::<Mutex<HostState>>();
        let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
        let session = state
            .recording
            .take()
            .ok_or_else(|| "当前没有录制".to_string())?;
        let (package, id) = state
            .recording_id
            .take()
            .ok_or_else(|| "录制项目丢失".to_string())?;
        let meta = state.recording_source_meta.take();
        let activity_guard = state.recording_activity_guard.take();
        (session, package, id, meta, activity_guard)
    };
    if let Some(bar) = app.get_webview_window("record-bar") {
        let _ = bar.close();
    }
    session.request_stop();
    let finished = session.join().map_err(|err| err.to_string())?;
    drop(activity_guard);
    let segments: Vec<String> = finished
        .video
        .segments
        .iter()
        .map(|segment| segment.file.clone())
        .collect();

    let actual_fps = if finished.elapsed.as_secs_f64() > 0.05 {
        ((finished.video.frames_written as f64) / finished.elapsed.as_secs_f64()).round() as i64
    } else {
        30
    };

    if let Some(meta) = source_meta.as_mut() {
        meta.frames_per_second = Some(actual_fps);
        if let Some(hwnd) = meta.window_id {
            let hwnd_obj = windows::Win32::Foundation::HWND(hwnd as *mut std::ffi::c_void);
            let mut rect = windows::Win32::Foundation::RECT::default();
            if unsafe {
                windows::Win32::UI::WindowsAndMessaging::GetWindowRect(hwnd_obj, &mut rect).is_ok()
            } {
                if rect.right > rect.left && rect.bottom > rect.top {
                    meta.global_bounds = LensRect {
                        x: rect.left as f64,
                        y: rect.top as f64,
                        width: (rect.right - rect.left) as f64,
                        height: (rect.bottom - rect.top) as f64,
                    };
                }
            }
        }
    }

    let has_system_audio = finished
        .audio
        .as_ref()
        .and_then(|a| a.system.as_ref())
        .is_some();
    let has_microphone = finished
        .audio
        .as_ref()
        .and_then(|a| a.microphone.as_ref())
        .is_some();
    let has_camera_track = package.join("raw/camera.mp4").is_file()
        && std::fs::metadata(package.join("raw/camera.mp4"))
            .map(|m| m.len() > 0)
            .unwrap_or(false);

    let mut item = lens_project::finalize_recording_package_full(
        &package,
        &id,
        finished.video.width,
        finished.video.height,
        finished.elapsed.as_secs_f64(),
        &segments,
        has_system_audio,
        has_microphone,
        has_camera_track,
        source_meta,
    )
    .map_err(|err| err.to_string())?;

    let clicks: Vec<(f64, LensPoint)> = finished
        .events
        .clicks
        .iter()
        .map(|sample| {
            (
                sample.t_seconds,
                LensPoint {
                    x: sample.normalized_x,
                    y: sample.normalized_y,
                },
            )
        })
        .collect();
    let processing = post_process_recording(
        &package,
        &segments,
        finished.elapsed.as_secs_f64(),
        &item.title,
        &clicks,
        has_camera_track,
        finished.camera,
    );
    let mixed = package.join("previews/program.mp4");
    if mixed.exists() {
        item.preview_path = Some(mixed.to_string_lossy().into_owned());
    }
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.last_item = Some(item.clone());
    }
    if let Err(err) = processing {
        let _ = lens_project::save_json(
            &package,
            "analysis/processing.json",
            &serde_json::json!({
                "status": "failed", "message": err,
            }),
        );
        return Err(format!("原始录制已保存，但成片处理失败：{err}"));
    }
    Ok(item)
}

fn post_process_recording(
    package: &std::path::Path,
    segments: &[String],
    duration: f64,
    title: &str,
    clicks: &[(f64, LensPoint)],
    _has_camera: bool,
    camera_outcome: Option<CameraTrackOutcome>,
) -> Result<(), String> {
    let segment_dir = package.join("raw/segments");
    let concat = package.join("raw/screen.mp4");
    lens_project::post::concat_segments(&segment_dir, segments, &concat)
        .map_err(|err| err.to_string())?;
    let system = package.join("raw/system-loopback.wav");
    let mic_wav = package.join("raw/microphone.wav");
    let mic_caf = package.join("raw/microphone.caf");
    let mic = if mic_wav.exists() { mic_wav } else { mic_caf };
    let mixed = package.join("previews/program.mp4");
    lens_project::post::mix_audio(
        &concat,
        system.exists().then_some(system.as_path()),
        mic.exists().then_some(mic.as_path()),
        &mixed,
    )
    .map_err(|err| err.to_string())?;

    let wav_path = if mic.exists() {
        Some(mic.clone())
    } else if system.exists() {
        Some(system.clone())
    } else {
        None
    };
    let wav_bytes = wav_path
        .as_ref()
        .and_then(|path| std::fs::read(path).ok())
        .unwrap_or_default();
    let (engine, vad) = transcript::transcribe_best(&wav_bytes, wav_path.as_deref());
    lens_project::save_json(package, "analysis/transcription-status.json", &serde_json::json!({
        "status": if engine == "unavailable" { "unavailable" } else { "ready" },
        "message": if engine == "unavailable" { "本地转写未完成：未获得可用识别结果，请检查语音内容、本地识别引擎和模型。" } else { "本地转写已完成" },
    })).map_err(|err| err.to_string())?;
    let cues = plan_captions(&vad, 42);
    let transcript_doc = TranscriptDocument {
        schema_version: "0.1".into(),
        engine,
        generated_at: lens_project::utc_now_iso(),
        locale_identifier: "zh-CN".into(),
        is_on_device: true,
        source_role: if mic.exists() {
            "microphone"
        } else {
            "systemAudio"
        }
        .into(),
        full_text: vad
            .iter()
            .map(|s| s.text.clone())
            .collect::<Vec<_>>()
            .join(" "),
        segments: vad,
    };
    let mut plan = make_auto_edit_plan(duration, clicks);
    plan.captions.cues = cues.clone();
    let insights = organize_insights(title, &transcript_doc.full_text, "");

    let camera_report = match camera_outcome {
        Some(CameraTrackOutcome::Captured(stats)) => serde_json::json!({
            "schemaVersion": "0.1",
            "recorded": true,
            "path": "raw/camera.mp4",
            "deviceName": stats.device_name,
            "width": stats.width,
            "height": stats.height,
            "frames": stats.frames_written,
            "degraded": false,
        }),
        Some(CameraTrackOutcome::Degraded(reason)) => serde_json::json!({
            "schemaVersion": "0.1",
            "recorded": false,
            "degraded": true,
            "reason": reason,
        }),
        None => {
            let cameras = camera::enumerate_video_capture_devices().unwrap_or_default();
            serde_json::json!({
                "schemaVersion": "0.1",
                "recorded": false,
                "degraded": cameras.is_empty(),
                "reason": if cameras.is_empty() { "无摄像头，摄像头轨已降级" } else { "未开启摄像头录制" },
                "devices": cameras.iter().map(|item| item.friendly_name.clone()).collect::<Vec<_>>(),
            })
        }
    };
    let _ = lens_project::save_json(package, "analysis/camera.json", &camera_report);
    lens_project::save_json(package, "analysis/transcript.json", &transcript_doc)
        .map_err(|err| err.to_string())?;
    lens_project::save_json(package, "analysis/insights.json", &insights)
        .map_err(|err| err.to_string())?;
    lens_project::save_json_preserving_extensions(package, "edits/edit-plan.json", &plan)
        .map_err(|err| err.to_string())?;
    let vtt = cues_to_vtt(&cues);
    let vtt_path = package.join("analysis/captions.vtt");
    std::fs::write(&vtt_path, vtt).map_err(|err| err.to_string())?;

    if let Ok(report) = media_encode::scan_segmented_recording(&segment_dir) {
        let recoverable: Vec<String> = report
            .segments
            .iter()
            .filter(|segment| segment.decodable)
            .map(|segment| segment.file.clone())
            .collect();
        let recovered = package.join("previews/recovered.mp4");
        let _ = lens_project::post::write_concat_recovery(&segment_dir, &recoverable, &recovered);
        let _ = lens_project::save_json(package, "analysis/recovery.json", &report);
    }
    Ok(())
}

#[tauri::command]
fn get_app_state(
    app: AppHandle,
    dpi: tauri::State<'_, DpiAwareness>,
) -> Result<AppSnapshot, String> {
    snapshot(&app, &dpi.0)
}

#[tauri::command]
fn set_library_root(app: AppHandle, path: String) -> Result<AppSnapshot, String> {
    lens_project::save_settings(&AppSettings { library_root: path })
        .map_err(|err| err.to_string())?;
    snapshot(&app, "Per-Monitor V2 enabled")
}

#[tauri::command]
async fn open_region_overlay(app: AppHandle, mode: OverlayMode) -> Result<(), String> {
    open_overlay(&app, mode).map_err(|err| err.to_string())
}

#[tauri::command(async)]
fn capture_display(app: AppHandle) -> Result<LibraryItem, String> {
    let displays = display::enumerate_displays().map_err(|err| err.to_string())?;
    let primary = displays
        .iter()
        .find(|item| item.is_primary)
        .or_else(|| displays.first())
        .ok_or_else(|| "没有显示器".to_string())?;
    let shot = screenshot::capture_display(primary).map_err(|err| err.to_string())?;
    let _ = clipboard::copy_png(&shot.png, shot.width, shot.height, &shot.bgra);
    let item = lens_project::save_screenshot_package(
        &library_root()?,
        &shot.png,
        shot.width as i64,
        shot.height as i64,
        LensRect {
            x: primary.left as f64,
            y: primary.top as f64,
            width: shot.width as f64,
            height: shot.height as f64,
        },
        "display",
    )
    .map_err(|err| err.to_string())?;
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.last_item = Some(item.clone());
    }
    let _ = app.emit("lens-changed", ());
    let _ = show_quick_access(&app);
    Ok(item)
}

fn start_scrolling(
    app: &AppHandle,
    region: overlay::PhysicalRegion,
) -> Result<LibraryItem, String> {
    let shot = screenshot::capture_region(region).map_err(|err| err.to_string())?;
    let frame = CapturedFrame {
        width: shot.width,
        height: shot.height,
        bgra: shot.bgra,
    };
    let host = app.state::<Mutex<HostState>>();
    let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
    state.scrolling = Some(ScrollingSession {
        region,
        frames: vec![frame],
    });
    Ok(LibraryItem {
        id: "scrolling".into(),
        kind: "screenshot".into(),
        title: "长截图".into(),
        state: "capturing".into(),
        created_at: String::new(),
        package_path: String::new(),
        preview_path: None,
        duration_seconds: None,
        width: Some(shot.width as i64),
        height: Some(shot.height as i64),
        search_text: String::new(),
    })
}

#[tauri::command(async)]
fn complete_region_selection(app: AppHandle, drag: OverlayDrag) -> Result<LibraryItem, String> {
    let bounds = overlay_bounds()?;
    let mut region = overlay::map_css_drag_to_physical(
        bounds,
        drag.origin_x,
        drag.origin_y,
        drag.current_x,
        drag.current_y,
        drag.device_pixel_ratio,
    )
    .map_err(|err| err.to_string())?;
    let edges = snap_edge_rects();
    let tuples: Vec<(i32, i32, i32, i32)> = edges
        .iter()
        .map(|edge| (edge[0], edge[1], edge[2], edge[3]))
        .collect();
    region = overlay::snap_region(region, &tuples, 8, drag.alt_held).0;
    let mode = app
        .state::<Mutex<HostState>>()
        .lock()
        .map(|state| state.overlay_mode)
        .unwrap_or(OverlayMode::Screenshot);
    close_overlay_and_restore(&app)?;
    // Give the overlay a moment to leave the capture surface.
    std::thread::sleep(Duration::from_millis(80));
    let item = match mode {
        OverlayMode::Screenshot => take_screenshot(region, "region")?,
        OverlayMode::Record => {
            let (session_cfg, fps) = {
                let host = app.state::<Mutex<HostState>>();
                let state = host.lock().map_err(|_| "state poisoned".to_string())?;
                (state.session_recording_config(), state.recording_fps)
            };
            let meta = RecordingSourceMeta {
                mode: "region".into(),
                display_id: None,
                window_id: None,
                global_bounds: LensRect {
                    x: region.x as f64,
                    y: region.y as f64,
                    width: region.width as f64,
                    height: region.height as f64,
                },
                source_rect: Some(LensRect {
                    x: region.x as f64,
                    y: region.y as f64,
                    width: region.width as f64,
                    height: region.height as f64,
                }),
                window_title: None,
                application_name: None,
                frames_per_second: Some(fps as i64),
                requested_frames_per_second: Some(fps as i64),
            };
            let source = lens_platform_windows::session::video_source_for_region(region)
                .unwrap_or(VideoSource::PrimaryMonitor);
            start_recording_session_with_meta(&app, meta, move |package| {
                LiveRecording::start_source_full(package, source, session_cfg)
            })?
        }
        OverlayMode::Scrolling => start_scrolling(&app, region)?,
    };
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.last_item = Some(item.clone());
    }
    let _ = app.emit("lens-changed", ());
    if mode == OverlayMode::Screenshot {
        let _ = show_quick_access(&app);
    }
    Ok(item)
}

#[tauri::command]
fn cancel_region_selection(app: AppHandle) -> Result<(), String> {
    close_overlay_and_restore(&app)
}

#[tauri::command(async)]
fn start_display_recording(app: AppHandle) -> Result<LibraryItem, String> {
    let displays = display::enumerate_displays().unwrap_or_default();
    let primary = displays
        .iter()
        .find(|d| d.is_primary)
        .or_else(|| displays.first());
    let (display_id, width, height, left, top) = if let Some(d) = primary {
        (
            Some(0_u32),
            d.width() as f64,
            d.height() as f64,
            d.left as f64,
            d.top as f64,
        )
    } else {
        (None, 1920.0, 1080.0, 0.0, 0.0)
    };
    let (session_cfg, fps) = {
        let host = app.state::<Mutex<HostState>>();
        let state = host.lock().map_err(|_| "state poisoned".to_string())?;
        (state.session_recording_config(), state.recording_fps)
    };
    let meta = RecordingSourceMeta {
        mode: "display".into(),
        display_id,
        window_id: None,
        global_bounds: LensRect {
            x: left,
            y: top,
            width,
            height,
        },
        source_rect: None,
        window_title: None,
        application_name: None,
        frames_per_second: Some(fps as i64),
        requested_frames_per_second: Some(fps as i64),
    };
    let item = start_recording_session_with_meta(&app, meta, move |package| {
        LiveRecording::start_source_full(package, VideoSource::PrimaryMonitor, session_cfg)
    })?;
    let _ = app.emit("lens-changed", ());
    Ok(item)
}

#[tauri::command(async)]
fn stop_recording(app: AppHandle) -> Result<LibraryItem, String> {
    let item = finish_recording(&app)?;
    let _ = app.emit("lens-changed", ());
    Ok(item)
}

#[tauri::command]
fn pause_recording(app: AppHandle, paused: bool) -> Result<AppSnapshot, String> {
    {
        let host = app.state::<Mutex<HostState>>();
        let state = host.lock().map_err(|_| "state poisoned".to_string())?;
        if let Some(session) = state.recording.as_ref() {
            session.set_paused(paused);
        }
    }
    snapshot(&app, "Per-Monitor V2 enabled")
}

#[tauri::command(async)]
fn start_window_recording(app: AppHandle, hwnd: isize) -> Result<LibraryItem, String> {
    let windows_list = win_windows::enumerate_capturable_windows().unwrap_or_default();
    let win_info = windows_list.into_iter().find(|w| w.hwnd == hwnd);
    let (title, app_name, bounds) = if let Some(w) = win_info {
        (
            Some(w.title.clone()),
            None,
            LensRect {
                x: w.left as f64,
                y: w.top as f64,
                width: (w.right - w.left).max(2) as f64,
                height: (w.bottom - w.top).max(2) as f64,
            },
        )
    } else {
        (
            None,
            None,
            LensRect {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
        )
    };
    let (session_cfg, fps) = {
        let host = app.state::<Mutex<HostState>>();
        let state = host.lock().map_err(|_| "state poisoned".to_string())?;
        (state.session_recording_config(), state.recording_fps)
    };
    let meta = RecordingSourceMeta {
        mode: "window".into(),
        display_id: None,
        window_id: Some(hwnd as u32),
        global_bounds: bounds,
        source_rect: None,
        window_title: title,
        application_name: app_name,
        frames_per_second: Some(fps as i64),
        requested_frames_per_second: Some(fps as i64),
    };
    let item = start_recording_session_with_meta(&app, meta, move |package| {
        LiveRecording::start_source_full(package, VideoSource::Window { hwnd }, session_cfg)
    })?;
    let _ = app.emit("lens-changed", ());
    Ok(item)
}

#[tauri::command]
fn list_windows() -> Result<Vec<win_windows::TopLevelWindow>, String> {
    win_windows::enumerate_capturable_windows().map_err(|err| err.to_string())
}

#[tauri::command]
fn list_snap_edges() -> Result<Vec<[i32; 4]>, String> {
    Ok(snap_edge_rects())
}

#[tauri::command]
fn list_audio_devices() -> Result<Vec<audio::AudioDeviceInfo>, String> {
    audio::enumerate_audio_devices().map_err(|err| err.to_string())
}

#[tauri::command]
fn list_camera_devices() -> Result<Vec<camera::VideoCaptureDeviceInfo>, String> {
    camera::enumerate_video_capture_devices().map_err(|err| err.to_string())
}

#[tauri::command]
fn set_recording_audio_config(
    app: AppHandle,
    enable_system: bool,
    enable_mic: bool,
    system_device_id: Option<String>,
    mic_device_id: Option<String>,
) -> Result<AppSnapshot, String> {
    {
        let host = app.state::<Mutex<HostState>>();
        let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
        state.audio_system_enabled = enable_system;
        state.audio_mic_enabled = enable_mic;
        state.audio_system_device_id = system_device_id;
        state.audio_mic_device_id = mic_device_id;
    }
    snapshot(&app, "Per-Monitor V2 enabled")
}

#[tauri::command]
fn set_recording_camera_config(
    app: AppHandle,
    enable_camera: bool,
    camera_device_link: Option<String>,
) -> Result<AppSnapshot, String> {
    {
        let host = app.state::<Mutex<HostState>>();
        let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
        state.camera_enabled = enable_camera;
        state.camera_device_link = camera_device_link;
    }
    snapshot(&app, "Per-Monitor V2 enabled")
}

#[tauri::command(async)]
fn capture_window(app: AppHandle, hwnd: isize) -> Result<LibraryItem, String> {
    let shot = screenshot::capture_window(hwnd).map_err(|err| err.to_string())?;
    let _ = clipboard::copy_png(&shot.png, shot.width, shot.height, &shot.bgra);
    let item = lens_project::save_screenshot_package(
        &library_root()?,
        &shot.png,
        shot.width as i64,
        shot.height as i64,
        LensRect {
            x: 0.0,
            y: 0.0,
            width: shot.width as f64,
            height: shot.height as f64,
        },
        "window",
    )
    .map_err(|err| err.to_string())?;
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.last_item = Some(item.clone());
    }
    let _ = app.emit("lens-changed", ());
    let _ = show_quick_access(&app);
    Ok(item)
}

const MAX_SCROLLING_FRAMES: usize = 120;

#[tauri::command]
fn scrolling_tick(app: AppHandle) -> Result<u32, String> {
    let region = {
        let host = app.state::<Mutex<HostState>>();
        let state = host.lock().map_err(|_| "state poisoned".to_string())?;
        state
            .scrolling
            .as_ref()
            .map(|session| session.region)
            .ok_or_else(|| "没有进行中的长截图".to_string())?
    };
    let shot = screenshot::capture_region(region).map_err(|err| err.to_string())?;
    let frame = CapturedFrame {
        width: shot.width,
        height: shot.height,
        bgra: shot.bgra,
    };
    let host = app.state::<Mutex<HostState>>();
    let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
    if let Some(session) = state.scrolling.as_mut() {
        if session.frames.len() >= MAX_SCROLLING_FRAMES {
            return Ok(session.frames.len() as u32);
        }
        if let Some(previous) = session.frames.last() {
            if !scrolling::should_append_frame(previous, &frame) {
                return Ok(session.frames.len() as u32);
            }
        }
        session.frames.push(frame);
        return Ok(session.frames.len() as u32);
    }
    Err("没有进行中的长截图".into())
}

#[tauri::command]
fn cancel_scrolling(app: AppHandle) -> Result<(), String> {
    let host = app.state::<Mutex<HostState>>();
    let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
    state.scrolling = None;
    let _ = app.emit("lens-changed", ());
    Ok(())
}

#[tauri::command(async)]
fn finish_scrolling(app: AppHandle) -> Result<LibraryItem, String> {
    let frames = {
        let host = app.state::<Mutex<HostState>>();
        let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
        state
            .scrolling
            .take()
            .map(|session| session.frames)
            .ok_or_else(|| "没有进行中的长截图".to_string())?
    };
    let stitched =
        scrolling::stitch_vertical(&frames).ok_or_else(|| "没有可拼接的帧".to_string())?;
    let png = screenshot::encode_frame_png(&stitched.frame).map_err(|err| err.to_string())?;
    let _ = clipboard::copy_png(
        &png,
        stitched.frame.width,
        stitched.frame.height,
        &stitched.frame.bgra,
    );
    let item = lens_project::save_screenshot_package(
        &library_root()?,
        &png,
        stitched.frame.width as i64,
        stitched.frame.height as i64,
        LensRect {
            x: 0.0,
            y: 0.0,
            width: stitched.frame.width as f64,
            height: stitched.frame.height as f64,
        },
        "region",
    )
    .map_err(|err| err.to_string())?;

    let package_path = std::path::Path::new(&item.package_path);
    let scrolling_raw_dir = package_path.join("raw/scrolling");
    let _ = std::fs::create_dir_all(&scrolling_raw_dir);
    for (idx, f) in frames.iter().enumerate() {
        if let Ok(frame_png) = screenshot::encode_frame_png(f) {
            let frame_file = scrolling_raw_dir.join(format!("frame-{:03}.png", idx));
            let _ = std::fs::write(&frame_file, frame_png);
        }
    }

    let steps_json: Vec<serde_json::Value> = stitched
        .steps
        .iter()
        .map(|s| {
            serde_json::json!({
                "index": s.index,
                "verticalOffset": s.vertical_offset,
                "appendedHeight": s.appended_height,
                "overlapDifference": s.overlap_difference,
            })
        })
        .collect();

    let _ = lens_project::save_json(
        package_path,
        "events/scrolling-capture.json",
        &serde_json::json!({
            "schemaVersion": "0.1",
            "frameCount": stitched.steps.len(),
            "outputHeight": stitched.frame.height,
            "steps": steps_json,
        }),
    );
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.last_item = Some(item.clone());
    }
    let _ = app.emit("lens-changed", ());
    let _ = show_quick_access(&app);
    Ok(item)
}

#[tauri::command]
fn recognize_ocr(package: String) -> Result<ocr::OcrDocument, String> {
    let png_path = std::path::Path::new(&package).join("raw/screenshot.png");
    let bytes = std::fs::read(&png_path).map_err(|err| err.to_string())?;
    let doc = ocr::recognize_png(&bytes).map_err(|err| err.to_string())?;
    let _ = lens_project::save_json(std::path::Path::new(&package), "analysis/ocr.json", &doc);
    Ok(doc)
}

#[tauri::command]
fn delete_item(package: String) -> Result<(), String> {
    lens_project::delete_package(&library_root()?, std::path::Path::new(&package))
        .map_err(|err| err.to_string())
}

fn register_media_task(
    app: &AppHandle,
    task_id: &str,
    package: &str,
) -> Result<Arc<AtomicBool>, String> {
    if task_id.is_empty()
        || task_id.len() > 128
        || !task_id
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'-' | b'_' | b'.'))
    {
        return Err("无效的后台任务 ID".into());
    }
    let cancel = Arc::new(AtomicBool::new(false));
    let host_state = app.state::<Mutex<HostState>>();
    let mut state = host_state
        .lock()
        .map_err(|_| "应用状态锁已损坏".to_string())?;
    if state.media_tasks.contains_key(task_id) {
        return Err(format!("后台任务 ID 已在运行：{task_id}"));
    }
    if state
        .media_tasks
        .values()
        .any(|task| task.package.eq_ignore_ascii_case(package))
    {
        return Err("该项目已有渲染或导出任务正在运行".into());
    }
    state.media_tasks.insert(
        task_id.to_string(),
        MediaTaskControl {
            package: package.to_string(),
            cancel: Arc::clone(&cancel),
        },
    );
    Ok(cancel)
}

fn unregister_media_task(app: &AppHandle, task_id: &str) {
    let host_state = app.state::<Mutex<HostState>>();
    if let Ok(mut state) = host_state.lock() {
        state.media_tasks.remove(task_id);
    };
}

#[tauri::command]
fn cancel_media_task(app: AppHandle, task_id: String) -> Result<bool, String> {
    let host_state = app.state::<Mutex<HostState>>();
    let state = host_state
        .lock()
        .map_err(|_| "应用状态锁已损坏".to_string())?;
    let Some(task) = state.media_tasks.get(&task_id) else {
        return Ok(false);
    };
    task.cancel.store(true, Ordering::SeqCst);
    Ok(true)
}

#[tauri::command]
fn media_task_status(app: AppHandle, task_id: String) -> Result<String, String> {
    let host_state = app.state::<Mutex<HostState>>();
    let state = host_state
        .lock()
        .map_err(|_| "应用状态锁已损坏".to_string())?;
    Ok(match state.media_tasks.get(&task_id) {
        Some(task) if task.cancel.load(Ordering::SeqCst) => "cancelling",
        Some(_) => "running",
        None => "notFound",
    }
    .into())
}

#[tauri::command]
async fn export_video(
    app: AppHandle,
    package: String,
    preset: String,
    task_id: String,
) -> Result<String, String> {
    let cancel = register_media_task(&app, &task_id, &package)?;
    let worker_task_id = task_id.clone();
    let joined = tauri::async_runtime::spawn_blocking(move || {
        let mut worker = lens_core::WorkerClient::new();
        let package_path = std::path::PathBuf::from(&package);
        let payload = serde_json::json!({
            "root": package,
            "preset": preset,
        });
        match worker.execute_task_cancellable(
            Some(&worker_task_id),
            "export_package",
            payload,
            Duration::from_secs(180),
            &cancel,
        ) {
            Ok(resp) => {
                if let Some(path) = resp
                    .result
                    .as_ref()
                    .and_then(|r| r.get("path"))
                    .and_then(|p| p.as_str())
                {
                    return Ok(path.to_string());
                }
            }
            Err(err) => {
                let _ =
                    lens_project::render::cleanup_task_workspace(&package_path, &worker_task_id);
                let log = std::env::temp_dir().join("lens-worker-dispatch.log");
                let _ = std::fs::write(&log, format!("worker export failed: {err}\n"));
                if err.contains("cancelled") {
                    return Err("导出任务已取消".to_string());
                }
                return Err(format!("后台导出进程失败，任务可重试：{err}"));
            }
        }
        Err("后台导出进程返回成功但缺少输出路径，任务可重试".to_string())
    })
    .await;
    unregister_media_task(&app, &task_id);
    joined.map_err(|err| err.to_string())?
}

#[tauri::command]
fn save_timeline(package: String, timeline: VideoEditTimeline) -> Result<(), String> {
    lens_project::save_json_preserving_extensions(
        std::path::Path::new(&package),
        "edits/timeline.json",
        &timeline,
    )
    .map(|_| ())
    .map_err(|err| err.to_string())
}

#[tauri::command]
async fn render_edit(
    app: AppHandle,
    package: String,
    timeline: VideoEditTimeline,
    task_id: String,
) -> Result<String, String> {
    let cancel = register_media_task(&app, &task_id, &package)?;
    let worker_task_id = task_id.clone();
    let joined = tauri::async_runtime::spawn_blocking(move || {
        let mut worker = lens_core::WorkerClient::new();
        let package_path = std::path::PathBuf::from(&package);
        let payload = serde_json::json!({
            "root": package,
            "timeline": timeline,
        });
        match worker.execute_task_cancellable(
            Some(&worker_task_id),
            "render_package",
            payload,
            Duration::from_secs(180),
            &cancel,
        ) {
            Ok(resp) => {
                if let Some(path) = resp
                    .result
                    .as_ref()
                    .and_then(|r| r.get("path"))
                    .and_then(|p| p.as_str())
                {
                    return Ok(path.to_string());
                }
            }
            Err(err) => {
                let _ =
                    lens_project::render::cleanup_task_workspace(&package_path, &worker_task_id);
                let log = std::env::temp_dir().join("lens-worker-dispatch.log");
                let _ = std::fs::write(&log, format!("worker render failed: {err}\n"));
                if err.contains("cancelled") {
                    return Err("渲染任务已取消".to_string());
                }
                return Err(format!("后台渲染进程失败，任务可重试：{err}"));
            }
        }
        Err("后台渲染进程返回成功但缺少输出路径，任务可重试".to_string())
    })
    .await;
    unregister_media_task(&app, &task_id);
    joined.map_err(|err| err.to_string())?
}

#[tauri::command]
fn preview_src(path: String) -> Result<String, String> {
    let bytes = std::fs::read(&path).map_err(|err| format!("无法读取预览：{err}"))?;
    if bytes.is_empty() {
        return Err("预览文件是空的".into());
    }
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".mp4")
        || lower.ends_with(".webm")
        || lower.ends_with(".mov")
        || lower.ends_with(".m4v")
    {
        return Ok(format!(
            "https://asset.localhost/{}",
            std::path::PathBuf::from(&path)
                .to_string_lossy()
                .replace('\\', "/")
        ));
    }
    let mime = if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        "image/jpeg"
    } else {
        "image/png"
    };
    Ok(format!("data:{mime};base64,{}", encode_base64(&bytes)))
}

fn encode_base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0] as u32;
        let b = chunk.get(1).copied().unwrap_or(0) as u32;
        let c = chunk.get(2).copied().unwrap_or(0) as u32;
        let triple = (a << 16) | (b << 8) | c;
        out.push(TABLE[((triple >> 18) & 63) as usize] as char);
        out.push(TABLE[((triple >> 12) & 63) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((triple >> 6) & 63) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(triple & 63) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

#[tauri::command(async)]
fn pin_last(app: AppHandle) -> Result<(), String> {
    if app.get_webview_window("pin").is_some() {
        if let Some(existing) = app.get_webview_window("pin") {
            let _ = existing.show();
            let _ = existing.set_focus();
        }
        return Ok(());
    }
    let pin_url = url::Url::parse(&frontend_server::frontend_url("window=pin"))
        .map_err(|err| err.to_string())?;
    WebviewWindowBuilder::new(&app, "pin", WebviewUrl::External(pin_url))
        .title("贴图")
        .decorations(false)
        .always_on_top(true)
        .inner_size(420.0, 280.0)
        .build()
        .map_err(|err| err.to_string())?;
    Ok(())
}

#[tauri::command]
fn save_annotation(package: String, png_base64: String) -> Result<String, String> {
    let bytes = decode_data_url(&png_base64)?;
    let path = lens_project::save_annotated_png(std::path::Path::new(&package), &bytes)
        .map_err(|err| err.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
fn export_screenshot(
    package: String,
    data_url: String,
    format: String,
    target_path: Option<String>,
) -> Result<String, String> {
    let bytes = decode_data_url(&data_url)?;
    let target = target_path.as_deref().map(std::path::Path::new);
    let path =
        lens_project::export_screenshot(std::path::Path::new(&package), &bytes, &format, target)
            .map_err(|err| err.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
fn reveal_in_explorer(path: String) -> Result<(), String> {
    let target = std::path::PathBuf::from(&path);
    if !target.exists() {
        return Err(format!("目标路径不存在: {path}"));
    }
    let path_str = target.to_string_lossy();
    let arg = format!("/select,\"{path_str}\"");
    std::process::Command::new("explorer")
        .arg(&arg)
        .spawn()
        .map_err(|err| format!("打开资源管理器失败: {err}"))?;
    Ok(())
}

#[tauri::command]
fn save_screenshot_plan(package: String, plan: ScreenshotEditPlan) -> Result<(), String> {
    lens_project::save_json_preserving_extensions(
        std::path::Path::new(&package),
        "edits/screenshot-edit.json",
        &plan,
    )
    .map(|_| ())
    .map_err(|err| err.to_string())
}

#[tauri::command]
fn load_screenshot_plan(package: String) -> Result<Option<ScreenshotEditPlan>, String> {
    let path = std::path::Path::new(&package).join("edits/screenshot-edit.json");
    if !path.exists() {
        return Ok(None);
    }
    let text = std::fs::read_to_string(&path).map_err(|err| err.to_string())?;
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|err| err.to_string())
}

#[tauri::command]
fn load_transcription_status(package: String) -> Result<Option<serde_json::Value>, String> {
    let path = std::path::Path::new(&package).join("analysis/transcription-status.json");
    if !path.exists() {
        return Ok(None);
    }
    let bytes = std::fs::read(path).map_err(|err| err.to_string())?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|err| err.to_string())
}

#[tauri::command]
fn load_captions(package: String) -> Result<Vec<CaptionCue>, String> {
    let edits = std::path::Path::new(&package).join("edits/captions.vtt");
    let analysis = std::path::Path::new(&package).join("analysis/captions.vtt");
    let path = if edits.exists() { edits } else { analysis };
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = std::fs::read_to_string(&path).map_err(|err| err.to_string())?;
    Ok(vtt_to_cues(&text))
}

#[tauri::command]
fn save_captions(package: String, cues: Vec<CaptionCue>) -> Result<(), String> {
    let vtt = cues_to_vtt(&cues);
    let root = std::path::Path::new(&package);
    std::fs::create_dir_all(root.join("edits")).map_err(|err| err.to_string())?;
    std::fs::write(root.join("edits/captions.vtt"), &vtt).map_err(|err| err.to_string())?;
    std::fs::create_dir_all(root.join("analysis")).map_err(|err| err.to_string())?;
    std::fs::write(root.join("analysis/captions.vtt"), vtt).map_err(|err| err.to_string())?;
    Ok(())
}

#[tauri::command]
fn load_timeline(package: String) -> Result<Option<VideoEditTimeline>, String> {
    let timeline = std::path::Path::new(&package).join("edits/timeline.json");
    let plan = std::path::Path::new(&package).join("edits/edit-plan.json");
    if timeline.exists() {
        let text = std::fs::read_to_string(&timeline).map_err(|err| err.to_string())?;
        return serde_json::from_str(&text)
            .map(Some)
            .map_err(|err| err.to_string());
    }
    if plan.exists() {
        let text = std::fs::read_to_string(&plan).map_err(|err| err.to_string())?;
        let value: serde_json::Value =
            serde_json::from_str(&text).map_err(|err| err.to_string())?;
        if let Some(timeline) = value.get("timeline") {
            return serde_json::from_value(timeline.clone())
                .map(Some)
                .map_err(|err| err.to_string());
        }
    }
    Ok(None)
}

#[tauri::command]
fn load_auto_edit_plan(package: String) -> Result<Option<lens_core::edit::AutoEditPlan>, String> {
    lens_project::render::load_auto_edit_plan(std::path::Path::new(&package))
        .map_err(|err| err.to_string())
}

#[tauri::command]
fn save_auto_edit_plan(package: String, plan: lens_core::edit::AutoEditPlan) -> Result<(), String> {
    lens_project::save_json_preserving_extensions(
        std::path::Path::new(&package),
        "edits/edit-plan.json",
        &plan,
    )
    .map(|_| ())
    .map_err(|err| err.to_string())
}

#[tauri::command]
fn inspect_package(package: String) -> Result<interop::PackageInspect, String> {
    lens_project::inspect_package(std::path::Path::new(&package)).map_err(|err| err.to_string())
}

#[tauri::command(async)]
fn capture_windows_composite(app: AppHandle, hwnds: Vec<isize>) -> Result<LibraryItem, String> {
    let listed = win_windows::enumerate_capturable_windows().map_err(|err| err.to_string())?;
    let mut targets = Vec::new();
    for hwnd in hwnds {
        let found = listed
            .iter()
            .find(|item| item.hwnd == hwnd)
            .ok_or_else(|| format!("窗口已关闭或不可捕获：{hwnd}"))?;
        targets.push(screenshot::WindowPlacement {
            hwnd: found.hwnd,
            left: found.left,
            top: found.top,
            right: found.right,
            bottom: found.bottom,
        });
    }
    let shot = screenshot::capture_windows_composite(&targets).map_err(|err| err.to_string())?;
    let _ = clipboard::copy_png(&shot.png, shot.width, shot.height, &shot.bgra);
    let item = lens_project::save_screenshot_package(
        &library_root()?,
        &shot.png,
        shot.width as i64,
        shot.height as i64,
        LensRect {
            x: shot.display_left as f64,
            y: shot.display_top as f64,
            width: shot.width as f64,
            height: shot.height as f64,
        },
        "window",
    )
    .map_err(|err| err.to_string())?;
    if let Ok(mut state) = app.state::<Mutex<HostState>>().lock() {
        state.last_item = Some(item.clone());
    }
    let _ = app.emit("lens-changed", ());
    let _ = show_quick_access(&app);
    Ok(item)
}

#[tauri::command]
fn discard_recording(app: AppHandle) -> Result<(), String> {
    let (session, package, activity_guard) = {
        let host = app.state::<Mutex<HostState>>();
        let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
        let session = state
            .recording
            .take()
            .ok_or_else(|| "当前没有录制".to_string())?;
        let (package, _) = state
            .recording_id
            .take()
            .ok_or_else(|| "录制项目丢失".to_string())?;
        let activity_guard = state.recording_activity_guard.take();
        (session, package, activity_guard)
    };
    session.request_stop();
    let _ = session.join();
    drop(activity_guard);
    if package.exists() {
        let _ = std::fs::remove_dir_all(&package);
    }
    if let Some(bar) = app.get_webview_window("record-bar") {
        let _ = bar.close();
    }
    let _ = app.emit("lens-changed", ());
    Ok(())
}

#[tauri::command]
fn set_recording_fps(app: AppHandle, fps: u32) -> Result<AppSnapshot, String> {
    {
        let host = app.state::<Mutex<HostState>>();
        let mut state = host.lock().map_err(|_| "state poisoned".to_string())?;
        state.recording_fps = if fps >= 60 { 60 } else { 30 };
    }
    snapshot(&app, "Per-Monitor V2 enabled")
}

#[tauri::command]
fn split_at(package: String, seconds: f64) -> Result<VideoEditTimeline, String> {
    let timeline = load_timeline(package.clone())?.unwrap_or_else(|| VideoEditTimeline {
        schema_version: "0.1".into(),
        segments: vec![],
    });
    let split = split_timeline(&timeline, seconds);
    save_timeline(package, split.clone())?;
    Ok(split)
}

#[tauri::command]
fn open_library(app: AppHandle) -> Result<(), String> {
    if let Some(island) = app.get_webview_window("island") {
        let _ = island.hide();
    }
    show_main(&app);
    if let Ok(state) = app.state::<Mutex<HostState>>().lock() {
        if let Some(item) = &state.last_item {
            let _ = app.emit_to("main", "lens-open-item", item.package_path.clone());
        }
    }
    Ok(())
}

fn snap_edge_rects() -> Vec<[i32; 4]> {
    let mut edges = Vec::new();
    if let Ok(displays) = display::enumerate_displays() {
        for item in displays {
            edges.push([item.left, item.top, item.right, item.bottom]);
        }
    }
    if let Ok(windows) = win_windows::enumerate_capturable_windows() {
        for item in windows {
            edges.push([item.left, item.top, item.right, item.bottom]);
        }
    }
    edges
}

fn open_record_bar(app: &AppHandle) -> Result<(), String> {
    if let Some(existing) = app.get_webview_window("record-bar") {
        let _ = existing.show();
        let _ = existing.set_focus();
        return Ok(());
    }
    let url = url::Url::parse(&frontend_server::frontend_url("window=record-bar"))
        .map_err(|err| err.to_string())?;
    WebviewWindowBuilder::new(app, "record-bar", WebviewUrl::External(url))
        .title("Lens 录制")
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .inner_size(520.0, 88.0)
        .build()
        .map_err(|err| err.to_string())?;
    Ok(())
}

fn open_island(app: &AppHandle) -> Result<(), String> {
    if let Some(existing) = app.get_webview_window("island") {
        let _ = existing.show();
        let _ = existing.unminimize();
        let _ = existing.set_focus();
        return Ok(());
    }
    let url = url::Url::parse(&frontend_server::frontend_url("window=island"))
        .map_err(|err| err.to_string())?;
    WebviewWindowBuilder::new(app, "island", WebviewUrl::External(url))
        .title("Lens")
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .inner_size(680.0, 380.0)
        .center()
        .build()
        .map_err(|err| err.to_string())?;
    Ok(())
}

fn show_quick_access(app: &AppHandle) -> Result<(), String> {
    if let Some(existing) = app.get_webview_window("quick-access") {
        let _ = existing.close();
    }
    let url = url::Url::parse(&frontend_server::frontend_url("window=quick-access"))
        .map_err(|err| err.to_string())?;
    let cursor = app.cursor_position().map_err(|err| err.to_string())?;
    let monitor = app.monitor_from_point(cursor.x, cursor.y).map_err(|err| err.to_string())?
        .or(app.primary_monitor().map_err(|err| err.to_string())?).ok_or("没有可用显示器")?;
    let area = monitor.work_area();
    let scale = monitor.scale_factor();
    let width = (420.0 * scale).round() as i32;
    let height = (148.0 * scale).round() as i32;
    let margin = (20.0 * scale).round() as i32;
    let max_x = area.position.x + area.size.width as i32 - width - margin;
    let max_y = area.position.y + area.size.height as i32 - height - margin;
    let placement_path = app.path().app_config_dir().map_err(|err| err.to_string())?.join("quick-access-position.json");
    let saved = std::fs::read(&placement_path).ok()
        .and_then(|bytes| serde_json::from_slice::<[i32; 2]>(&bytes).ok());
    let position = saved.filter(|[x, y]| *x >= area.position.x && *x <= max_x && *y >= area.position.y && *y <= max_y)
        .unwrap_or([max_x.max(area.position.x), max_y.max(area.position.y)]);
    let quick = WebviewWindowBuilder::new(app, "quick-access", WebviewUrl::External(url))
        .title("Quick Access")
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .visible(false)
        .inner_size(420.0, 148.0)
        .build()
        .map_err(|err| err.to_string())?;
    quick.set_position(Position::Physical(PhysicalPosition::new(position[0], position[1]))).map_err(|err| err.to_string())?;
    quick.on_window_event(move |event| {
        if let WindowEvent::Moved(position) = event {
            if let Some(parent) = placement_path.parent() { let _ = std::fs::create_dir_all(parent); }
            if let Ok(bytes) = serde_json::to_vec(&[position.x, position.y]) {
                let _ = std::fs::write(&placement_path, bytes);
            }
        }
    });
    quick.show().map_err(|err| err.to_string())?;
    Ok(())
}

#[tauri::command(async)]
fn open_quick_access(app: AppHandle) -> Result<(), String> {
    show_quick_access(&app)
}

#[tauri::command(async)]
fn open_record_bar_cmd(app: AppHandle) -> Result<(), String> {
    open_record_bar(&app)
}

fn decode_data_url(value: &str) -> Result<Vec<u8>, String> {
    let payload = value
        .split(',')
        .next_back()
        .ok_or_else(|| "empty annotation".to_string())?;
    decode_base64(payload)
}

fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let filtered: String = input.chars().filter(|ch| !ch.is_whitespace()).collect();
    if filtered.len() % 4 != 0 {
        return Err("invalid base64".into());
    }
    let table = |c: u8| -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let bytes = filtered.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let a = table(chunk[0]).ok_or("invalid base64")?;
        let b = table(chunk[1]).ok_or("invalid base64")?;
        out.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            let c = table(chunk[2]).ok_or("invalid base64")?;
            out.push((b << 4) | (c >> 2));
            if chunk[3] != b'=' {
                let d = table(chunk[3]).ok_or("invalid base64")?;
                out.push((c << 6) | d);
            }
        }
    }
    Ok(out)
}
