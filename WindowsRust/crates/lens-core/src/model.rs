use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase { Idle, Starting, Recording, Pausing, Paused, Stopping, Processing }
impl Phase {
    pub fn may_start(self) -> bool { self == Self::Idle }
    pub fn may_pause(self) -> bool { self == Self::Recording }
    pub fn may_resume(self) -> bool { self == Self::Paused }
    pub fn may_stop(self) -> bool { matches!(self, Self::Recording | Self::Paused) }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Crop { pub x: u32, pub y: u32, pub width: u32, pub height: u32 }
impl Crop {
    /// Reject out-of-bounds rectangles; never silently include unselected pixels.
    pub fn validate(self, width: u32, height: u32) -> Result<Self, String> {
        if self.width < 2 || self.height < 2 { return Err("选区至少为 2 × 2 像素".into()); }
        if self.x.checked_add(self.width).filter(|x| *x <= width).is_none()
            || self.y.checked_add(self.height).filter(|y| *y <= height).is_none() {
            return Err("选区超出捕获来源边界；请重新选择".into());
        }
        // H.264 needs even dimensions. Shrink by at most one pixel, never expand.
        Ok(Self { width: self.width & !1, height: self.height & !1, ..self })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordOptions {
    pub source_id: String,
    pub fps: u32,
    pub system_audio: bool,
    pub microphone: bool,
    pub cursor: bool,
    pub title: String,
    pub crop: Option<Crop>,
}
impl RecordOptions {
    pub fn validate(&self) -> Result<(), String> {
        if ![30, 60].contains(&self.fps) { return Err("只支持 30 或 60 FPS".into()); }
        if self.source_id.is_empty() || self.source_id.len() > 80 { return Err("捕获来源无效".into()); }
        if self.title.chars().count() > 120 { return Err("标题最多 120 个字符".into()); }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Dimensions { pub width: u32, pub height: u32 }
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Asset { pub role: String, pub relative_path: String }
impl Asset { pub fn new(role: &str, path: &str) -> Self { Self { role: role.into(), relative_path: path.into() } } }

/// The field names and version follow leolemon777/Lens LensManifest.swift.
/// Optional fields omitted here are legal for the Swift Codable reader.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub schema_version: String,
    pub id: String,
    pub kind: String,
    pub created_at: String,
    pub title: String,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dimensions: Option<Dimensions>,
    pub assets: Vec<Asset>,
    /// Preserve fields not understood by this first Windows implementation.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    pub index: u32,
    pub timeline_start_seconds: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    pub screen_relative_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub microphone_relative_path: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SegmentIndex { pub schema_version: String, pub segments: Vec<Segment> }
impl Default for SegmentIndex {
    fn default() -> Self { Self { schema_version: "0.1".into(), segments: vec![] } }
}
impl SegmentIndex {
    pub fn duration(&self) -> f64 { self.segments.iter().filter_map(|s| s.duration_seconds).sum() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn crop_stays_inside_selection() {
        assert_eq!(Crop{x:1,y:1,width:9,height:11}.validate(20,20).unwrap(), Crop{x:1,y:1,width:8,height:10});
    }
    #[test] fn crop_rejects_overflow() {
        assert!(Crop{x:u32::MAX,y:0,width:10,height:10}.validate(100,100).is_err());
    }
    #[test] fn crop_rejects_outside() {
        assert!(Crop{x:10,y:0,width:100,height:10}.validate(100,100).is_err());
    }
    #[test] fn crop_rejects_zero() { assert!(Crop{x:0,y:0,width:0,height:2}.validate(4,4).is_err()); }
    #[test] fn starting_is_not_reentrant() { assert!(!Phase::Starting.may_start()); }
    #[test] fn transition_guards() {
        assert!(Phase::Idle.may_start()); assert!(Phase::Recording.may_pause());
        assert!(Phase::Paused.may_resume()); assert!(!Phase::Processing.may_stop());
    }
    #[test] fn segments_exclude_pauses() {
        let mut idx=SegmentIndex::default();
        for n in 0..2 { idx.segments.push(Segment{index:n,timeline_start_seconds:idx.duration(),duration_seconds:Some(2.0),screen_relative_path:format!("raw/{n}.mp4"),microphone_relative_path:None}); }
        assert_eq!(idx.duration(),4.0); assert_eq!(idx.segments[1].timeline_start_seconds,2.0);
    }
}
