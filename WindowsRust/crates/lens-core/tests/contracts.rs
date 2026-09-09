//! Synthetic source-contract fixtures, NOT evidence of a Mac app roundtrip.
use lens_core::{Manifest,SegmentIndex,check_version};
#[test]
fn reads_manifest_source_contract() {
    let m:Manifest=serde_json::from_str(include_str!("fixtures/manifest-0.9.json")).unwrap();
    check_version(&m.schema_version).unwrap();
    assert_eq!(m.kind,"recording");
    assert_eq!(m.dimensions.as_ref().unwrap().width,1920);
    assert!(uuid::Uuid::parse_str(&m.id).is_ok());
    assert!(chrono::DateTime::parse_from_rfc3339(&m.created_at).is_ok());
}
#[test]
fn writes_camel_case_and_preserves_optional_capture_source() {
    let m:Manifest=serde_json::from_str(include_str!("fixtures/manifest-0.9.json")).unwrap();
    let value=serde_json::to_value(m).unwrap();
    assert_eq!(value["captureSource"]["mode"],"display");
    assert!(value.get("schemaVersion").is_some());
    assert!(value.get("schema_version").is_none());
    assert_eq!(value["assets"][0]["relativePath"],"raw/screen.mp4");
}
#[test]
fn segments_represent_pause_free_time() {
    let index:SegmentIndex=serde_json::from_str(include_str!("fixtures/segments-0.1.json")).unwrap();
    assert_eq!(index.schema_version,"0.1");
    assert_eq!(index.duration(),10.0);
    assert_eq!(index.segments[1].timeline_start_seconds,5.0);
}
