use std::fs;
use std::path::PathBuf;
use std::process::Command;

use lens_core::edit::{VideoEditSegment, VideoEditTimeline};
use lens_project::post::find_tool;
use lens_project::render::{export_package, render_package};
use lens_project::{new_uuid, scan_library, LibraryItem};

fn temp_workspace(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("lens-test-edit-export-{}", name));
    if dir.exists() {
        let _ = fs::remove_dir_all(&dir);
    }
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn ffmpeg(args: &[&str]) {
    let tool = find_tool("ffmpeg");
    let status = Command::new(&tool)
        .args(["-hide_banner", "-loglevel", "error", "-y"])
        .args(args)
        .status()
        .unwrap_or_else(|e| panic!("failed to run {}: {e}", tool.display()));
    assert!(status.success(), "ffmpeg command failed: {args:?}");
}

#[test]
fn test_edit_pipeline_end_to_end_consistency_and_raw_integrity() {
    let ws = temp_workspace("e2e-consistency");
    let pkg = ws.join("test-recording.lens");
    let raw_dir = pkg.join("raw");
    let analysis_dir = pkg.join("analysis");
    let edits_dir = pkg.join("edits");
    let previews_dir = pkg.join("previews");
    fs::create_dir_all(&raw_dir).unwrap();
    fs::create_dir_all(&analysis_dir).unwrap();
    fs::create_dir_all(&edits_dir).unwrap();
    fs::create_dir_all(&previews_dir).unwrap();

    let screen_mp4 = raw_dir.join("screen.mp4");
    let camera_mp4 = raw_dir.join("camera.mp4");
    let mic_wav = raw_dir.join("mic.wav");
    let system_wav = raw_dir.join("system.wav");

    // 1. Generate 2-second screen video (red first second, blue second second)
    ffmpeg(&[
        "-f",
        "lavfi",
        "-i",
        "color=c=red:duration=1:size=640x360:rate=30",
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:duration=1:size=640x360:rate=30",
        "-filter_complex",
        "[0:v][1:v]concat=n=2:v=1:a=0[v]",
        "-map",
        "[v]",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        screen_mp4.to_str().unwrap(),
    ]);

    // 2. Generate 2-second camera PiP video (green)
    ffmpeg(&[
        "-f",
        "lavfi",
        "-i",
        "color=c=green:duration=2:size=320x180:rate=30",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        camera_mp4.to_str().unwrap(),
    ]);

    // 3. Generate system audio: continuous 440 Hz tone for 2s
    ffmpeg(&[
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=2",
        "-c:a",
        "pcm_s16le",
        system_wav.to_str().unwrap(),
    ]);

    // 4. Generate mic audio: 1s silence + 1s speech (1000 Hz)
    ffmpeg(&[
        "-f",
        "lavfi",
        "-i",
        "anullsrc=duration=1:sample_rate=48000",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=1000:duration=1:sample_rate=48000",
        "-filter_complex",
        "[0:a][1:a]concat=n=2:v=0:a=1[a]",
        "-map",
        "[a]",
        "-c:a",
        "pcm_s16le",
        mic_wav.to_str().unwrap(),
    ]);

    // Snapshot exact initial bytes of all raw assets
    let screen_bytes_init = fs::read(&screen_mp4).expect("screen bytes");
    let camera_bytes_init = fs::read(&camera_mp4).expect("camera bytes");
    let mic_bytes_init = fs::read(&mic_wav).expect("mic bytes");
    let system_bytes_init = fs::read(&system_wav).expect("system bytes");

    // Write manifest
    let manifest = serde_json::json!({
        "schemaVersion": "0.9",
        "id": new_uuid(),
        "kind": "recording",
        "createdAt": "2026-09-11T00:00:00Z",
        "title": "E2E Edit Export Test",
        "state": "ready",
        "durationSeconds": 2.0,
        "assets": [
            { "role": "screenVideo", "relativePath": "raw/screen.mp4" },
            { "role": "camera", "relativePath": "raw/camera.mp4" },
            { "role": "microphone", "relativePath": "raw/mic.wav" },
            { "role": "systemAudio", "relativePath": "raw/system.wav" }
        ]
    });
    fs::write(
        pkg.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();

    // Write auto-edit plan with PiP, ducking, camera mode
    let edit_plan = serde_json::json!({
        "cameraPip": {
            "isEnabled": true,
            "position": "bottomRight",
            "scale": 0.25,
            "shape": "roundedRect"
        },
        "camera": {
            "mode": "auto",
            "keyframes": [
                {
                    "time": 0.5,
                    "scale": 1.4,
                    "center": { "x": 0.5, "y": 0.5 },
                    "easing": "easeOut",
                    "reason": "focus"
                }
            ]
        },
        "audio": {
            "duckingEnabled": true,
            "duckingAttenuationDb": -15.0,
            "normalizeEnabled": false
        }
    });
    fs::write(
        edits_dir.join("auto-edit.json"),
        serde_json::to_vec_pretty(&edit_plan).unwrap(),
    )
    .unwrap();

    // Write timeline with 2 segments: reordered (seg 2 first, then seg 1)
    let timeline = VideoEditTimeline {
        schema_version: "0.1".into(),
        segments: vec![
            VideoEditSegment {
                id: "seg-first-half".into(),
                source_start_seconds: 0.0,
                source_end_seconds: 1.0,
                playback_rate: 1.0,
                is_enabled: true,
                transition: "cut".into(),
            },
            VideoEditSegment {
                id: "seg-second-half".into(),
                source_start_seconds: 1.0,
                source_end_seconds: 2.0,
                playback_rate: 1.0,
                is_enabled: true,
                transition: "cut".into(),
            },
        ],
    };

    // 5. Execute render
    let rendered_path = render_package(&pkg, &timeline).expect("render_package succeeds");
    assert!(rendered_path.is_file());
    assert_eq!(rendered_path, previews_dir.join("edited.mp4"));

    // 6. Execute exports for original, balanced, and lightweight presets
    let exp_orig = export_package(&pkg, "original").expect("export original");
    let exp_bal = export_package(&pkg, "balanced").expect("export balanced");
    let exp_light = export_package(&pkg, "lightweight").expect("export lightweight");

    assert!(exp_orig.is_file());
    assert!(exp_bal.is_file());
    assert!(exp_light.is_file());

    // 7. Assert raw media integrity: all raw assets must remain 100% byte-for-byte identical
    assert_eq!(
        fs::read(&screen_mp4).unwrap(),
        screen_bytes_init,
        "raw screen.mp4 must not be modified"
    );
    assert_eq!(
        fs::read(&camera_mp4).unwrap(),
        camera_bytes_init,
        "raw camera.mp4 must not be modified"
    );
    assert_eq!(
        fs::read(&mic_wav).unwrap(),
        mic_bytes_init,
        "raw mic.wav must not be modified"
    );
    assert_eq!(
        fs::read(&system_wav).unwrap(),
        system_bytes_init,
        "raw system.wav must not be modified"
    );

    // 8. Test reopening project: library index scan discovers project and its edited preview
    let library_items: Vec<LibraryItem> = scan_library(&ws).expect("scan_library succeeds");
    assert_eq!(library_items.len(), 1);
    let item = &library_items[0];
    assert_eq!(item.title, "E2E Edit Export Test");
    assert_eq!(item.kind, "recording");
    assert!(item.preview_path.is_some());

    let _ = fs::remove_dir_all(&ws);
}
