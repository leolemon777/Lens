//! Integration tests that touch real Windows graphics infrastructure.

use lens_platform_windows::{audio, camera, capture, display, dpi, encode, graphics};

/// WGC limits concurrent capture sessions per process; hardware tests must
/// serialize even when cargo runs tests on parallel threads.
static HARDWARE_TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn hardware_lock() -> std::sync::MutexGuard<'static, ()> {
    HARDWARE_TEST_MUTEX
        .lock()
        .expect("hardware test mutex poisoned")
}

#[test]
fn enumerates_at_least_one_valid_display() {
    let displays = display::enumerate_displays().expect("display enumeration");
    assert!(
        !displays.is_empty(),
        "at least one display must be attached"
    );
    for item in &displays {
        assert!(item.geometry_is_valid(), "invalid geometry: {item:?}");
    }
}

#[test]
fn enumerates_dxgi_adapters_with_outputs() {
    let adapters = graphics::enumerate_adapters().expect("DXGI enumeration");
    assert!(!adapters.is_empty(), "at least one adapter must exist");
    let attached_outputs = adapters
        .iter()
        .flat_map(|adapter| adapter.outputs.iter())
        .filter(|output| output.attached_to_desktop);
    assert!(
        attached_outputs.into_iter().count() >= 1,
        "at least one output must be attached to the desktop"
    );
}

#[test]
fn creates_warp_device_with_bgra_support() {
    let device = graphics::create_warp_device().expect("WARP device");
    assert!(!device.capabilities.hardware);
    assert!(!device.capabilities.video_support);
    assert!(device.capabilities.feature_level >= 0xB000);
}

// Hardware device creation and the WGC support probe require an interactive
// session with real graphics drivers; run explicitly on the baseline machine:
// cargo test -p lens-platform-windows --test platform_integration -- --ignored --nocapture
#[test]
#[ignore = "requires an interactive baseline machine with real GPU drivers"]
fn creates_hardware_video_device_and_reports_wgc_support() {
    let _guard = hardware_lock();
    // Best effort: the first test in the process wins; later calls may return
    // an error because the awareness context can no longer be changed.
    let _ = dpi::enable_per_monitor_v2();
    let device = graphics::create_video_device().expect("hardware video device");
    assert!(device.capabilities.hardware);
    assert!(device.capabilities.feature_level >= 0xB000);

    let supported = capture::is_wgc_supported().expect("WGC support probe");
    assert!(supported, "WGC must be supported on the baseline machine");
}

#[test]
#[ignore = "requires an interactive baseline machine with real GPU drivers"]
fn captures_real_wgc_frame_from_primary_monitor() {
    let _guard = hardware_lock();
    let _ = dpi::enable_per_monitor_v2();
    let frame = capture::capture_primary_monitor_frame(std::time::Duration::from_secs(3))
        .expect("WGC frame capture");
    let displays = display::enumerate_displays().expect("display enumeration");
    let primary = displays
        .iter()
        .find(|item| item.is_primary)
        .or_else(|| displays.first())
        .expect("primary display");

    assert_eq!(frame.width as i32, primary.width());
    assert_eq!(frame.height as i32, primary.height());
    assert_eq!(
        frame.bgra.len(),
        frame.width as usize * frame.height as usize * 4
    );

    let nonblack = frame
        .bgra
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|pixel| pixel.iter().any(|byte| *byte != 0))
        .count();
    assert!(
        nonblack > frame.bgra.len() / 4 / 100,
        "capture must contain real non-black desktop content"
    );
}

#[test]
#[ignore = "requires an interactive baseline machine with real GPU drivers"]
fn event_driven_capture_runs_on_capture_runtime_threads() {
    let _guard = hardware_lock();
    let _ = dpi::enable_per_monitor_v2();
    let stats = capture::capture_primary_monitor_frame_stream(std::time::Duration::from_secs(2))
        .expect("event-driven capture");

    assert!(
        stats.frames_arrived >= 1,
        "at least one FrameArrived callback must fire"
    );
    assert_eq!(
        stats.frames_arrived, stats.frames_drained,
        "every arrived frame must be drained from the pool"
    );
    assert!(
        !stats.callback_thread_ids.is_empty(),
        "callbacks must record their thread ids"
    );
    assert!(
        stats
            .callback_thread_ids
            .iter()
            .all(|id| *id != stats.worker_thread_id),
        "free-threaded FrameArrived must not run on the worker thread"
    );
    assert!(
        stats.elapsed >= stats.requested_duration,
        "burst must run for the requested duration before stopping"
    );
}

#[test]
#[ignore = "requires an interactive baseline machine with real GPU drivers and Media Foundation codecs"]
fn records_and_decodes_h264_from_real_wgc_frames() {
    let _guard = hardware_lock();
    let _ = dpi::enable_per_monitor_v2();
    let output_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .join("Build/Windows/evidence/m0-rust-002-20260909/tests");
    std::fs::create_dir_all(&output_dir).expect("create temp output");
    let recording_path = output_dir.join("wgc-h264-recording.mp4");
    let _ = std::fs::remove_file(&recording_path);

    let recording =
        encode::record_primary_monitor_h264(&recording_path, std::time::Duration::from_secs(2))
            .unwrap_or_else(|err| panic!("H.264 recording failed: {err:?}"));
    println!("Recording diagnostics: {recording:?}");
    assert_eq!((recording.width, recording.height), (3840, 2160));
    assert!(recording.frames_written >= 10, "expected animated frames");

    let decode = encode::verify_h264_decoding(&recording_path).expect("decode verification");
    assert!(decode.frames_decoded >= 10, "expected decoded frames");
    assert!(
        decode.saw_nonzero_pixels,
        "decoded frames must contain pixels"
    );

    std::fs::remove_file(&recording_path).expect("remove test recording");
}

#[test]
#[ignore = "requires an interactive baseline machine with real GPU drivers and Media Foundation codecs"]
fn records_segmented_h264_with_confirmed_journal() {
    let _guard = hardware_lock();
    let _ = dpi::enable_per_monitor_v2();
    let output_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .join("Build/Windows/evidence/m0-rust-002-20260909/tests/segments");
    let _ = std::fs::remove_dir_all(&output_dir);

    let segmented = encode::record_primary_monitor_h264_segmented(
        &output_dir,
        std::time::Duration::from_secs(4),
        std::time::Duration::from_millis(1500),
    )
    .expect("segmented recording");
    println!("Segment diagnostics: {segmented:?}");

    assert_eq!((segmented.width, segmented.height), (3840, 2160));
    assert!(segmented.segments.len() >= 2, "rotation must occur");
    assert!(segmented.frames_written >= 30);

    let manifest_path = output_dir.join("manifest.json");
    let manifest: encode::RecordingManifest =
        serde_json::from_str(&std::fs::read_to_string(&manifest_path).expect("manifest json"))
            .expect("manifest schema");
    assert_eq!(manifest.version, 1);
    assert_eq!(manifest.segments.len(), segmented.segments.len());

    for (position, segment) in manifest.segments.iter().enumerate() {
        assert_eq!(segment.state, "confirmed");
        let path = output_dir.join(&segment.file);
        assert!(path.is_file(), "missing segment file: {path:?}");
        let decode = encode::verify_h264_decoding(&path).expect("segment decode");
        // The final segment can be a short tail; full segments must carry
        // enough decoded frames to prove real content.
        let minimum = if position + 1 == manifest.segments.len() {
            1
        } else {
            10
        };
        assert!(
            decode.frames_decoded >= minimum,
            "segment {position} too small: {} frames",
            decode.frames_decoded
        );
        assert!(decode.saw_nonzero_pixels);
        assert_eq!(decode.frames_decoded, segment.frames);
    }

    std::fs::remove_dir_all(&output_dir).expect("remove segmented test output");
}

#[test]
#[ignore = "requires an interactive baseline machine with real GPU drivers and Media Foundation codecs"]
fn recovers_segments_after_forced_process_termination() {
    let _guard = hardware_lock();
    let _ = dpi::enable_per_monitor_v2();

    let output_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .join("Build/Windows/evidence/m0-rust-002-20260909/tests/forced-kill");
    let _ = std::fs::remove_dir_all(&output_dir);

    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_segmented_recorder"))
        .arg(&output_dir)
        .arg("15")
        .arg("2")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn segmented recorder");

    // Setup takes roughly one second and 4K decode verification of a rotated
    // segment adds CPU time, so give two segments room to confirm before the
    // kill lands in a later segment's writing window.
    std::thread::sleep(std::time::Duration::from_secs(8));
    child.kill().expect("force-kill recorder");
    let status = child.wait().expect("wait for killed recorder");
    assert!(!status.success(), "killed recorder must not exit cleanly");

    let report = encode::scan_segmented_recording(&output_dir).expect("recovery scan");
    println!("Forced-kill recovery: {report:?}");

    let decodable = report
        .segments
        .iter()
        .filter(|segment| segment.decodable)
        .count();
    assert!(
        decodable >= 2,
        "at least two complete segments must survive: {report:?}"
    );
    assert!(
        report.segments.len() as u64 - decodable as u64 <= 1,
        "loss boundary must be at most one segment: {report:?}"
    );
    assert!(
        report
            .segments
            .iter()
            .filter(|segment| segment.journal_state == "confirmed")
            .all(|segment| segment.decodable),
        "every confirmed segment must decode: {report:?}"
    );
    assert!(
        report.recoverable_frames >= 30,
        "expected substantial recoverable content: {report:?}"
    );

    std::fs::remove_dir_all(&output_dir).expect("remove forced-kill test output");
}

#[test]
#[ignore = "requires interactive audio devices; plays a short quiet tone"]
fn captures_dual_wasapi_audio_with_clock_metadata() {
    let _guard = hardware_lock();
    let output_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .join("Build/Windows/evidence/m0-rust-002-20260909/tests/audio");
    let _ = std::fs::remove_dir_all(&output_dir);

    let stats = audio::capture_dual_audio(&output_dir, std::time::Duration::from_secs(2), true)
        .expect("dual audio capture");
    println!("Audio diagnostics: {stats:?}");

    let system = stats.system.as_ref().expect("system audio track");
    validate_wav(std::path::Path::new(&system.path));
    assert!(system.frames >= 48_000);
    assert!(system.saw_nonzero_samples);
    assert!(system.end_qpc > system.start_qpc);
    assert!(system.qpc_frequency > 0);
    assert!(system.first_packet_qpc.is_some());

    if let Some(microphone) = &stats.microphone {
        validate_wav(std::path::Path::new(&microphone.path));
        assert!(microphone.frames >= 48_000);
        assert!(microphone.end_qpc > microphone.start_qpc);
        assert_eq!(microphone.qpc_frequency, system.qpc_frequency);
    }

    std::fs::remove_dir_all(&output_dir).expect("remove audio test output");
}

#[test]
#[ignore = "requires Media Foundation; empty result is valid when no camera is installed"]
fn enumerates_video_capture_devices_without_mocking_absence() {
    let _guard = hardware_lock();
    let cameras = camera::enumerate_video_capture_devices().expect("camera enumeration");
    println!("Video capture diagnostics: {cameras:?}");
    for camera in &cameras {
        assert!(!camera.friendly_name.is_empty());
        assert!(!camera.symbolic_link.is_empty());
    }
}

fn validate_wav(path: &std::path::Path) {
    let bytes = std::fs::read(path).expect("wav file");
    assert!(bytes.starts_with(b"RIFF"), "RIFF header missing");
    assert_eq!(&bytes[8..12], b"WAVE");
    assert_eq!(&bytes[12..16], b"fmt ");
    let format = u16::from_le_bytes([bytes[20], bytes[21]]);
    let channels = u16::from_le_bytes([bytes[22], bytes[23]]);
    let rate = u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]);
    let bits = u16::from_le_bytes([bytes[34], bytes[35]]);
    assert_eq!(format, 1);
    assert_eq!(channels, 2);
    assert_eq!(rate, 48_000);
    assert_eq!(bits, 16);
    assert_eq!(&bytes[36..40], b"data");
    let data_len = u32::from_le_bytes([bytes[40], bytes[41], bytes[42], bytes[43]]) as usize;
    assert_eq!(data_len, bytes.len() - 44);
}
