//! Reads the legacy v0.1 fixtures and validates manifest schema compatibility.

use lens_core::schema::manifest;

fn repo_root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .expect("repo root")
        .to_path_buf()
}

#[test]
fn legacy_recording_manifest_schema_is_readable() {
    let path = repo_root().join("Tests/LensCoreTests/Fixtures/LegacyRecordingV0_1/manifest.json");
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {path:?}: {e}"));
    let json: serde_json::Value =
        serde_json::from_str(&text).expect("legacy manifest is valid JSON");
    let version = json["schemaVersion"].as_str().expect("schemaVersion");
    manifest().validate(version).expect("v0.1 is readable");
}

#[test]
fn legacy_screenshot_manifest_schema_is_readable() {
    let path = repo_root().join("Tests/LensCoreTests/Fixtures/LegacyScreenshotV0_1/manifest.json");
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {path:?}: {e}"));
    let json: serde_json::Value =
        serde_json::from_str(&text).expect("legacy manifest is valid JSON");
    let version = json["schemaVersion"].as_str().expect("schemaVersion");
    manifest().validate(version).expect("v0.1 is readable");
}

#[test]
fn legacy_recording_assets_have_valid_relative_paths() {
    let path = repo_root().join("Tests/LensCoreTests/Fixtures/LegacyRecordingV0_1/manifest.json");
    let text = std::fs::read_to_string(&path).unwrap();
    let json: serde_json::Value = serde_json::from_str(&text).unwrap();
    let assets = json["assets"].as_array().expect("assets array");
    assert!(!assets.is_empty());
    for asset in assets {
        let rel = asset["relativePath"].as_str().expect("relativePath");
        lens_core::project::validate_relative_path(rel)
            .unwrap_or_else(|e| panic!("asset path {rel} should be valid: {e}"));
    }
}

#[test]
fn legacy_fixtures_deserialize_as_typed_manifest_and_roundtrip() {
    for fixture_dir in ["LegacyRecordingV0_1", "LegacyScreenshotV0_1"] {
        let path = repo_root().join(format!("Tests/LensCoreTests/Fixtures/{fixture_dir}/manifest.json"));
        let text = std::fs::read_to_string(&path).unwrap();
        let manifest: lens_core::manifest::LensManifest =
            serde_json::from_str(&text).expect("typed manifest deserializes");
        assert!(manifest.validate().is_ok());
        let reserialized = serde_json::to_string(&manifest).expect("reserializes");
        let manifest_roundtrip: lens_core::manifest::LensManifest =
            serde_json::from_str(&reserialized).expect("roundtrip deserializes");
        assert_eq!(manifest.id, manifest_roundtrip.id);
        assert_eq!(manifest.kind, manifest_roundtrip.kind);
        assert_eq!(manifest.assets.len(), manifest_roundtrip.assets.len());
    }
}

#[test]
fn unknown_fields_in_manifest_are_tolerated() {
    let json_with_unknown = r#"{
        "schemaVersion": "0.9",
        "id": "22222222-2222-2222-2222-222222222222",
        "kind": "recording",
        "createdAt": "2026-09-10T12:00:00Z",
        "title": "Mac特定录制",
        "state": "ready",
        "darwinSpecificBundleIdentifier": "com.apple.Safari",
        "metalGraphicsDeviceVendor": "Apple",
        "assets": [
            { "role": "screenVideo", "relativePath": "raw/screen.mp4" }
        ]
    }"#;
    let manifest: lens_core::manifest::LensManifest =
        serde_json::from_str(json_with_unknown).expect("unknown fields ignored safely");
    assert!(manifest.validate().is_ok());
    assert_eq!(manifest.title, "Mac特定录制");
}
