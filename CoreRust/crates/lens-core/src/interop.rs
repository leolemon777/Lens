//! Read-only inspection of `.lens` packages, including Mac CAF/MOV sidecars.
//!
//! Inspection never writes, migrates, or rewrites files. Windows can open a Mac
//! package, report which media containers are present, and leave `raw/` intact.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::schema;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MediaContainer {
    Caf,
    Mov,
    Mp4,
    Wav,
    Png,
    Jpeg,
    Json,
    Vtt,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetInspect {
    pub relative_path: String,
    pub container: MediaContainer,
    pub readable: bool,
    pub note: String,
    pub byte_len: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageInspect {
    pub schema_version: String,
    pub kind: String,
    pub title: String,
    pub writable: bool,
    pub assets: Vec<AssetInspect>,
}

/// Sniffs a file header. Does not decode media.
pub fn sniff_container(bytes: &[u8], hint: &str) -> MediaContainer {
    if bytes.len() >= 4 && &bytes[0..4] == b"caff" {
        return MediaContainer::Caf;
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE" {
        return MediaContainer::Wav;
    }
    if bytes.len() >= 8 && &bytes[4..8] == b"ftyp" {
        let brand = if bytes.len() >= 12 {
            &bytes[8..12]
        } else {
            &[]
        };
        if brand == b"qt  " || hint.ends_with(".mov") {
            return MediaContainer::Mov;
        }
        return MediaContainer::Mp4;
    }
    if bytes.len() >= 8 && bytes[0..8] == [137, 80, 78, 71, 13, 10, 26, 10] {
        return MediaContainer::Png;
    }
    if bytes.len() >= 3 && bytes[0..3] == [0xFF, 0xD8, 0xFF] {
        return MediaContainer::Jpeg;
    }
    if hint.ends_with(".json") {
        return MediaContainer::Json;
    }
    if hint.ends_with(".vtt") {
        return MediaContainer::Vtt;
    }
    if hint.ends_with(".caf") {
        return MediaContainer::Caf;
    }
    if hint.ends_with(".mov") {
        return MediaContainer::Mov;
    }
    MediaContainer::Unknown
}

pub fn container_is_readable(kind: MediaContainer, bytes: &[u8]) -> (bool, String) {
    match kind {
        MediaContainer::Caf => {
            let ok = bytes.len() >= 8 && &bytes[0..4] == b"caff";
            (
                ok,
                if ok {
                    "Mac Core Audio Format; Windows reads without rewriting raw/".into()
                } else {
                    "CAF magic missing".into()
                },
            )
        }
        MediaContainer::Mov | MediaContainer::Mp4 => {
            let ok = bytes.len() >= 8 && &bytes[4..8] == b"ftyp";
            (
                ok,
                if ok {
                    "QuickTime/MP4 ftyp present; decode via ffmpeg, do not rewrite raw/".into()
                } else {
                    "missing ftyp box".into()
                },
            )
        }
        MediaContainer::Wav => (bytes.len() >= 44, "PCM WAV".into()),
        MediaContainer::Png => (bytes.len() >= 8, "PNG".into()),
        MediaContainer::Jpeg => (bytes.len() >= 3, "JPEG".into()),
        MediaContainer::Json => (serde_json::from_slice::<serde_json::Value>(bytes).is_ok(), "JSON".into()),
        MediaContainer::Vtt => (bytes.starts_with(b"WEBVTT"), "WebVTT".into()),
        MediaContainer::Unknown => (false, "unrecognized sidecar".into()),
    }
}

/// Walks a package tree and reports assets. Never creates, truncates, or rewrites files.
pub fn inspect_package_readonly(root: &Path) -> io::Result<PackageInspect> {
    let manifest_path = root.join("manifest.json");
    let manifest_text = fs::read_to_string(&manifest_path)?;
    let manifest: serde_json::Value = serde_json::from_str(&manifest_text)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    let schema_version = manifest
        .get("schemaVersion")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    let kind = manifest
        .get("kind")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    let title = manifest
        .get("title")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string();
    let writable = schema::manifest().validate(&schema_version).is_ok();
    let mut assets = Vec::new();
    collect_assets(root, root, &mut assets)?;
    Ok(PackageInspect {
        schema_version,
        kind,
        title,
        writable,
        assets,
    })
}

fn collect_assets(root: &Path, dir: &Path, out: &mut Vec<AssetInspect>) -> io::Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err),
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_assets(root, &path, out)?;
            continue;
        }
        let relative = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let bytes = fs::read(&path)?;
        let container = sniff_container(&bytes, &relative);
        let (readable, note) = container_is_readable(container, &bytes);
        out.push(AssetInspect {
            relative_path: relative,
            container,
            readable,
            note,
            byte_len: bytes.len() as u64,
            duration_seconds: None,
        });
    }
    Ok(())
}

pub fn file_fingerprint(path: &Path) -> io::Result<(u64, PathBuf)> {
    let meta = fs::metadata(path)?;
    Ok((meta.len(), path.to_path_buf()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_caf_and_quicktime_headers() {
        let mut caf = b"caff".to_vec();
        caf.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 0]);
        assert_eq!(sniff_container(&caf, "raw/microphone.caf"), MediaContainer::Caf);
        let mut mov = vec![0, 0, 0, 20];
        mov.extend_from_slice(b"ftypqt  ");
        mov.extend_from_slice(&[0, 0, 0, 0]);
        assert_eq!(sniff_container(&mov, "raw/source.mov"), MediaContainer::Mov);
        let mut mp4 = vec![0, 0, 0, 20];
        mp4.extend_from_slice(b"ftypisom");
        mp4.extend_from_slice(&[0, 0, 0, 0]);
        assert_eq!(sniff_container(&mp4, "raw/screen.mp4"), MediaContainer::Mp4);
    }

    #[test]
    fn inspect_does_not_rewrite_mac_sidecars() {
        let root = std::env::temp_dir().join(format!(
            "lens-interop-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("raw")).unwrap();
        fs::write(
            root.join("manifest.json"),
            r#"{"schemaVersion":"0.9","id":"mac-pkg","kind":"recording","createdAt":"t","title":"Mac take","state":"ready","assets":[]}"#,
        )
        .unwrap();
        let mut caf = b"caff".to_vec();
        caf.extend_from_slice(&[0, 0, 0, 1, 1, 2, 3, 4]);
        fs::write(root.join("raw/microphone.caf"), &caf).unwrap();
        let mut mov = vec![0, 0, 0, 24];
        mov.extend_from_slice(b"ftypqt  ");
        mov.extend_from_slice(&[0, 0, 0, 0, 9, 8, 7, 6]);
        fs::write(root.join("raw/source.mov"), &mov).unwrap();
        let caf_before = fs::read(root.join("raw/microphone.caf")).unwrap();
        let mov_before = fs::read(root.join("raw/source.mov")).unwrap();
        let report = inspect_package_readonly(&root).unwrap();
        assert_eq!(report.schema_version, "0.9");
        assert!(report.writable);
        assert!(report
            .assets
            .iter()
            .any(|asset| asset.container == MediaContainer::Caf && asset.readable));
        assert!(report
            .assets
            .iter()
            .any(|asset| asset.container == MediaContainer::Mov && asset.readable));
        assert_eq!(fs::read(root.join("raw/microphone.caf")).unwrap(), caf_before);
        assert_eq!(fs::read(root.join("raw/source.mov")).unwrap(), mov_before);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn future_schema_is_readable_as_inspect_but_not_writable() {
        let root = std::env::temp_dir().join(format!(
            "lens-future-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("manifest.json"),
            r#"{"schemaVersion":"9.9","id":"x","kind":"screenshot","createdAt":"t","title":"t","state":"ready","assets":[]}"#,
        )
        .unwrap();
        let report = inspect_package_readonly(&root).unwrap();
        assert!(!report.writable);
        let _ = fs::remove_dir_all(root);
    }
}
