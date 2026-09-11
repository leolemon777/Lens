//! Portable `.lens` manifest matching the Swift 0.9 schema.

use serde::{Deserialize, Serialize};

use crate::project::validate_relative_path;
use crate::schema::{self, SchemaError};

pub const CURRENT_MANIFEST_VERSION: &str = "0.9";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LensRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LensDimensions {
    pub width: i64,
    pub height: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LensAsset {
    pub role: String,
    pub relative_path: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenshotCaptureSource {
    pub mode: String,
    #[serde(rename = "displayID", skip_serializing_if = "Option::is_none")]
    pub display_id: Option<u32>,
    #[serde(rename = "windowIDs", default, skip_serializing_if = "Vec::is_empty")]
    pub window_ids: Vec<u32>,
    pub global_bounds: LensRect,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_rect: Option<LensRect>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub application_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingCaptureSource {
    pub mode: String,
    #[serde(rename = "displayID", skip_serializing_if = "Option::is_none")]
    pub display_id: Option<u32>,
    #[serde(rename = "windowID", skip_serializing_if = "Option::is_none")]
    pub window_id: Option<u32>,
    pub global_bounds: LensRect,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_rect: Option<LensRect>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub application_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frames_per_second: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requested_frames_per_second: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LensManifest {
    pub schema_version: String,
    pub id: String,
    pub kind: String,
    pub created_at: String,
    pub title: String,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dimensions: Option<LensDimensions>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capture_source: Option<RecordingCaptureSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshot_capture_source: Option<ScreenshotCaptureSource>,
    pub assets: Vec<LensAsset>,
}

impl LensManifest {
    pub fn validate(&self) -> Result<(), SchemaError> {
        schema::manifest().validate(&self.schema_version)?;
        if self.kind != "screenshot" && self.kind != "recording" {
            return Err(SchemaError::Malformed {
                document: "manifest.json".into(),
                found: self.kind.clone(),
            });
        }
        for asset in &self.assets {
            validate_relative_path(&asset.relative_path).map_err(|_| SchemaError::Malformed {
                document: asset.relative_path.clone(),
                found: asset.relative_path.clone(),
            })?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_schema_roundtrip() {
        let json = r#"{
            "schemaVersion": "0.9",
            "id": "11111111-1111-1111-1111-111111111111",
            "kind": "screenshot",
            "createdAt": "2026-09-10T01:02:03Z",
            "title": "截图",
            "state": "ready",
            "dimensions": { "width": 100, "height": 80 },
            "assets": [{ "role": "screenshot", "relativePath": "raw/screenshot.png" }]
        }"#;
        let manifest: LensManifest = serde_json::from_str(json).unwrap();
        manifest.validate().unwrap();
        assert_eq!(manifest.kind, "screenshot");
        let encoded = serde_json::to_value(&manifest).unwrap();
        assert_eq!(encoded["schemaVersion"], "0.9");
        assert_eq!(encoded["createdAt"], "2026-09-10T01:02:03Z");
    }

    #[test]
    fn future_schema_is_rejected() {
        let mut manifest: LensManifest = serde_json::from_str(
            r#"{
            "schemaVersion": "9.9",
            "id": "11111111-1111-1111-1111-111111111111",
            "kind": "screenshot",
            "createdAt": "2026-09-10T01:02:03Z",
            "title": "x",
            "state": "ready",
            "assets": []
        }"#,
        )
        .unwrap();
        assert!(manifest.validate().is_err());
        manifest.schema_version = "0.9".into();
        manifest.validate().unwrap();
    }
}
