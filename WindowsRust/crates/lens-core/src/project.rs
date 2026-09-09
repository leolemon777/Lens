use crate::{Asset, Manifest, SegmentIndex};
use chrono::{SecondsFormat, Utc};
use std::{fs, io::{Read, Write}, path::{Component, Path, PathBuf}};
use uuid::Uuid;

pub const MAX_JSON_BYTES: u64 = 1_048_576;

pub fn check_version(version: &str) -> Result<(), String> {
    let Some((major, minor)) = version.split_once('.') else { return Err("无效项目版本".into()); };
    let major: u32 = major.parse().map_err(|_| "无效项目版本")?;
    let minor: u32 = minor.parse().map_err(|_| "无效项目版本")?;
    if major != 0 || !(1..=9).contains(&minor) { return Err(format!("不支持项目版本 {version}；不修改原文件")); }
    Ok(())
}

pub fn safe_relative(path: &str) -> Result<(), String> {
    if path.is_empty() || path.contains('\\') || path.contains(':') || path.contains('\0') {
        return Err("不安全的项目相对路径".into());
    }
    if Path::new(path).components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err("项目路径不能是绝对路径或包含 ..".into());
    }
    Ok(())
}

pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, String> {
    let mut file = fs::File::open(path).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > MAX_JSON_BYTES { return Err("项目 JSON 超过 1 MiB 上限".into()); }
    let mut bytes = Vec::new();
    (&mut file).take(MAX_JSON_BYTES + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_JSON_BYTES { return Err("项目 JSON 超过上限".into()); }
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

/// Tempfile is created on the same volume. Never delete the old manifest before replacement.
pub fn atomic_json<T: serde::Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let parent = path.parent().ok_or("文件没有父目录")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let bytes = serde_json::to_vec_pretty(value).map_err(|e|e.to_string())?;
    if bytes.len() as u64 + 1 > MAX_JSON_BYTES { return Err("项目 JSON 超过 1 MiB 写入上限；保留原文件".into()); }
    let mut tmp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    tmp.write_all(&bytes).map_err(|e|e.to_string())?;
    tmp.write_all(b"\n").map_err(|e| e.to_string())?;
    tmp.as_file().sync_all().map_err(|e| e.to_string())?;
    tmp.persist(path).map_err(|e| e.to_string())?;
    Ok(())
}

pub struct Project { pub path: PathBuf, pub manifest: Manifest, pub segments: SegmentIndex }
impl Project {
    pub fn create(root: &Path, kind: &str, title: &str) -> Result<Self, String> {
        if !["recording", "screenshot"].contains(&kind) { return Err("未知项目类型".into()); }
        fs::create_dir_all(root).map_err(|e| e.to_string())?;
        let id = Uuid::new_v4().to_string().to_uppercase();
        // User title never becomes a path component.
        let path = root.join(format!("{}_{}.lens", Utc::now().format("%Y%m%d_%H%M%S"), &id[..8]));
        fs::create_dir(&path).map_err(|e| e.to_string())?;
        for dir in ["raw/segments", "events", "edits", "analysis", "previews", "diagnostics"] {
            fs::create_dir_all(path.join(dir)).map_err(|e| e.to_string())?;
        }
        let result = Self { path, manifest: Manifest {
            schema_version: "0.9".into(), id, kind: kind.into(),
            created_at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
            title: if title.trim().is_empty(){"未命名录制".into()}else{title.trim().into()},
            state: "capturing".into(), duration_seconds: None, dimensions: None,
            assets: vec![], extra: Default::default(),
        }, segments: SegmentIndex::default() };
        result.save()?; Ok(result)
    }
    pub fn load(path: &Path) -> Result<Self, String> {
        let manifest: Manifest = read_json(&path.join("manifest.json"))?;
        check_version(&manifest.schema_version)?;
        for asset in &manifest.assets { safe_relative(&asset.relative_path)?; }
        let index_path = path.join("events/segments.json");
        let segments: SegmentIndex = if index_path.exists(){read_json(&index_path)?}else{SegmentIndex::default()};
        if segments.schema_version != "0.1" { return Err("不支持的分段版本".into()); }
        let mut seen = std::collections::HashSet::new();
        for s in &segments.segments {
            safe_relative(&s.screen_relative_path)?;
            if let Some(microphone) = &s.microphone_relative_path { safe_relative(microphone)?; }
            if !seen.insert(s.index) || !s.timeline_start_seconds.is_finite() || s.timeline_start_seconds < 0.0
                || s.duration_seconds.is_some_and(|d| !d.is_finite() || d < 0.0) {
                return Err("分段索引重复或时码无效".into());
            }
        }
        Ok(Self { path: path.to_path_buf(), manifest, segments })
    }
    pub fn add_asset(&mut self, role: &str, relative: &str) -> Result<(), String> {
        safe_relative(relative)?;
        if !self.manifest.assets.iter().any(|a| a.role == role && a.relative_path == relative) {
            self.manifest.assets.push(Asset::new(role, relative));
        }
        Ok(())
    }
    pub fn save(&self) -> Result<(), String> {
        atomic_json(&self.path.join("events/segments.json"), &self.segments)?;
        atomic_json(&self.path.join("manifest.json"), &self.manifest)
    }
    pub fn resolve_existing(&self, relative: &str) -> Result<PathBuf, String> {
        safe_relative(relative)?;
        let root = self.path.canonicalize().map_err(|e| e.to_string())?;
        let actual = root.join(relative).canonicalize().map_err(|e| e.to_string())?;
        if !actual.starts_with(&root) { return Err("项目中的链接指向了项目目录之外".into()); }
        Ok(actual)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn refuses_future_versions() { for v in ["1.0","0.10","0.0","wrong"]{assert!(check_version(v).is_err());} }
    #[test] fn accepts_known_versions() { assert!(check_version("0.9").is_ok()); assert!(check_version("0.8").is_ok()); }
    #[test] fn blocks_traversal_and_drives() { for p in ["../x","/tmp/x","C:/x","a\\b","a/../../x"]{assert!(safe_relative(p).is_err(),"{p}");} }
    #[test] fn ordinary_paths_work(){ assert!(safe_relative("raw/segments/0000/screen.mp4").is_ok()); }
    #[test] fn atomic_replacement_roundtrip(){
        let d=tempfile::tempdir().unwrap(); let mut p=Project::create(d.path(),"recording","../../not-a-path").unwrap();
        p.manifest.state="ready".into();p.save().unwrap();
        assert_eq!(Project::load(&p.path).unwrap().manifest.state,"ready");
        assert!(p.path.starts_with(d.path()));
    }
    #[test] fn preserves_unknown_manifest_fields(){
        let d=tempfile::tempdir().unwrap(); let mut p=Project::create(d.path(),"recording","test").unwrap();
        p.manifest.extra.insert("captureSource".into(),serde_json::json!({"mode":"display"}));p.save().unwrap();
        assert_eq!(Project::load(&p.path).unwrap().manifest.extra["captureSource"]["mode"],"display");
    }
}
