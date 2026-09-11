//! `.lens` package creation, library scanning, and settings for Windows.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub use lens_core::manifest::LensManifest;
use lens_core::manifest::{
    LensAsset, LensDimensions, LensRect, RecordingCaptureSource, ScreenshotCaptureSource,
    CURRENT_MANIFEST_VERSION,
};
use serde::{Deserialize, Serialize};
use windows::Win32::System::Com::CoCreateGuid;

pub mod post;
pub mod render;

#[derive(Debug, thiserror::Error)]
pub enum ProjectError {
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("invalid screenshot dimensions")]
    InvalidDimensions,
    #[error("package already exists")]
    PackageExists,
    #[error("manifest is not readable: {0}")]
    Manifest(String),
    #[error("image format error: {0}")]
    BadImageFormat(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryItem {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub state: String,
    pub created_at: String,
    pub package_path: String,
    pub preview_path: Option<String>,
    pub duration_seconds: Option<f64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    #[serde(default)]
    pub search_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub library_root: String,
}

pub fn default_library_root() -> PathBuf {
    let pictures = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("E:/"));
    let candidate = PathBuf::from("E:/Lens");
    if Path::new("E:/").exists() {
        candidate
    } else {
        pictures.join("Pictures").join("Lens")
    }
}

pub fn settings_path() -> PathBuf {
    let appdata = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    appdata.join("Lens").join("settings.json")
}

pub fn load_settings() -> Result<AppSettings, ProjectError> {
    let path = settings_path();
    if path.exists() {
        let text = fs::read_to_string(&path)?;
        let settings: AppSettings = serde_json::from_str(&text)?;
        return Ok(settings);
    }
    let settings = AppSettings {
        library_root: default_library_root().to_string_lossy().into_owned(),
    };
    save_settings(&settings)?;
    Ok(settings)
}

pub fn save_settings(settings: &AppSettings) -> Result<(), ProjectError> {
    let path = settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    write_atomic(&path, serde_json::to_vec_pretty(settings)?)?;
    Ok(())
}

pub fn new_uuid() -> String {
    let guid = unsafe { CoCreateGuid().unwrap_or_default() };
    format!(
        "{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        guid.data1,
        guid.data2,
        guid.data3,
        guid.data4[0],
        guid.data4[1],
        guid.data4[2],
        guid.data4[3],
        guid.data4[4],
        guid.data4[5],
        guid.data4[6],
        guid.data4[7]
    )
}

pub fn utc_now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    unix_to_iso8601(secs)
}

fn unix_to_iso8601(mut secs: u64) -> String {
    let days = secs / 86400;
    secs %= 86400;
    let hour = secs / 3600;
    let minute = (secs % 3600) / 60;
    let second = secs % 60;
    let z = days as i64 + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, minute, second
    )
}

fn write_atomic(path: &Path, bytes: Vec<u8>) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
    }
    if path.exists() {
        let _ = fs::remove_file(path);
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

fn json_identity(value: &serde_json::Value) -> Option<String> {
    let object = value.as_object()?;
    for key in ["id", "taskId"] {
        if let Some(value) = object.get(key).and_then(|value| value.as_str()) {
            return Some(format!("{key}:{value}"));
        }
    }
    if let (Some(role), Some(path)) = (
        object.get("role").and_then(|value| value.as_str()),
        object.get("relativePath").and_then(|value| value.as_str()),
    ) {
        return Some(format!("asset:{role}:{path}"));
    }
    for key in ["time", "startSeconds", "sourceStartSeconds"] {
        if let Some(value) = object.get(key).and_then(|value| value.as_f64()) {
            return Some(format!("{key}:{value:.9}"));
        }
    }
    None
}

fn merge_unknown_json_fields(existing: &serde_json::Value, updated: &mut serde_json::Value) {
    if let (Some(existing), Some(updated)) = (existing.as_object(), updated.as_object_mut()) {
        for (key, old_value) in existing {
            match updated.get_mut(key) {
                Some(new_value) => merge_unknown_json_fields(old_value, new_value),
                None => {
                    updated.insert(key.clone(), old_value.clone());
                }
            }
        }
        return;
    }
    if let (Some(existing), Some(updated)) = (existing.as_array(), updated.as_array_mut()) {
        for (index, new_value) in updated.iter_mut().enumerate() {
            let old_value = json_identity(new_value)
                .and_then(|identity| {
                    existing
                        .iter()
                        .find(|candidate| json_identity(candidate).as_deref() == Some(&identity))
                })
                .or_else(|| existing.get(index));
            if let Some(old_value) = old_value {
                merge_unknown_json_fields(old_value, new_value);
            }
        }
    }
}

fn managed_asset_role(role: &str) -> bool {
    matches!(
        role,
        "screenshot"
            | "screenVideo"
            | "screenVideoSegment"
            | "recordingSegments"
            | "systemAudio"
            | "microphone"
            | "camera"
    )
}

fn write_manifest_preserving_extensions(
    path: &Path,
    manifest: &LensManifest,
) -> Result<(), ProjectError> {
    let mut updated = serde_json::to_value(manifest)?;
    if let Ok(bytes) = fs::read(path) {
        if let Ok(existing) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            merge_unknown_json_fields(&existing, &mut updated);
            if let (Some(old_assets), Some(new_assets)) = (
                existing.get("assets").and_then(|value| value.as_array()),
                updated
                    .get_mut("assets")
                    .and_then(|value| value.as_array_mut()),
            ) {
                for old_asset in old_assets {
                    let role = old_asset
                        .get("role")
                        .and_then(|value| value.as_str())
                        .unwrap_or("");
                    let relative_path = old_asset
                        .get("relativePath")
                        .and_then(|value| value.as_str())
                        .unwrap_or("");
                    if let Some(new_asset) = new_assets.iter_mut().find(|asset| {
                        asset.get("role").and_then(|value| value.as_str()) == Some(role)
                            && asset.get("relativePath").and_then(|value| value.as_str())
                                == Some(relative_path)
                    }) {
                        merge_unknown_json_fields(old_asset, new_asset);
                    } else if !role.is_empty()
                        && !relative_path.is_empty()
                        && !managed_asset_role(role)
                    {
                        new_assets.push(old_asset.clone());
                    }
                }
            }
        }
    }
    write_atomic(path, serde_json::to_vec_pretty(&updated)?)?;
    Ok(())
}

fn unique_package_dir(root: &Path, created_at: &str, id: &str) -> PathBuf {
    let stamp = created_at.replace(':', "").replace('-', "");
    let short = id.split('-').next().unwrap_or(id);
    root.join(format!("{stamp}-{short}.lens"))
}

fn ensure_package_dirs(package: &Path) -> io::Result<()> {
    for name in ["raw", "events", "analysis", "edits", "previews"] {
        fs::create_dir_all(package.join(name))?;
    }
    Ok(())
}

pub fn save_screenshot_package(
    library_root: &Path,
    png: &[u8],
    width: i64,
    height: i64,
    region: LensRect,
    mode: &str,
) -> Result<LibraryItem, ProjectError> {
    if width <= 0 || height <= 0 || png.is_empty() {
        return Err(ProjectError::InvalidDimensions);
    }
    fs::create_dir_all(library_root)?;
    let id = new_uuid();
    let created_at = utc_now_iso();
    let package = unique_package_dir(library_root, &created_at, &id);
    if package.exists() {
        return Err(ProjectError::PackageExists);
    }
    ensure_package_dirs(&package)?;
    write_atomic(&package.join("raw/screenshot.png"), png.to_vec())?;
    let title = format!(
        "截图 {}",
        created_at.replace('T', " ").trim_end_matches('Z')
    );
    let manifest = LensManifest {
        schema_version: CURRENT_MANIFEST_VERSION.into(),
        id: id.clone(),
        kind: "screenshot".into(),
        created_at: created_at.clone(),
        title: title.clone(),
        state: "ready".into(),
        duration_seconds: None,
        dimensions: Some(LensDimensions { width, height }),
        capture_source: None,
        screenshot_capture_source: Some(ScreenshotCaptureSource {
            mode: mode.into(),
            display_id: None,
            window_ids: Vec::new(),
            global_bounds: region.clone(),
            source_rect: Some(region.clone()),
            window_title: None,
            application_name: None,
        }),
        assets: vec![LensAsset {
            role: "screenshot".into(),
            relative_path: "raw/screenshot.png".into(),
        }],
    };
    manifest
        .validate()
        .map_err(|err| ProjectError::Manifest(err.to_string()))?;
    write_manifest_preserving_extensions(&package.join("manifest.json"), &manifest)?;
    Ok(LibraryItem {
        id,
        kind: "screenshot".into(),
        title,
        state: "ready".into(),
        created_at,
        package_path: package.to_string_lossy().into_owned(),
        preview_path: Some(
            package
                .join("raw/screenshot.png")
                .to_string_lossy()
                .into_owned(),
        ),
        duration_seconds: None,
        width: Some(width),
        height: Some(height),
        search_text: String::new(),
    })
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingSourceMeta {
    pub mode: String,
    pub display_id: Option<u32>,
    pub window_id: Option<u32>,
    pub global_bounds: LensRect,
    pub source_rect: Option<LensRect>,
    pub window_title: Option<String>,
    pub application_name: Option<String>,
    pub frames_per_second: Option<i64>,
    pub requested_frames_per_second: Option<i64>,
}

pub fn create_recording_package(library_root: &Path) -> Result<(PathBuf, String), ProjectError> {
    create_recording_package_with_source(library_root, None)
}

pub fn create_recording_package_with_source(
    library_root: &Path,
    source: Option<RecordingSourceMeta>,
) -> Result<(PathBuf, String), ProjectError> {
    fs::create_dir_all(library_root)?;
    let id = new_uuid();
    let created_at = utc_now_iso();
    let package = unique_package_dir(library_root, &created_at, &id);
    ensure_package_dirs(&package)?;
    fs::create_dir_all(package.join("raw/segments"))?;
    let placeholder = LensManifest {
        schema_version: CURRENT_MANIFEST_VERSION.into(),
        id: id.clone(),
        kind: "recording".into(),
        created_at,
        title: "录屏".into(),
        state: "capturing".into(),
        duration_seconds: None,
        dimensions: None,
        capture_source: Some(if let Some(src) = source {
            RecordingCaptureSource {
                mode: src.mode,
                display_id: src.display_id,
                window_id: src.window_id,
                global_bounds: src.global_bounds,
                source_rect: src.source_rect,
                window_title: src.window_title,
                application_name: src.application_name,
                frames_per_second: src.frames_per_second,
                requested_frames_per_second: src.requested_frames_per_second,
            }
        } else {
            RecordingCaptureSource {
                mode: "display".into(),
                display_id: None,
                window_id: None,
                global_bounds: LensRect {
                    x: 0.0,
                    y: 0.0,
                    width: 0.0,
                    height: 0.0,
                },
                source_rect: None,
                window_title: None,
                application_name: None,
                frames_per_second: Some(30),
                requested_frames_per_second: Some(30),
            }
        }),
        screenshot_capture_source: None,
        assets: Vec::new(),
    };
    write_manifest_preserving_extensions(&package.join("manifest.json"), &placeholder)?;
    Ok((package, id))
}

pub fn finalize_recording_package(
    package: &Path,
    id: &str,
    width: u32,
    height: u32,
    duration_seconds: f64,
    segment_files: &[String],
    has_system_audio: bool,
    has_microphone: bool,
) -> Result<LibraryItem, ProjectError> {
    finalize_recording_package_full(
        package,
        id,
        width,
        height,
        duration_seconds,
        segment_files,
        has_system_audio,
        has_microphone,
        false,
        None,
    )
}

pub fn finalize_recording_package_full(
    package: &Path,
    id: &str,
    width: u32,
    height: u32,
    duration_seconds: f64,
    segment_files: &[String],
    has_system_audio: bool,
    has_microphone: bool,
    has_camera: bool,
    source_meta: Option<RecordingSourceMeta>,
) -> Result<LibraryItem, ProjectError> {
    let manifest_path = package.join("manifest.json");
    let created_at = fs::read(&manifest_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<LensManifest>(&bytes).ok())
        .filter(|manifest| manifest.id == id && manifest.kind == "recording")
        .map(|manifest| manifest.created_at)
        .unwrap_or_else(utc_now_iso);
    let mut assets = Vec::new();
    for (index, file) in segment_files.iter().enumerate() {
        let name = format!("raw/segments/{file}");
        if index == 0 {
            assets.push(LensAsset {
                role: "screenVideo".into(),
                relative_path: name.clone(),
            });
        }
        assets.push(LensAsset {
            role: "screenVideoSegment".into(),
            relative_path: name,
        });
    }
    assets.push(LensAsset {
        role: "recordingSegments".into(),
        relative_path: "raw/segments/manifest.json".into(),
    });
    if has_system_audio {
        assets.push(LensAsset {
            role: "systemAudio".into(),
            relative_path: "raw/system-loopback.wav".into(),
        });
    }
    if has_microphone {
        assets.push(LensAsset {
            role: "microphone".into(),
            relative_path: "raw/microphone.wav".into(),
        });
    }
    if has_camera {
        assets.push(LensAsset {
            role: "camera".into(),
            relative_path: "raw/camera.mp4".into(),
        });
    }
    let title = format!(
        "录屏 {}",
        created_at.replace('T', " ").trim_end_matches('Z')
    );
    let capture_source = if let Some(meta) = source_meta {
        RecordingCaptureSource {
            mode: meta.mode,
            display_id: meta.display_id,
            window_id: meta.window_id,
            global_bounds: meta.global_bounds,
            source_rect: meta.source_rect,
            window_title: meta.window_title,
            application_name: meta.application_name,
            frames_per_second: meta.frames_per_second,
            requested_frames_per_second: meta.requested_frames_per_second,
        }
    } else {
        RecordingCaptureSource {
            mode: "display".into(),
            display_id: None,
            window_id: None,
            global_bounds: LensRect {
                x: 0.0,
                y: 0.0,
                width: width as f64,
                height: height as f64,
            },
            source_rect: None,
            window_title: None,
            application_name: None,
            frames_per_second: Some(30),
            requested_frames_per_second: Some(30),
        }
    };
    let manifest = LensManifest {
        schema_version: CURRENT_MANIFEST_VERSION.into(),
        id: id.to_string(),
        kind: "recording".into(),
        created_at: created_at.clone(),
        title: title.clone(),
        state: "ready".into(),
        duration_seconds: Some(duration_seconds),
        dimensions: Some(LensDimensions {
            width: width as i64,
            height: height as i64,
        }),
        capture_source: Some(capture_source),
        screenshot_capture_source: None,
        assets,
    };
    manifest
        .validate()
        .map_err(|err| ProjectError::Manifest(err.to_string()))?;
    write_manifest_preserving_extensions(&manifest_path, &manifest)?;
    let preview = segment_files.first().map(|file| {
        package
            .join("raw/segments")
            .join(file)
            .to_string_lossy()
            .into_owned()
    });
    Ok(LibraryItem {
        id: id.to_string(),
        kind: "recording".into(),
        title,
        state: "ready".into(),
        created_at,
        package_path: package.to_string_lossy().into_owned(),
        preview_path: preview,
        duration_seconds: Some(duration_seconds),
        width: Some(width as i64),
        height: Some(height as i64),
        search_text: String::new(),
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LibraryIndexCache {
    schema_version: u32,
    entries: std::collections::HashMap<String, LibraryCacheEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LibraryCacheEntry {
    fingerprint: String,
    item: LibraryItem,
}

fn file_fingerprint(path: &Path) -> Option<(u64, u128, u64)> {
    use std::hash::Hasher;
    use std::io::Read as _;

    let meta = fs::metadata(path).ok()?;
    let len = meta.len();
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut file = fs::File::open(path).ok()?;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).ok()?;
        if read == 0 {
            break;
        }
        hasher.write(&buffer[..read]);
    }
    Some((len, mtime, hasher.finish()))
}

pub fn compute_package_fingerprint(package: &Path) -> String {
    let tracked = [
        "manifest.json",
        "edits/captions.vtt",
        "analysis/captions.vtt",
        "analysis/ocr.json",
        "analysis/transcript.json",
        "analysis/insights.json",
        "previews/program.mp4",
        "raw/screen.mp4",
    ];
    let mut parts = Vec::with_capacity(tracked.len());
    for rel in tracked {
        let f = package.join(rel);
        if let Some((len, mtime, content_hash)) = file_fingerprint(&f) {
            parts.push(format!("{rel}:{len}:{mtime}:{content_hash:016x}"));
        } else {
            parts.push(format!("{rel}:missing"));
        }
    }
    parts.join(";")
}

pub fn scan_library(root: &Path) -> Result<Vec<LibraryItem>, ProjectError> {
    if !root.exists() {
        return Ok(Vec::new());
    }

    let cache_path = root.join(".lens_library_index.json");
    let mut cache: Option<LibraryIndexCache> = fs::read_to_string(&cache_path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok());
    let mut cache_dirty = cache.is_none();
    let mut entries = cache.take().map(|c| c.entries).unwrap_or_default();

    let mut current_paths = std::collections::HashSet::new();
    let mut items = Vec::new();

    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("lens") && !path.is_dir() {
            continue;
        }
        let manifest_path = if path.is_dir() {
            path.join("manifest.json")
        } else {
            continue;
        };
        if !manifest_path.exists() {
            continue;
        }

        let path_str = path.to_string_lossy().into_owned();
        current_paths.insert(path_str.clone());

        let fingerprint = compute_package_fingerprint(&path);

        if let Some(cached) = entries.get(&path_str) {
            if cached.fingerprint == fingerprint && !fingerprint.is_empty() {
                items.push(cached.item.clone());
                continue;
            }
        }

        // Cache miss or modified: parse manifest and compute search text
        let text = match fs::read_to_string(&manifest_path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let manifest: LensManifest = match serde_json::from_str(&text) {
            Ok(value) => value,
            Err(_) => continue,
        };
        if manifest.validate().is_err() {
            continue;
        }
        let complete_recording = (manifest.kind == "recording")
            .then(|| {
                ["previews/program.mp4", "raw/screen.mp4"]
                    .iter()
                    .map(|relative| path.join(relative))
                    .find(|candidate| candidate.is_file())
                    .map(|candidate| candidate.to_string_lossy().into_owned())
            })
            .flatten();
        let preview = complete_recording.or_else(|| {
            manifest.assets.iter().find_map(|asset| {
                if asset.role == "screenshot"
                    || asset.role == "screenVideo"
                    || asset.role == "annotatedScreenshot"
                {
                    Some(
                        path.join(asset.relative_path.replace('/', "\\"))
                            .to_string_lossy()
                            .into_owned(),
                    )
                } else {
                    None
                }
            })
        });
        let search_text = library_search_blob(&path, &manifest.title);
        let item = LibraryItem {
            id: manifest.id,
            kind: manifest.kind,
            title: manifest.title,
            state: manifest.state,
            created_at: manifest.created_at,
            package_path: path_str.clone(),
            preview_path: preview,
            duration_seconds: manifest.duration_seconds,
            width: manifest.dimensions.as_ref().map(|d| d.width),
            height: manifest.dimensions.as_ref().map(|d| d.height),
            search_text,
        };
        entries.insert(
            path_str,
            LibraryCacheEntry {
                fingerprint,
                item: item.clone(),
            },
        );
        cache_dirty = true;
        items.push(item);
    }

    // Evict deleted packages from index cache
    let before_count = entries.len();
    entries.retain(|k, _| current_paths.contains(k));
    if entries.len() != before_count {
        cache_dirty = true;
    }

    if cache_dirty {
        let new_cache = LibraryIndexCache {
            schema_version: 1,
            entries,
        };
        if let Ok(bytes) = serde_json::to_vec(&new_cache) {
            let _ = write_atomic(&cache_path, bytes);
        }
    }

    items.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(items)
}

pub fn save_annotated_png(package: &Path, png: &[u8]) -> Result<PathBuf, ProjectError> {
    if !png.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(ProjectError::BadImageFormat(
            "数据不是有效的 PNG 图像".into(),
        ));
    }
    let path = package.join("previews/annotated.png");
    write_atomic(&path, png.to_vec())?;
    Ok(path)
}

pub fn export_screenshot(
    package: &Path,
    image_bytes: &[u8],
    format: &str,
    target_path: Option<&Path>,
) -> Result<PathBuf, ProjectError> {
    let lower_format = format.trim().to_ascii_lowercase();
    let ext = match lower_format.as_str() {
        "jpeg" | "jpg" => {
            if !image_bytes.starts_with(&[0xff, 0xd8, 0xff]) {
                return Err(ProjectError::BadImageFormat(
                    "数据不是有效的 JPEG 图像".into(),
                ));
            }
            "jpg"
        }
        "png" => {
            if !image_bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
                return Err(ProjectError::BadImageFormat(
                    "数据不是有效的 PNG 图像".into(),
                ));
            }
            "png"
        }
        other => {
            return Err(ProjectError::BadImageFormat(format!(
                "不支持的导出格式：{other}"
            )));
        }
    };

    let destination = match target_path {
        Some(p) => {
            let mut buf = p.to_path_buf();
            buf.set_extension(ext);
            buf
        }
        None => {
            let title = fs::read_to_string(package.join("manifest.json"))
                .ok()
                .and_then(|text| serde_json::from_str::<LensManifest>(&text).ok())
                .map(|m| m.title)
                .unwrap_or_else(|| "screenshot".into());
            let clean_title: String = title
                .chars()
                .map(|c| {
                    if c.is_alphanumeric() || c == '-' || c == '_' {
                        c
                    } else {
                        '_'
                    }
                })
                .collect();
            let stamp = utc_now_iso().replace([':', '.'], "-");
            let filename = format!("{clean_title}-{stamp}.{ext}");
            package.join("exports").join(filename)
        }
    };

    write_atomic(&destination, image_bytes.to_vec())?;
    Ok(destination)
}

pub fn save_json(
    package: &Path,
    relative: &str,
    value: &impl Serialize,
) -> Result<PathBuf, ProjectError> {
    let path = package.join(relative);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    write_atomic(&path, serde_json::to_vec_pretty(value)?)?;
    Ok(path)
}

/// Save a user-editable JSON sidecar without discarding extension fields written
/// by another Lens version or platform. Values owned by `value` win; unknown
/// object fields are retained recursively. Array entries are paired by a stable
/// identity (or by position as a fallback), while entries removed by the caller
/// are not resurrected.
pub fn save_json_preserving_extensions(
    package: &Path,
    relative: &str,
    value: &impl Serialize,
) -> Result<PathBuf, ProjectError> {
    let path = package.join(relative);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut updated = serde_json::to_value(value)?;
    if let Ok(bytes) = fs::read(&path) {
        if let Ok(existing) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            merge_unknown_json_fields(&existing, &mut updated);
        }
    }
    write_atomic(&path, serde_json::to_vec_pretty(&updated)?)?;
    Ok(path)
}

/// Read-only package inspect. Optional ffprobe durations never rewrite `raw/`.
pub fn inspect_package(path: &Path) -> Result<lens_core::interop::PackageInspect, ProjectError> {
    let mut report = lens_core::interop::inspect_package_readonly(path)?;
    for asset in &mut report.assets {
        match asset.container {
            lens_core::interop::MediaContainer::Caf
            | lens_core::interop::MediaContainer::Mov
            | lens_core::interop::MediaContainer::Mp4
            | lens_core::interop::MediaContainer::Wav => {
                let mut full = path.to_path_buf();
                for part in asset.relative_path.split(['/', '\\']) {
                    if !part.is_empty() {
                        full.push(part);
                    }
                }
                if let Some(duration) = post::ffprobe_duration(&full) {
                    asset.duration_seconds = Some(duration);
                }
            }
            _ => {}
        }
    }
    Ok(report)
}

fn library_search_blob(package: &Path, title: &str) -> String {
    let mut parts = vec![title.to_string()];

    // Manual correction layer: edits/captions.vtt overrides or complements analysis
    if let Ok(text) = fs::read_to_string(package.join("edits/captions.vtt")) {
        parts.push(text);
    } else if let Ok(text) = fs::read_to_string(package.join("analysis/captions.vtt")) {
        parts.push(text);
    }

    if let Ok(text) = fs::read_to_string(package.join("analysis/ocr.json")) {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(ft) = val.get("fullText").and_then(|v| v.as_str()) {
                parts.push(ft.to_string());
            }
        } else {
            parts.push(text);
        }
    }

    if let Ok(text) = fs::read_to_string(package.join("analysis/transcript.json")) {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(ft) = val.get("fullText").and_then(|v| v.as_str()) {
                parts.push(ft.to_string());
            }
        } else {
            parts.push(text);
        }
    }

    if let Ok(text) = fs::read_to_string(package.join("analysis/insights.json")) {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(summary) = val.get("summary").and_then(|v| v.as_str()) {
                parts.push(summary.to_string());
            }
            if let Some(st) = val.get("suggestedTitle").and_then(|v| v.as_str()) {
                parts.push(st.to_string());
            }
            if let Some(tags) = val.get("tags").and_then(|v| v.as_array()) {
                for tag in tags {
                    if let Some(t) = tag.as_str() {
                        parts.push(t.to_string());
                    }
                }
            }
        } else {
            parts.push(text);
        }
    }

    parts.join(" ")
}

pub fn delete_package(library_root: &Path, package: &Path) -> Result<(), ProjectError> {
    let root = library_root
        .canonicalize()
        .map_err(|_| ProjectError::Manifest("library root missing".into()))?;
    let target = package
        .canonicalize()
        .map_err(|_| ProjectError::Manifest("package missing".into()))?;
    if !target.starts_with(&root) {
        return Err(ProjectError::Manifest(
            "refusing to delete outside library".into(),
        ));
    }
    let name = target
        .file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default();
    if !name.ends_with(".lens") {
        return Err(ProjectError::Manifest("not a .lens package".into()));
    }
    fs::remove_dir_all(&target)?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryReport {
    pub schema_version: String,
    pub recovered_at: String,
    pub status: String, // "full", "partial", "failed"
    pub total_segments_found: usize,
    pub valid_segments_used: Vec<String>,
    pub discarded_segments: Vec<String>,
    pub duration_seconds: Option<f64>,
    pub error_message: Option<String>,
    #[serde(default)]
    pub journal_used: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub journal_error: Option<String>,
    #[serde(default)]
    pub segment_results: Vec<RecoverySegmentResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoverySegmentResult {
    pub file: String,
    pub journal_state: Option<String>,
    pub decodable: bool,
    pub error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RecoveryJournal {
    #[serde(default)]
    segments: Vec<RecoveryJournalSegment>,
}

#[derive(Debug, Deserialize)]
struct RecoveryJournalSegment {
    #[serde(default)]
    index: u64,
    file: String,
    #[serde(default)]
    state: String,
}

fn recovery_candidates(
    segment_dir: &Path,
) -> (Vec<(String, Option<String>)>, bool, Option<String>) {
    let journal_path = segment_dir.join("manifest.json");
    if journal_path.is_file() {
        match fs::read_to_string(&journal_path)
            .map_err(|e| e.to_string())
            .and_then(|text| {
                serde_json::from_str::<RecoveryJournal>(&text).map_err(|e| e.to_string())
            }) {
            Ok(mut journal) if !journal.segments.is_empty() => {
                journal.segments.sort_by_key(|entry| entry.index);
                let mut seen = std::collections::HashSet::new();
                let candidates = journal
                    .segments
                    .into_iter()
                    .filter_map(|entry| {
                        let file_name = Path::new(&entry.file).file_name()?.to_str()?.to_string();
                        if file_name != entry.file
                            || !file_name.to_ascii_lowercase().ends_with(".mp4")
                            || !seen.insert(file_name.clone())
                        {
                            return None;
                        }
                        Some((file_name, Some(entry.state)))
                    })
                    .collect();
                return (candidates, true, None);
            }
            Ok(_) => {
                return (
                    Vec::new(),
                    true,
                    Some("segment journal contains no entries".into()),
                )
            }
            Err(error) => {
                // Legacy recordings sometimes contain an empty placeholder journal.
                // Fall back to scanning, but persist the reason in the recovery report.
                let fallback = enumerate_mp4_segments(segment_dir);
                return (
                    fallback,
                    false,
                    Some(format!("segment journal unreadable: {error}")),
                );
            }
        }
    }
    (
        enumerate_mp4_segments(segment_dir),
        false,
        Some("segment journal missing; used legacy directory scan".into()),
    )
}

fn enumerate_mp4_segments(segment_dir: &Path) -> Vec<(String, Option<String>)> {
    let mut files = Vec::new();
    if let Ok(entries) = fs::read_dir(segment_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file()
                && path
                    .extension()
                    .and_then(|value| value.to_str())
                    .map(|value| value.eq_ignore_ascii_case("mp4"))
                    == Some(true)
            {
                if let Some(name) = path.file_name().and_then(|value| value.to_str()) {
                    files.push((name.to_string(), None));
                }
            }
        }
    }
    files.sort_by(|left, right| left.0.cmp(&right.0));
    files
}

fn persist_recovery_failure(
    package: &Path,
    manifest_path: &Path,
    manifest_json: &mut serde_json::Value,
    report: &RecoveryReport,
) -> Result<(), ProjectError> {
    save_json(package, "analysis/recovery-report.json", report)?;
    manifest_json["state"] = serde_json::Value::String("recoveryFailed".into());
    write_atomic(manifest_path, serde_json::to_vec_pretty(manifest_json)?)?;
    Ok(())
}

fn publish_recovery_output(staged: &Path, destination: &Path) -> Result<(), ProjectError> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    if !destination.exists() {
        fs::rename(staged, destination)?;
        return Ok(());
    }
    let backup = destination.with_extension(format!("recovery-backup-{}", new_uuid()));
    fs::rename(destination, &backup)?;
    match fs::rename(staged, destination) {
        Ok(()) => {
            let _ = fs::remove_file(backup);
            Ok(())
        }
        Err(error) => {
            let _ = fs::rename(&backup, destination);
            Err(error.into())
        }
    }
}

fn open_recovery_lock(path: &Path) -> io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // An unshared handle prevents concurrent recovery. If a process crashed,
        // the kernel released its handle and the existing marker is reusable.
        options.share_mode(0);
    }
    #[cfg(not(windows))]
    options.create_new(true);
    options.open(path)
}

pub struct RecordingActivityGuard {
    file: Option<fs::File>,
    path: PathBuf,
}

impl Drop for RecordingActivityGuard {
    fn drop(&mut self) {
        drop(self.file.take());
        let _ = fs::remove_file(&self.path);
    }
}

/// Holds an OS-level unshared handle for the whole live capture. Recovery opens
/// the same marker unshared, so it cannot touch a package that is still recording;
/// a marker left by a crashed process is harmless because its kernel handle is gone.
pub fn create_recording_activity_guard(
    package: &Path,
) -> Result<RecordingActivityGuard, ProjectError> {
    let path = package.join("raw/segments/recording.active");
    let file = open_recovery_lock(&path)?;
    Ok(RecordingActivityGuard {
        file: Some(file),
        path,
    })
}

pub fn recover_recording_package(package: &Path) -> Result<RecoveryReport, ProjectError> {
    let manifest_path = package.join("manifest.json");
    if !manifest_path.is_file() {
        return Err(ProjectError::Manifest("manifest.json missing".into()));
    }
    let text = fs::read_to_string(&manifest_path)?;
    let mut manifest_json: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| ProjectError::Manifest(format!("invalid manifest: {e}")))?;
    let manifest: LensManifest = serde_json::from_value(manifest_json.clone())
        .map_err(|e| ProjectError::Manifest(format!("invalid manifest: {e}")))?;

    if manifest.kind != "recording"
        || !matches!(
            manifest.state.as_str(),
            "capturing" | "recoveryFailed" | "recoveredPartial"
        )
    {
        return Err(ProjectError::Manifest(
            "package is not recoverable or has already been fully recovered".into(),
        ));
    }

    // Prevent two startup/manual recovery attempts from publishing over each other.
    let lock_path = package.join("analysis/recovery.lock");
    fs::create_dir_all(package.join("analysis"))?;
    let _recovery_lock = open_recovery_lock(&lock_path)
        .map_err(|_| ProjectError::Manifest("recording recovery is already in progress".into()))?;
    struct RecoveryLock(PathBuf);
    impl Drop for RecoveryLock {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }
    let _lock_guard = RecoveryLock(lock_path);

    let segment_dir = package.join("raw").join("segments");
    let activity_path = segment_dir.join("recording.active");
    let _activity_probe = if activity_path.exists() {
        Some(open_recovery_lock(&activity_path).map_err(|_| {
            ProjectError::Manifest("recording is still active; recovery was skipped".into())
        })?)
    } else {
        None
    };
    let (candidates, journal_used, journal_error) = recovery_candidates(&segment_dir);
    let candidate_files: Vec<String> = candidates.iter().map(|entry| entry.0.clone()).collect();

    let mut valid_segments = Vec::new();
    let mut discarded_segments = Vec::new();
    let mut segment_results = Vec::new();

    for (file, journal_state) in &candidates {
        let seg_path = segment_dir.join(file);
        let decode_result = post::verify_video_decodable(&seg_path);
        if decode_result.is_ok() {
            valid_segments.push(file.clone());
        } else {
            discarded_segments.push(file.clone());
        }
        segment_results.push(RecoverySegmentResult {
            file: file.clone(),
            journal_state: journal_state.clone(),
            decodable: decode_result.is_ok(),
            error: decode_result.err().map(|error| error.to_string()),
        });
    }

    let report_dir = package.join("analysis");
    let _ = fs::create_dir_all(&report_dir);

    if valid_segments.is_empty() {
        let report = RecoveryReport {
            schema_version: "1.0".into(),
            recovered_at: utc_now_iso(),
            status: "failed".into(),
            total_segments_found: candidate_files.len(),
            valid_segments_used: Vec::new(),
            discarded_segments,
            duration_seconds: None,
            error_message: Some("no decodable video segments found".into()),
            journal_used,
            journal_error,
            segment_results,
        };
        persist_recovery_failure(package, &manifest_path, &mut manifest_json, &report)?;
        return Ok(report);
    }

    let work_dir = package
        .join("previews")
        .join(format!("recovery-{}", new_uuid()));
    fs::create_dir_all(&work_dir)?;
    struct RecoveryWork(PathBuf);
    impl Drop for RecoveryWork {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _work_guard = RecoveryWork(work_dir.clone());
    let recovered_video = work_dir.join("screen.mp4");
    if let Err(e) = post::concat_segments(&segment_dir, &valid_segments, &recovered_video) {
        let report = RecoveryReport {
            schema_version: "1.0".into(),
            recovered_at: utc_now_iso(),
            status: "failed".into(),
            total_segments_found: candidate_files.len(),
            valid_segments_used: valid_segments,
            discarded_segments,
            duration_seconds: None,
            error_message: Some(format!("segment concatenation failed: {e}")),
            journal_used,
            journal_error,
            segment_results,
        };
        persist_recovery_failure(package, &manifest_path, &mut manifest_json, &report)?;
        return Ok(report);
    }

    let system = package.join("raw/system-loopback.wav");
    let mic = package.join("raw/microphone.wav");
    let camera = package.join("raw/camera.mp4");
    let staged_program = work_dir.join("program.mp4");
    let program = package.join("previews/program.mp4");

    if let Err(e) = post::mix_audio_and_pip(
        &recovered_video,
        system.is_file().then_some(system.as_path()),
        mic.is_file().then_some(mic.as_path()),
        camera.is_file().then_some(camera.as_path()),
        None,
        &staged_program,
    ) {
        let report = RecoveryReport {
            schema_version: "1.0".into(),
            recovered_at: utc_now_iso(),
            status: "failed".into(),
            total_segments_found: candidate_files.len(),
            valid_segments_used: valid_segments,
            discarded_segments,
            duration_seconds: None,
            error_message: Some(format!("media audio/pip synthesis failed: {e}")),
            journal_used,
            journal_error,
            segment_results,
        };
        persist_recovery_failure(package, &manifest_path, &mut manifest_json, &report)?;
        return Ok(report);
    }

    let verified_duration = match post::verify_video_decodable(&staged_program).and_then(|_| {
        post::ffprobe_duration(&staged_program)
            .ok_or_else(|| ProjectError::Manifest("cannot probe synthesized video".into()))
    }) {
        Ok(d) if d > 0.0 => d,
        result => {
            let report = RecoveryReport {
                schema_version: "1.0".into(),
                recovered_at: utc_now_iso(),
                status: "failed".into(),
                total_segments_found: candidate_files.len(),
                valid_segments_used: valid_segments,
                discarded_segments,
                duration_seconds: None,
                error_message: Some(format!(
                    "synthesized video validation failed: {}",
                    result
                        .err()
                        .map(|e| e.to_string())
                        .unwrap_or_else(|| "zero duration".into())
                )),
                journal_used,
                journal_error,
                segment_results,
            };
            persist_recovery_failure(package, &manifest_path, &mut manifest_json, &report)?;
            return Ok(report);
        }
    };

    if let Err(error) = publish_recovery_output(&staged_program, &program) {
        let report = RecoveryReport {
            schema_version: "1.0".into(),
            recovered_at: utc_now_iso(),
            status: "failed".into(),
            total_segments_found: candidate_files.len(),
            valid_segments_used: valid_segments,
            discarded_segments,
            duration_seconds: None,
            error_message: Some(format!("cannot publish verified recovery output: {error}")),
            journal_used,
            journal_error,
            segment_results,
        };
        persist_recovery_failure(package, &manifest_path, &mut manifest_json, &report)?;
        return Ok(report);
    }

    let status = if discarded_segments.is_empty() {
        "full".to_string()
    } else {
        "partial".to_string()
    };

    manifest_json["durationSeconds"] = serde_json::json!(verified_duration);
    manifest_json["state"] = serde_json::Value::String(
        if status == "full" {
            "ready"
        } else {
            "recoveredPartial"
        }
        .into(),
    );
    manifest_json["title"] = serde_json::Value::String(format!(
        "已恢复录屏 {}",
        manifest.created_at.replace('T', " ").trim_end_matches('Z')
    ));

    // Keep original JSON objects for unrelated assets so extension fields from
    // macOS/future schemas are not erased by a typed deserialize/serialize pass.
    let mut assets = manifest_json["assets"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assets.retain(|asset| {
        !matches!(
            asset.get("role").and_then(|value| value.as_str()),
            Some(
                "screenVideo"
                    | "screenVideoSegment"
                    | "recordingSegments"
                    | "systemAudio"
                    | "microphone"
                    | "camera"
            )
        )
    });

    for (index, file) in valid_segments.iter().enumerate() {
        let name = format!("raw/segments/{file}");
        if index == 0 {
            assets.push(serde_json::json!({ "role": "screenVideo", "relativePath": name.clone() }));
        }
        assets.push(serde_json::json!({ "role": "screenVideoSegment", "relativePath": name }));
    }
    assets.push(serde_json::json!({ "role": "recordingSegments", "relativePath": "raw/segments/manifest.json" }));
    if system.is_file() {
        assets.push(
            serde_json::json!({ "role": "systemAudio", "relativePath": "raw/system-loopback.wav" }),
        );
    }
    if mic.is_file() {
        assets.push(
            serde_json::json!({ "role": "microphone", "relativePath": "raw/microphone.wav" }),
        );
    }
    if camera.is_file() {
        assets.push(serde_json::json!({ "role": "camera", "relativePath": "raw/camera.mp4" }));
    }

    manifest_json["assets"] = serde_json::Value::Array(assets);
    write_atomic(&manifest_path, serde_json::to_vec_pretty(&manifest_json)?)?;

    let report = RecoveryReport {
        schema_version: "1.0".into(),
        recovered_at: utc_now_iso(),
        status,
        total_segments_found: candidate_files.len(),
        valid_segments_used: valid_segments,
        discarded_segments,
        duration_seconds: Some(verified_duration),
        error_message: None,
        journal_used,
        journal_error,
        segment_results,
    };
    save_json(package, "analysis/recovery-report.json", &report)?;

    Ok(report)
}

pub fn recover_incomplete_recordings(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let manifest_path = path.join("manifest.json");
        if !manifest_path.is_file() {
            continue;
        }
        let Ok(text) = fs::read_to_string(&manifest_path) else {
            continue;
        };
        let Ok(manifest): Result<LensManifest, _> = serde_json::from_str(&text) else {
            continue;
        };
        if manifest.kind == "recording"
            && matches!(
                manifest.state.as_str(),
                "capturing" | "recoveryFailed" | "recoveredPartial"
            )
        {
            let _ = recover_recording_package(&path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lens_core::manifest::LensRect;

    #[test]
    fn screenshot_package_writes_manifest_and_png() {
        let root = std::env::temp_dir().join(format!("lens-test-{}", new_uuid()));
        let png = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0];
        let item = save_screenshot_package(
            &root,
            &png,
            20,
            10,
            LensRect {
                x: 1.0,
                y: 2.0,
                width: 20.0,
                height: 10.0,
            },
            "region",
        )
        .unwrap();
        let manifest_path = PathBuf::from(&item.package_path).join("manifest.json");
        let text = fs::read_to_string(manifest_path).unwrap();
        let manifest: LensManifest = serde_json::from_str(&text).unwrap();
        assert_eq!(manifest.schema_version, "0.9");
        assert_eq!(manifest.kind, "screenshot");
        assert!(PathBuf::from(item.preview_path.unwrap()).exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn future_schema_is_skipped_by_library_scan() {
        let root = std::env::temp_dir().join(format!("lens-scan-{}", new_uuid()));
        fs::create_dir_all(root.join("future.lens")).unwrap();
        fs::write(
            root.join("future.lens/manifest.json"),
            r#"{"schemaVersion":"9.9","id":"x","kind":"screenshot","createdAt":"t","title":"t","state":"ready","assets":[]}"#,
        )
        .unwrap();
        let items = scan_library(&root).unwrap();
        assert!(items.is_empty());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn inspect_mac_sidecars_does_not_rewrite_raw() {
        let root = std::env::temp_dir().join(format!("lens-mac-{}", new_uuid()));
        fs::create_dir_all(root.join("raw")).unwrap();
        fs::write(
            root.join("manifest.json"),
            r#"{"schemaVersion":"0.9","id":"mac","kind":"recording","createdAt":"t","title":"Mac","state":"ready","assets":[]}"#,
        )
        .unwrap();
        let mut caf = b"caff".to_vec();
        caf.extend_from_slice(&[0, 0, 0, 1, 9, 8, 7, 6]);
        fs::write(root.join("raw/microphone.caf"), &caf).unwrap();
        let mut mov = vec![0, 0, 0, 24];
        mov.extend_from_slice(b"ftypqt  ");
        mov.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        fs::write(root.join("raw/source.mov"), &mov).unwrap();
        let before_caf = fs::read(root.join("raw/microphone.caf")).unwrap();
        let before_mov = fs::read(root.join("raw/source.mov")).unwrap();
        let report = inspect_package(&root).unwrap();
        assert_eq!(report.schema_version, "0.9");
        assert!(report
            .assets
            .iter()
            .any(|asset| asset.container == lens_core::interop::MediaContainer::Caf));
        assert_eq!(
            fs::read(root.join("raw/microphone.caf")).unwrap(),
            before_caf
        );
        assert_eq!(fs::read(root.join("raw/source.mov")).unwrap(), before_mov);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn save_annotated_png_rejects_non_png() {
        let root = std::env::temp_dir().join(format!("lens-test-png-{}", new_uuid()));
        fs::create_dir_all(&root).unwrap();
        // JPEG magic header instead of PNG
        let fake_jpeg = vec![0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10];
        let err = save_annotated_png(&root, &fake_jpeg).unwrap_err();
        match err {
            ProjectError::BadImageFormat(msg) => assert!(msg.contains("PNG")),
            other => panic!("expected BadImageFormat, got {other:?}"),
        }
        // Valid PNG header
        let mut valid_png = b"\x89PNG\r\n\x1a\n".to_vec();
        valid_png.extend_from_slice(&[0, 0, 0, 13]);
        let path = save_annotated_png(&root, &valid_png).unwrap();
        assert!(path.exists());
        assert_eq!(path.file_name().unwrap(), "annotated.png");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn export_screenshot_enforces_extension_and_format_matching() {
        let root = std::env::temp_dir().join(format!("lens-test-export-{}", new_uuid()));
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("manifest.json"),
            r#"{"schemaVersion":"0.9","id":"shot","kind":"screenshot","createdAt":"2026-09-10T12:00:00Z","title":"我的截图","state":"ready","assets":[]}"#,
        ).unwrap();

        let valid_png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR".to_vec();
        let valid_jpeg = vec![0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46];

        // PNG export
        let png_exported = export_screenshot(&root, &valid_png, "png", None).unwrap();
        assert!(png_exported.exists());
        assert_eq!(png_exported.extension().unwrap(), "png");

        // JPEG export
        let jpeg_exported = export_screenshot(&root, &valid_jpeg, "jpeg", None).unwrap();
        assert!(jpeg_exported.exists());
        assert_eq!(jpeg_exported.extension().unwrap(), "jpg");

        // Format mismatch rejects
        assert!(export_screenshot(&root, &valid_png, "jpeg", None).is_err());
        assert!(export_screenshot(&root, &valid_jpeg, "png", None).is_err());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn editable_json_save_preserves_extensions_without_resurrecting_removed_items() {
        let root = std::env::temp_dir().join(format!("lens-json-extensions-{}", new_uuid()));
        fs::create_dir_all(root.join("edits")).unwrap();
        fs::write(
            root.join("edits/timeline.json"),
            r#"{
              "schemaVersion":"0.9",
              "title":"old",
              "macExtension":{"mode":"cinematic"},
              "settings":{"volume":0.5,"vendorCurve":"smooth"},
              "segments":[
                {"id":"keep","startSeconds":0.0,"label":"old","vendorColor":"red"},
                {"id":"remove","startSeconds":5.0,"label":"deleted","vendorColor":"blue"}
              ]
            }"#,
        )
        .unwrap();

        let updated = serde_json::json!({
            "schemaVersion": "0.9",
            "title": "new",
            "settings": {"volume": 0.8},
            "segments": [
                {"id":"keep","startSeconds":1.0,"label":"updated"}
            ]
        });
        save_json_preserving_extensions(&root, "edits/timeline.json", &updated).unwrap();

        let saved: serde_json::Value =
            serde_json::from_slice(&fs::read(root.join("edits/timeline.json")).unwrap()).unwrap();
        assert_eq!(saved["title"], "new");
        assert_eq!(saved["settings"]["volume"], 0.8);
        assert_eq!(saved["settings"]["vendorCurve"], "smooth");
        assert_eq!(saved["macExtension"]["mode"], "cinematic");
        assert_eq!(saved["segments"].as_array().unwrap().len(), 1);
        assert_eq!(saved["segments"][0]["startSeconds"], 1.0);
        assert_eq!(saved["segments"][0]["vendorColor"], "red");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn library_incremental_index_rebuild_and_manual_correction_overlay() {
        let root = std::env::temp_dir().join(format!("lens-test-lib-{}", new_uuid()));
        fs::create_dir_all(&root).unwrap();

        let pkg1 = root.join("pkg1.lens");
        fs::create_dir_all(pkg1.join("analysis")).unwrap();
        fs::write(
            pkg1.join("manifest.json"),
            r#"{"schemaVersion":"0.9","id":"pkg1","kind":"recording","createdAt":"2026-09-10T12:00:00Z","title":"初始项目录制","state":"ready","assets":[]}"#,
        ).unwrap();
        fs::write(
            pkg1.join("analysis/captions.vtt"),
            "WEBVTT\n\n00:00.000 --> 00:02.000\n机器转写字幕\n",
        )
        .unwrap();

        // 1. Initial scan builds persistent index cache
        let items1 = scan_library(&root).unwrap();
        assert_eq!(items1.len(), 1);
        assert!(items1[0].search_text.contains("机器转写字幕"));
        let cache_file = root.join(".lens_library_index.json");
        assert!(cache_file.exists());

        // 2. Immediate sub-second manual correction overlay (edits/captions.vtt) without sleeping
        fs::create_dir_all(pkg1.join("edits")).unwrap();
        fs::write(
            pkg1.join("edits/captions.vtt"),
            "WEBVTT\n\n00:00.000 --> 00:02.000\n人工校正精确字幕\n",
        )
        .unwrap();

        let items2 = scan_library(&root).unwrap();
        assert_eq!(items2.len(), 1);
        assert!(items2[0].search_text.contains("人工校正精确字幕"));

        // 3. Background OCR completed and written
        fs::write(
            pkg1.join("analysis/ocr.json"),
            r#"{"fullText":"屏幕OCR关键内容"}"#,
        )
        .unwrap();
        let items_ocr = scan_library(&root).unwrap();
        assert_eq!(items_ocr.len(), 1);
        assert!(items_ocr[0].search_text.contains("屏幕OCR关键内容"));

        // Same-length, immediate overwrite must invalidate even on filesystems
        // whose timestamp resolution/coalescing would otherwise hide the edit.
        fs::write(
            pkg1.join("analysis/ocr.json"),
            r#"{"fullText":"same-size-A"}"#,
        )
        .unwrap();
        let same_size_a = scan_library(&root).unwrap();
        assert!(same_size_a[0].search_text.contains("same-size-A"));
        fs::write(
            pkg1.join("analysis/ocr.json"),
            r#"{"fullText":"same-size-B"}"#,
        )
        .unwrap();
        let same_size_b = scan_library(&root).unwrap();
        assert!(same_size_b[0].search_text.contains("same-size-B"));
        assert!(!same_size_b[0].search_text.contains("same-size-A"));

        // 4. Background Insights summary generated
        fs::write(
            pkg1.join("analysis/insights.json"),
            r#"{"summary":"AI提炼的核心会议结论","suggestedTitle":"Lens技术周报"}"#,
        )
        .unwrap();
        let items_insights = scan_library(&root).unwrap();
        assert_eq!(items_insights.len(), 1);
        assert!(items_insights[0]
            .search_text
            .contains("AI提炼的核心会议结论"));
        assert!(items_insights[0].search_text.contains("Lens技术周报"));

        // 5. Corrupt the index cache file and verify auto-rebuild
        fs::write(&cache_file, "INVALID_CORRUPTED_JSON_DATA{{{{").unwrap();
        let items3 = scan_library(&root).unwrap();
        assert_eq!(items3.len(), 1);
        assert!(items3[0].search_text.contains("人工校正精确字幕"));
        assert!(items3[0].search_text.contains("AI提炼的核心会议结论"));
        // The index file should now be repaired and contain valid JSON
        let repaired_text = fs::read_to_string(&cache_file).unwrap();
        let _parsed: serde_json::Value =
            serde_json::from_str(&repaired_text).expect("repaired index is valid JSON");

        let _ = fs::remove_dir_all(root);
    }
}
