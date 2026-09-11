use lens_core::manifest::{LensRect, CURRENT_MANIFEST_VERSION};
use lens_project::{
    create_recording_package_with_source, finalize_recording_package_full,
    recover_incomplete_recordings, RecordingSourceMeta,
};
use std::fs;

#[test]
fn test_create_and_finalize_recording_with_camera_and_window_source() {
    let temp = std::env::temp_dir().join(format!("lens_test_rec_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&temp).unwrap();

    let meta = RecordingSourceMeta {
        mode: "window".into(),
        display_id: None,
        window_id: Some(12345),
        global_bounds: LensRect {
            x: 100.0,
            y: 100.0,
            width: 800.0,
            height: 600.0,
        },
        source_rect: None,
        window_title: Some("Test Window".into()),
        application_name: Some("test.exe".into()),
        frames_per_second: Some(30),
        requested_frames_per_second: Some(60),
    };

    let (package, id) = create_recording_package_with_source(&temp, Some(meta.clone())).unwrap();
    assert!(package.join("raw/segments").is_dir());
    assert!(package.join("manifest.json").is_file());

    let manifest_path = package.join("manifest.json");
    let mut capturing_manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    let original_created_at = capturing_manifest["createdAt"].clone();
    capturing_manifest["macExtension"] = serde_json::json!({ "keep": true });
    capturing_manifest["captureSource"]["vendorCaptureField"] =
        serde_json::json!({ "nested": "keep" });
    capturing_manifest["assets"] = serde_json::json!([
        {
            "role": "screenVideo",
            "relativePath": "raw/segments/0000.mp4",
            "vendorAssetField": "keep"
        },
        {
            "role": "macMetadata",
            "relativePath": "analysis/mac.json",
            "vendorAssetField": "keep"
        }
    ]);
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&capturing_manifest).unwrap(),
    )
    .unwrap();

    fs::write(package.join("raw/segments/0000.mp4"), b"fake_segment_0").unwrap();
    fs::write(package.join("raw/camera.mp4"), b"fake_camera_track").unwrap();
    fs::write(package.join("raw/segments/manifest.json"), b"{}").unwrap();

    let item = finalize_recording_package_full(
        &package,
        &id,
        800,
        600,
        10.5,
        &["0000.mp4".into()],
        false,
        true,
        true,
        Some(meta),
    )
    .unwrap();

    assert_eq!(item.state, "ready");
    assert_eq!(item.width, Some(800));
    assert_eq!(item.height, Some(600));

    let manifest_content = fs::read_to_string(package.join("manifest.json")).unwrap();
    let manifest: serde_json::Value = serde_json::from_str(&manifest_content).unwrap();

    assert_eq!(manifest["kind"], "recording");
    assert_eq!(manifest["state"], "ready");
    assert_eq!(manifest["schemaVersion"], CURRENT_MANIFEST_VERSION);
    assert_eq!(manifest["createdAt"], original_created_at);
    assert_eq!(manifest["macExtension"]["keep"], true);

    let src = &manifest["captureSource"];
    assert_eq!(src["mode"], "window");
    assert_eq!(src["windowID"], 12345);
    assert_eq!(src["windowTitle"], "Test Window");
    assert_eq!(src["requestedFramesPerSecond"], 60);
    assert_eq!(src["vendorCaptureField"]["nested"], "keep");

    let assets = manifest["assets"].as_array().unwrap();
    let has_camera_role = assets
        .iter()
        .any(|a| a["role"] == "camera" && a["relativePath"] == "raw/camera.mp4");
    assert!(
        has_camera_role,
        "Manifest must contain role: camera for camera track"
    );
    assert!(assets
        .iter()
        .any(|asset| { asset["role"] == "screenVideo" && asset["vendorAssetField"] == "keep" }));
    assert!(assets
        .iter()
        .any(|asset| { asset["role"] == "macMetadata" && asset["vendorAssetField"] == "keep" }));

    let has_mic_role = assets.iter().any(|a| a["role"] == "microphone");
    assert!(
        has_mic_role,
        "Manifest must contain microphone role when enabled"
    );

    let has_sys_role = assets.iter().any(|a| a["role"] == "systemAudio");
    assert!(
        !has_sys_role,
        "Manifest must not contain systemAudio when disabled"
    );

    let _ = fs::remove_dir_all(&temp);
}

#[test]
fn test_create_and_finalize_recording_with_region_source_and_audio_tracks() {
    let temp = std::env::temp_dir().join(format!("lens_test_reg_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&temp).unwrap();

    let meta = RecordingSourceMeta {
        mode: "region".into(),
        display_id: None,
        window_id: None,
        global_bounds: LensRect {
            x: 200.0,
            y: 300.0,
            width: 1280.0,
            height: 720.0,
        },
        source_rect: Some(LensRect {
            x: 200.0,
            y: 300.0,
            width: 1280.0,
            height: 720.0,
        }),
        window_title: None,
        application_name: None,
        frames_per_second: Some(60),
        requested_frames_per_second: Some(60),
    };

    let (package, id) = create_recording_package_with_source(&temp, Some(meta.clone())).unwrap();
    fs::write(package.join("raw/segments/0000.mp4"), b"fake_seg").unwrap();
    fs::write(package.join("raw/segments/manifest.json"), b"{}").unwrap();

    let item = finalize_recording_package_full(
        &package,
        &id,
        1280,
        720,
        5.0,
        &["0000.mp4".into()],
        true,
        true,
        false,
        Some(meta),
    )
    .unwrap();

    assert_eq!(item.state, "ready");
    let manifest_content = fs::read_to_string(package.join("manifest.json")).unwrap();
    let manifest: serde_json::Value = serde_json::from_str(&manifest_content).unwrap();

    let assets = manifest["assets"].as_array().unwrap();
    assert!(assets.iter().any(|a| a["role"] == "systemAudio"));
    assert!(assets.iter().any(|a| a["role"] == "microphone"));
    assert!(!assets.iter().any(|a| a["role"] == "camera"));

    let _ = fs::remove_dir_all(&temp);
}

fn create_test_mp4(output: &std::path::Path, duration: f64) {
    let result = std::process::Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-f",
            "lavfi",
            "-i",
            &format!("testsrc=size=320x180:rate=30:duration={duration}"),
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ])
        .arg(output)
        .output()
        .expect("ffmpeg must run to generate test mp4");
    assert!(result.status.success());
}

fn write_segment_journal(package: &std::path::Path, entries: &[(&str, &str)]) {
    let segments: Vec<_> = entries
        .iter()
        .enumerate()
        .map(|(index, (file, state))| {
            serde_json::json!({
                "index": index,
                "file": file,
                "state": state,
                "frames": 30,
                "started_at_100ns": index as i64 * 10_000_000,
                "ended_at_100ns": (index as i64 + 1) * 10_000_000
            })
        })
        .collect();
    fs::write(
        package.join("raw/segments/manifest.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "version": 1,
            "width": 320,
            "height": 180,
            "frame_rate": 30,
            "segments": segments
        }))
        .unwrap(),
    )
    .unwrap();
}

#[test]
fn test_incomplete_recording_recovery_with_valid_head_and_corrupt_tail() {
    let temp = std::env::temp_dir().join(format!("lens_test_recov_partial_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&temp).unwrap();

    let (package, _id) = create_recording_package_with_source(&temp, None).unwrap();
    let manifest_file = package.join("manifest.json");

    // Add an existing asset (e.g. ocr) to verify assets are not cleared
    fs::create_dir_all(package.join("analysis")).unwrap();
    fs::write(
        package.join("analysis/ocr.json"),
        b"{\"fullText\":\"test\"}",
    )
    .unwrap();
    let mut manifest_val: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&manifest_file).unwrap()).unwrap();
    manifest_val["assets"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "role": "ocr",
            "relativePath": "analysis/ocr.json",
            "macExtension": { "preserve": true }
        }));
    manifest_val["futureExtension"] = serde_json::json!({ "keep": "verbatim" });
    fs::write(
        &manifest_file,
        serde_json::to_vec_pretty(&manifest_val).unwrap(),
    )
    .unwrap();

    // Valid head segment (1.0s real mp4)
    let seg0 = package.join("raw/segments/0000.mp4");
    create_test_mp4(&seg0, 1.0);

    // Corrupt tail segment (truncated invalid bytes)
    let seg1 = package.join("raw/segments/0001.mp4");
    fs::write(&seg1, b"CORRUPTED_INCOMPLETE_TAIL_DATA_WITHOUT_MOOV").unwrap();
    // A valid but unjournaled file must not be pulled into a journaled recovery.
    let stray = package.join("raw/segments/9999.mp4");
    create_test_mp4(&stray, 1.0);
    write_segment_journal(
        &package,
        &[("0000.mp4", "confirmed"), ("0001.mp4", "writing")],
    );

    let seg0_bytes = fs::read(&seg0).unwrap();
    let seg1_bytes = fs::read(&seg1).unwrap();

    // Run recovery
    let report =
        lens_project::recover_recording_package(&package).expect("recovery should process");
    assert_eq!(report.status, "partial");
    assert_eq!(report.valid_segments_used, vec!["0000.mp4"]);
    assert_eq!(report.discarded_segments, vec!["0001.mp4"]);
    assert!(report.journal_used);
    assert!(!report.valid_segments_used.contains(&"9999.mp4".to_string()));
    assert!(report.duration_seconds.unwrap() > 0.5);

    // Partial recovery is usable but remains explicitly distinguishable/retryable.
    let recovered_manifest: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&manifest_file).unwrap()).unwrap();
    assert_eq!(recovered_manifest["state"], "recoveredPartial");
    assert!(recovered_manifest["durationSeconds"].as_f64().unwrap() > 0.5);

    // Verify existing ocr asset is preserved!
    let assets = recovered_manifest["assets"].as_array().unwrap();
    assert!(assets
        .iter()
        .any(|a| a["role"] == "ocr" && a["relativePath"] == "analysis/ocr.json"));
    let ocr = assets.iter().find(|a| a["role"] == "ocr").unwrap();
    assert_eq!(ocr["macExtension"]["preserve"], true);
    assert_eq!(recovered_manifest["futureExtension"]["keep"], "verbatim");
    assert!(
        assets
            .iter()
            .any(|a| a["role"] == "screenVideoSegment"
                && a["relativePath"] == "raw/segments/0000.mp4")
    );
    // Corrupt segment should not be registered as screenVideoSegment
    assert!(!assets
        .iter()
        .any(|a| a["relativePath"] == "raw/segments/0001.mp4"));

    // Verify real playable video
    let program = package.join("previews/program.mp4");
    assert!(program.is_file());
    lens_project::post::verify_video_decodable(&program).unwrap();
    let dur = lens_project::post::ffprobe_duration(&program).unwrap();
    assert!(dur > 0.5);

    // Verify original files remain completely unchanged (hashes/bytes preserved)
    assert_eq!(fs::read(&seg0).unwrap(), seg0_bytes);
    assert_eq!(fs::read(&seg1).unwrap(), seg1_bytes);

    // Verify report file
    let report_file = package.join("analysis/recovery-report.json");
    assert!(report_file.is_file());

    // Retrying recovery on a recoveredPartial package is safely allowed
    let retry_res = lens_project::recover_recording_package(&package);
    assert!(retry_res.is_ok(), "recoveredPartial should allow retry");

    let _ = fs::remove_dir_all(&temp);
}

#[test]
fn test_incomplete_recording_recovery_all_corrupt_fails_safely() {
    let temp = std::env::temp_dir().join(format!("lens_test_recov_fail_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&temp).unwrap();

    let (package, _id) = create_recording_package_with_source(&temp, None).unwrap();
    let manifest_file = package.join("manifest.json");

    let seg0 = package.join("raw/segments/0000.mp4");
    fs::write(&seg0, b"CORRUPTED_HEADER_NOT_A_VALID_MP4").unwrap();
    let seg1 = package.join("raw/segments/0001.mp4");
    fs::write(&seg1, b"").unwrap(); // 0-byte file
    write_segment_journal(
        &package,
        &[("0000.mp4", "confirmed"), ("0001.mp4", "writing")],
    );

    let seg0_bytes = fs::read(&seg0).unwrap();
    let seg1_bytes = fs::read(&seg1).unwrap();

    let report = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(report.status, "failed");
    assert!(report.valid_segments_used.is_empty());
    assert_eq!(report.discarded_segments.len(), 2);

    let final_manifest: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&manifest_file).unwrap()).unwrap();
    // Must NOT be ready
    assert_ne!(final_manifest["state"], "ready");
    assert_eq!(final_manifest["state"], "recoveryFailed");

    // Original files must remain untouched
    assert_eq!(fs::read(&seg0).unwrap(), seg0_bytes);
    assert_eq!(fs::read(&seg1).unwrap(), seg1_bytes);

    // Recovery report is preserved for user diagnosis
    let report_file = package.join("analysis/recovery-report.json");
    assert!(report_file.is_file());

    let _ = fs::remove_dir_all(&temp);
}

#[test]
fn test_batch_recover_incomplete_recordings_skips_unrelated_and_processes_capturing() {
    let temp = std::env::temp_dir().join(format!("lens_test_batch_recov_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&temp).unwrap();

    let (pkg_capturing, _) = create_recording_package_with_source(&temp, None).unwrap();
    let seg = pkg_capturing.join("raw/segments/0000.mp4");
    create_test_mp4(&seg, 1.0);
    write_segment_journal(&pkg_capturing, &[("0000.mp4", "confirmed")]);

    // Call batch recover
    recover_incomplete_recordings(&temp);

    let manifest_file = pkg_capturing.join("manifest.json");
    let val: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(manifest_file).unwrap()).unwrap();
    assert_eq!(val["state"], "ready");

    let _ = fs::remove_dir_all(&temp);
}

#[test]
fn test_recovery_failed_package_can_retry_after_media_track_is_fixed() {
    let temp = std::env::temp_dir().join(format!(
        "lens_test_recov_retry_{}",
        lens_project::new_uuid()
    ));
    fs::create_dir_all(&temp).unwrap();
    let (package, _) = create_recording_package_with_source(&temp, None).unwrap();
    let segment = package.join("raw/segments/0000.mp4");
    create_test_mp4(&segment, 1.0);
    write_segment_journal(&package, &[("0000.mp4", "confirmed")]);
    let original = fs::read(&segment).unwrap();

    // The presence of a broken side track forces product mixing to fail.
    fs::write(package.join("raw/microphone.wav"), b"not a wave file").unwrap();
    let first = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(first.status, "failed");
    let failed_manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(package.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(failed_manifest["state"], "recoveryFailed");
    assert!(!package.join("previews/program.mp4").exists());

    fs::remove_file(package.join("raw/microphone.wav")).unwrap();
    let retry = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(retry.status, "full");
    let ready_manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(package.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(ready_manifest["state"], "ready");
    lens_project::post::verify_video_decodable(&package.join("previews/program.mp4")).unwrap();
    assert_eq!(fs::read(&segment).unwrap(), original);

    let _ = fs::remove_dir_all(&temp);
}

#[test]
fn test_recovery_refuses_package_held_by_live_recording_guard() {
    let temp = std::env::temp_dir().join(format!(
        "lens_test_recov_active_{}",
        lens_project::new_uuid()
    ));
    fs::create_dir_all(&temp).unwrap();
    let (package, _) = create_recording_package_with_source(&temp, None).unwrap();
    let segment = package.join("raw/segments/0000.mp4");
    create_test_mp4(&segment, 1.0);
    write_segment_journal(&package, &[("0000.mp4", "writing")]);

    let guard = lens_project::create_recording_activity_guard(&package).unwrap();
    let error = lens_project::recover_recording_package(&package)
        .unwrap_err()
        .to_string();
    assert!(error.contains("still active"), "unexpected error: {error}");
    assert!(!package.join("previews/program.mp4").exists());
    drop(guard);

    let report = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(report.status, "full");
    let _ = fs::remove_dir_all(&temp);
}

#[test]
#[ignore = "mutates process media-tool overrides; run this test in isolation"]
fn test_recovery_reports_media_tool_unavailable_without_publishing() {
    let temp = std::env::temp_dir().join(format!(
        "lens_test_recov_no_tools_{}",
        lens_project::new_uuid()
    ));
    fs::create_dir_all(&temp).unwrap();
    let (package, _) = create_recording_package_with_source(&temp, None).unwrap();
    let segment = package.join("raw/segments/0000.mp4");
    create_test_mp4(&segment, 1.0);
    write_segment_journal(&package, &[("0000.mp4", "confirmed")]);
    let original = fs::read(&segment).unwrap();
    let fake_tool = temp.join("unusable-media-tool.exe");
    fs::write(&fake_tool, b"not an executable").unwrap();

    let previous_ffmpeg = std::env::var_os("LENS_FFMPEG_PATH");
    let previous_ffprobe = std::env::var_os("LENS_FFPROBE_PATH");
    std::env::set_var("LENS_FFMPEG_PATH", &fake_tool);
    std::env::set_var("LENS_FFPROBE_PATH", &fake_tool);
    let report = lens_project::recover_recording_package(&package).unwrap();
    match previous_ffmpeg {
        Some(value) => std::env::set_var("LENS_FFMPEG_PATH", value),
        None => std::env::remove_var("LENS_FFMPEG_PATH"),
    }
    match previous_ffprobe {
        Some(value) => std::env::set_var("LENS_FFPROBE_PATH", value),
        None => std::env::remove_var("LENS_FFPROBE_PATH"),
    }

    assert_eq!(report.status, "failed");
    assert!(!package.join("previews/program.mp4").exists());
    assert_eq!(fs::read(&segment).unwrap(), original);
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(package.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["state"], "recoveryFailed");

    // Retry recovery after media tools are restored: must succeed
    let retry_report = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(retry_report.status, "full");
    let ready_manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(package.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(ready_manifest["state"], "ready");
    assert!(package.join("previews/program.mp4").exists());
    lens_project::post::verify_video_decodable(&package.join("previews/program.mp4")).unwrap();

    let _ = fs::remove_dir_all(&temp);
}

#[test]
fn test_recovery_detects_corrupt_payload_even_with_valid_container_duration() {
    let temp = std::env::temp_dir().join(format!(
        "lens_test_recov_payload_{}",
        lens_project::new_uuid()
    ));
    fs::create_dir_all(&temp).unwrap();
    let (package, _) = create_recording_package_with_source(&temp, None).unwrap();
    let seg0 = package.join("raw/segments/0000.mp4");
    create_test_mp4(&seg0, 1.0);

    let seg1 = package.join("raw/segments/0001.mp4");
    // Generate segment with faststart so container moov duration is intact
    std::process::Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=s=160x120:d=1:r=30",
            "-c:v",
            "libx264",
            "-movflags",
            "+faststart",
        ])
        .arg(&seg1)
        .output()
        .unwrap();

    // Overwrite payload bytes inside mdat to corrupt actual video decoding
    let mut bytes = fs::read(&seg1).unwrap();
    if let Some(pos) = bytes.windows(4).position(|w| w == b"mdat") {
        let start = pos + 8;
        for b in &mut bytes[start..] {
            *b = 0xFF;
        }
        fs::write(&seg1, &bytes).unwrap();
    }
    write_segment_journal(
        &package,
        &[("0000.mp4", "confirmed"), ("0001.mp4", "confirmed")],
    );

    let report = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(report.status, "partial");
    assert_eq!(report.valid_segments_used, vec!["0000.mp4"]);
    assert_eq!(report.discarded_segments, vec!["0001.mp4"]);

    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(package.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["state"], "recoveredPartial");
    assert!(package.join("previews/program.mp4").exists());
    lens_project::post::verify_video_decodable(&package.join("previews/program.mp4")).unwrap();

    let _ = fs::remove_dir_all(&temp);
}

#[test]
fn test_recovery_partial_state_allows_subsequent_retry() {
    let temp = std::env::temp_dir().join(format!(
        "lens_test_recov_partial_retry_{}",
        lens_project::new_uuid()
    ));
    fs::create_dir_all(&temp).unwrap();
    let (package, _) = create_recording_package_with_source(&temp, None).unwrap();
    let seg0 = package.join("raw/segments/0000.mp4");
    create_test_mp4(&seg0, 1.0);
    let seg1 = package.join("raw/segments/0001.mp4");
    fs::write(&seg1, b"corrupted").unwrap();
    write_segment_journal(
        &package,
        &[("0000.mp4", "confirmed"), ("0001.mp4", "confirmed")],
    );

    let report1 = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(report1.status, "partial");

    // Repair seg1 with valid mp4
    create_test_mp4(&seg1, 1.0);

    // Calling recovery on recoveredPartial package must be allowed and succeed fully
    let report2 = lens_project::recover_recording_package(&package).unwrap();
    assert_eq!(report2.status, "full");
    assert_eq!(report2.valid_segments_used.len(), 2);

    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(package.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["state"], "ready");

    let _ = fs::remove_dir_all(&temp);
}
