#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(not(target_os = "windows"))]
compile_error!("Lens Windows requires Windows. Use cargo test -p lens-core for portable core tests.");

mod audio;
mod media;
mod native;
mod service;
mod shortcuts;

use std::{path::PathBuf, sync::Arc};
use lens_core::{Crop, Phase, RecordOptions};
use parking_lot::Mutex;
use serde::Serialize;
use tauri::{Emitter, Manager, State};
use service::{Service, Status, LibraryItem};

#[derive(Default)]
struct RegionState(Mutex<Option<native::Source>>);

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct RegionResult { source_id: String, crop: Crop }

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppInfo {
    version: &'static str,
    library_path: String,
    ffmpeg_available: bool,
    platform: &'static str,
}

async fn blocking<T, F>(work: F) -> Result<T, String>
where T: Send + 'static, F: FnOnce() -> Result<T, String> + Send + 'static {
    tauri::async_runtime::spawn_blocking(work).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn app_info(service: State<'_, Arc<Service>>) -> AppInfo {
    AppInfo {
        version: env!("CARGO_PKG_VERSION"),
        library_path: service.root.to_string_lossy().into_owned(),
        ffmpeg_available: media::ffmpeg().is_some(),
        platform: "windows-x64",
    }
}

#[tauri::command]
async fn list_sources() -> Result<Vec<native::Source>, String> {
    blocking(native::sources).await
}

#[tauri::command]
fn record_status(service: State<'_, Arc<Service>>) -> Status { service.status() }

#[tauri::command]
async fn start_recording(service: State<'_, Arc<Service>>, options: RecordOptions) -> Result<(), String> {
    let service = service.inner().clone();
    blocking(move || service.start(options)).await
}

#[tauri::command]
async fn pause_recording(service: State<'_, Arc<Service>>) -> Result<(), String> {
    let service = service.inner().clone();
    blocking(move || service.pause()).await
}

#[tauri::command]
async fn resume_recording(service: State<'_, Arc<Service>>) -> Result<(), String> {
    let service = service.inner().clone();
    blocking(move || service.resume()).await
}

#[tauri::command]
async fn stop_recording(service: State<'_, Arc<Service>>) -> Result<String, String> {
    let service = service.inner().clone();
    blocking(move || service.stop()).await
}

#[tauri::command]
async fn take_screenshot(service: State<'_, Arc<Service>>, options: RecordOptions) -> Result<String, String> {
    let service = service.inner().clone();
    blocking(move || service.screenshot(options)).await
}

#[tauri::command]
async fn list_projects(service: State<'_, Arc<Service>>) -> Result<Vec<LibraryItem>, String> {
    let service = service.inner().clone();
    blocking(move || service.library()).await
}

#[tauri::command]
async fn retry_export(service: State<'_, Arc<Service>>, path: String) -> Result<(), String> {
    let service = service.inner().clone();
    blocking(move || service.retry_export(&path)).await
}

#[tauri::command]
async fn open_project(service: State<'_, Arc<Service>>, path: Option<String>) -> Result<(), String> {
    let service = service.inner().clone();
    blocking(move || {
        let directory = match path {
            Some(path) => service.owned_project(&path)?.path,
            None => service.root.clone(),
        };
        // Never dispatch URLs, a shell string, or a user-supplied executable.
        let windows = std::env::var_os("WINDIR").ok_or("找不到 Windows 系统目录")?;
        std::process::Command::new(PathBuf::from(windows).join("explorer.exe"))
            .arg(directory).spawn().map_err(|e| e.to_string())?;
        Ok(())
    }).await
}

#[tauri::command]
async fn select_region(
    app: tauri::AppHandle,
    service: State<'_, Arc<Service>>,
    region: State<'_, RegionState>,
    source_id: String,
) -> Result<(), String> {
    if service.status().phase != Phase::Idle { return Err("请先停止录制再选择区域".into()); }
    if app.get_webview_window("region").is_some() { return Err("已有选区窗口，请先完成或取消".into()); }
    let source = blocking(move || {
        native::sources()?.into_iter().find(|s| s.id == source_id && s.kind == "display")
            .ok_or("区域选择需要一个仍在线的显示器".into())
    }).await?;
    *region.0.lock() = Some(source.clone());
    // Creating a WebView from an async command avoids WebView2 synchronous-command deadlocks.
    let result = (|| -> Result<(), String> {
        let window = tauri::WebviewWindowBuilder::new(&app, "region", tauri::WebviewUrl::App("region.html".into()))
            .title("Lens · 选择录制区域")
            .decorations(false).transparent(true).shadow(false).always_on_top(true)
            .resizable(false).skip_taskbar(true).visible(false)
            .build().map_err(|e| e.to_string())?;
        window.set_position(tauri::PhysicalPosition::new(source.x, source.y)).map_err(|e| e.to_string())?;
        window.set_size(tauri::PhysicalSize::new(source.width, source.height)).map_err(|e| e.to_string())?;
        let _ = window.set_content_protected(true);
        if let Some(main) = app.get_webview_window("main") { let _ = main.hide(); }
        window.show().map_err(|e| e.to_string())?;
        window.set_focus().map_err(|e| e.to_string())?;
        Ok(())
    })();
    if result.is_err() {
        region.0.lock().take();
        if let Some(w) = app.get_webview_window("region") { let _ = w.destroy(); }
        if let Some(main) = app.get_webview_window("main") { let _ = main.show(); }
    }
    result
}

#[tauri::command]
fn region_context(region: State<'_, RegionState>) -> Result<native::Source, String> {
    region.0.lock().clone().ok_or("没有有效选区会话".into())
}

#[tauri::command]
fn finish_region(app: tauri::AppHandle, region: State<'_, RegionState>, crop: Option<Crop>) -> Result<(), String> {
    let source = region.0.lock().clone().ok_or("没有有效选区会话")?;
    let selected = crop.map(|c| c.validate(source.width, source.height)).transpose()?;
    region.0.lock().take();
    if let Some(w) = app.get_webview_window("region") { let _ = w.destroy(); }
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.show(); let _ = main.set_focus();
        if let Some(crop) = selected {
            main.emit("region-picked", RegionResult { source_id: source.id, crop }).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn main() {
    // Establish physical-coordinate semantics before any windows or monitor enumeration.
    unsafe {
        use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show(); let _ = window.unminimize(); let _ = window.set_focus();
            }
        }))
        .manage(RegionState::default())
        .setup(|app| {
            let root = dirs::video_dir().or_else(dirs::document_dir)
                .ok_or_else(|| std::io::Error::other("找不到当前用户的视频或文档目录"))?
                .join("Lens-Windows");
            let service = Service::new(root).map_err(std::io::Error::other)?;
            app.asset_protocol_scope().allow_directory(&service.root, true)?;
            if let Some(window) = app.get_webview_window("main") {
                if window.set_content_protected(true).is_err() {
                    service.notify("系统未能排除 Lens 窗口，请录制前最小化主窗口");
                }
            }
            service.monitor();
            shortcuts::start(service.clone());
            app.manage(service);
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    let service = window.state::<Arc<Service>>();
                    if service.status().phase != Phase::Idle {
                        api.prevent_close();
                        let _ = window.emit("close-blocked", "请先停止录制并等待保存，再关闭 Lens");
                    }
                } else if window.label() == "region" {
                    window.state::<RegionState>().0.lock().take();
                    if let Some(main) = window.get_webview_window("main") { let _ = main.show(); let _ = main.set_focus(); }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            app_info, list_sources, record_status, start_recording, pause_recording,
            resume_recording, stop_recording, take_screenshot, list_projects,
            retry_export, open_project, select_region, region_context, finish_region
        ]);
    if let Err(error) = builder.run(tauri::generate_context!()) {
        // GUI startup failures are also visible when launching from a terminal.
        eprintln!("Lens 启动失败：{error}");
        let message:Vec<u16>=format!("Lens 启动失败：{error}").encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW,MB_OK,MB_ICONERROR};
            let _=MessageBoxW(None,windows::core::PCWSTR(message.as_ptr()),windows::core::w!("Lens Windows"),MB_OK|MB_ICONERROR);
        }
        std::process::exit(1);
    }
}
