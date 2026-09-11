//! Records a segmented WGC -> H.264 capture for M0 evidence.
//!
//! Runs in its own process: Media Foundation and WGC sessions are not yet
//! reused across multiple full recording lifecycles in one process, which is
//! an accepted prototype limitation recorded in the execution log.

use lens_platform_windows::encode;
use std::time::Duration;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output_dir =
        std::path::Path::new("../Build/Windows/evidence/m0-rust-002-20260909/wgc-h264-segments");
    let _ = std::fs::remove_dir_all(output_dir);

    let segmented = encode::record_primary_monitor_h264_segmented(
        output_dir,
        Duration::from_secs(5),
        Duration::from_secs(2),
    )?;
    println!(
        "Segmented recording: {}x{} segments={} frames={} elapsed={:?} dir={}",
        segmented.width,
        segmented.height,
        segmented.segments.len(),
        segmented.frames_written,
        segmented.elapsed,
        segmented.output_dir
    );
    assert!(segmented.segments.len() >= 2, "rotation must occur");
    assert!(segmented.frames_written >= 40);

    for segment in &segmented.segments {
        assert_eq!(segment.state, "confirmed");
        let decode = encode::verify_h264_decoding(&output_dir.join(&segment.file))?;
        println!(
            "  {} state={} decoded_frames={} nonzero={}",
            segment.file, segment.state, decode.frames_decoded, decode.saw_nonzero_pixels
        );
        assert!(decode.frames_decoded >= 10);
        assert!(decode.saw_nonzero_pixels);
    }

    let manifest: encode::RecordingManifest =
        serde_json::from_str(&std::fs::read_to_string(output_dir.join("manifest.json"))?)?;
    assert_eq!(manifest.segments.len(), segmented.segments.len());
    assert!(manifest
        .segments
        .iter()
        .all(|item| item.state == "confirmed"));

    let recovery = encode::scan_segmented_recording(output_dir)?;
    println!(
        "Recovery scan: recoverable_frames={} broken_segments={:?}",
        recovery.recoverable_frames, recovery.broken_segments
    );
    assert!(recovery.broken_segments.is_empty());
    assert_eq!(recovery.recoverable_frames, segmented.frames_written);
    Ok(())
}
