//! Real FFmpeg regressions. Run explicitly; never require a user's captured media.
use lens_core::edit::{VideoEditSegment, VideoEditTimeline};
use lens_project::{post, render};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

struct Fixture {
    root: PathBuf,
    original: Vec<(PathBuf, Vec<u8>)>,
}
impl Fixture {
    fn new(audio: bool) -> Self {
        let base = std::env::var_os("LENS_MEDIA_EVIDENCE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let root = base.join(format!("lens-media-{}.lens", lens_project::new_uuid()));
        fs::create_dir_all(root.join("raw/segments")).unwrap();
        fs::create_dir_all(root.join("analysis")).unwrap();
        fs::create_dir_all(root.join("edits")).unwrap();
        // Disk names deliberately disagree with the authoritative manifest order.
        for (file, color) in [("z-first.mp4", "red"), ("a-second.mp4", "blue")] {
            ffmpeg(
                &[
                    "-f",
                    "lavfi",
                    "-i",
                    &format!("color=c={color}:s=320x180:r=30:d=2"),
                    "-c:v",
                    "libx264",
                    "-pix_fmt",
                    "yuv420p",
                ],
                &root.join("raw/segments").join(file),
            );
        }
        if audio {
            ffmpeg(
                &[
                    "-f",
                    "lavfi",
                    "-i",
                    "sine=frequency=440:sample_rate=48000:duration=4",
                    "-c:a",
                    "pcm_s16le",
                ],
                &root.join("raw/system-loopback.wav"),
            );
        }
        lens_project::finalize_recording_package(
            &root,
            &lens_project::new_uuid(),
            320,
            180,
            4.0,
            &["z-first.mp4".into(), "a-second.mp4".into()],
            audio,
            false,
        )
        .unwrap();
        let mut original = Vec::new();
        for name in ["raw/segments/z-first.mp4", "raw/segments/a-second.mp4"] {
            let path = root.join(name);
            original.push((path.clone(), fs::read(path).unwrap()));
        }
        Self { root, original }
    }
    fn assert_raw_unchanged(&self) {
        for (path, bytes) in &self.original {
            assert_eq!(&fs::read(path).unwrap(), bytes);
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if std::env::var_os("LENS_MEDIA_EVIDENCE_DIR").is_none() {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
fn ffmpeg(args: &[&str], output: &Path) {
    let result = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-y"])
        .args(args)
        .arg(output)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
}
fn streams(path: &Path) -> serde_json::Value {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-show_streams", "-of", "json"])
        .arg(path)
        .output()
        .unwrap();
    assert!(out.status.success());
    serde_json::from_slice(&out.stdout).unwrap()
}
fn frame(path: &Path, at: f64) -> Vec<u8> {
    let out = Command::new("ffmpeg")
        .args(["-v", "error", "-ss", &at.to_string(), "-i"])
        .arg(path)
        .args([
            "-frames:v",
            "1",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "pipe:1",
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(out.stdout.len(), 320 * 180 * 3);
    out.stdout
}
fn pixel_at(frame_bytes: &[u8], width: usize, x: usize, y: usize) -> (u8, u8, u8) {
    let offset = (y * width + x) * 3;
    (
        frame_bytes[offset],
        frame_bytes[offset + 1],
        frame_bytes[offset + 2],
    )
}
fn audio_rms_segment(path: &Path, start_sec: f64, duration_sec: f64) -> f64 {
    let out = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-ss",
            &start_sec.to_string(),
            "-t",
            &duration_sec.to_string(),
            "-i",
        ])
        .arg(path)
        .args(["-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"])
        .output()
        .unwrap();
    if !out.status.success() || out.stdout.is_empty() {
        return 0.0;
    }
    let pcm = &out.stdout;
    let mut sum_sq = 0.0;
    let mut count = 0;
    for chunk in pcm.chunks_exact(2) {
        let sample = i16::from_le_bytes([chunk[0], chunk[1]]) as f64;
        sum_sq += sample * sample;
        count += 1;
    }
    if count == 0 {
        0.0
    } else {
        (sum_sq / count as f64).sqrt()
    }
}
fn audio_band_rms_segment(path: &Path, frequency: u32, start_sec: f64, duration_sec: f64) -> f64 {
    let filter = format!("bandpass=f={frequency}:width_type=h:width=60");
    let out = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-ss",
            &start_sec.to_string(),
            "-t",
            &duration_sec.to_string(),
            "-i",
        ])
        .arg(path)
        .args([
            "-af", &filter, "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1",
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let samples = out
        .stdout
        .chunks_exact(2)
        .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]) as f64);
    let (sum, count) = samples.fold((0.0, 0_u64), |(sum, count), sample| {
        (sum + sample * sample, count + 1)
    });
    if count == 0 {
        0.0
    } else {
        (sum / count as f64).sqrt()
    }
}
fn audio_band_rms(path: &Path, frequency: u32) -> f64 {
    audio_band_rms_segment(path, frequency, 0.0, 60.0)
}
fn segment(id: &str, start: f64, end: f64, rate: f64, transition: &str) -> VideoEditSegment {
    VideoEditSegment {
        id: id.into(),
        source_start_seconds: start,
        source_end_seconds: end,
        playback_rate: rate,
        is_enabled: true,
        transition: transition.into(),
    }
}
fn timeline(segments: Vec<VideoEditSegment>) -> VideoEditTimeline {
    VideoEditTimeline {
        schema_version: "0.1".into(),
        segments,
    }
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe with H.264, HEVC and subtitle filters"]
fn full_export_preserves_manifest_order_and_all_frames() {
    let fixture = Fixture::new(true);
    let output = render::export_package(&fixture.root, "original").unwrap();
    let duration = post::ffprobe_duration(&output).unwrap();
    assert!((duration - 4.0).abs() < 0.15, "duration={duration}");
    let first = frame(&output, 0.5);
    let second = frame(&output, 2.5);
    assert!(first[0] > 200 && first[2] < 30);
    assert!(second[2] > 200 && second[0] < 30);
    assert!(post::has_audio(&output).unwrap());
    // Failed new render must preserve the existing complete export.
    let previous = fs::read(&output).unwrap();
    fs::write(
        fixture.root.join("edits/timeline.json"),
        serde_json::to_vec(&timeline(vec![segment("bad", 0.0, 10.0, 1.0, "cut")])).unwrap(),
    )
    .unwrap();
    assert!(render::export_package(&fixture.root, "original").is_err());
    assert_eq!(fs::read(&output).unwrap(), previous);
    fixture.assert_raw_unchanged();
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn retiming_keeps_audio_and_video_durations_aligned() {
    let fixture = Fixture::new(true);
    for rate in [0.5, 1.0, 3.0] {
        let edit = timeline(vec![segment("speed", 0.5, 3.5, rate, "cut")]);
        let output = render::render_package(&fixture.root, &edit).unwrap();
        let probe = streams(&output);
        let mut durations = Vec::new();
        for stream in probe["streams"].as_array().unwrap() {
            let duration = stream["duration"].as_str().unwrap().parse::<f64>().unwrap();
            assert!(
                (duration - 3.0 / rate).abs() < 0.15,
                "rate={rate}, stream={stream}"
            );
            durations.push(duration);
        }
        assert_eq!(durations.len(), 2);
        assert!((durations[0] - durations[1]).abs() < 0.12, "{durations:?}");
    }
    fixture.assert_raw_unchanged();
}

#[test]
#[ignore = "requires local ffmpeg with libass"]
fn reordered_clips_burn_captions_on_both_parts() {
    let fixture = Fixture::new(false);
    fs::write(
        fixture.root.join("analysis/captions.vtt"),
        "WEBVTT\n\n00:00:00.000 --> 00:00:01.900\nFIRST\n\n00:00:02.000 --> 00:00:03.900\nSECOND\n",
    )
    .unwrap();
    let edit = timeline(vec![
        segment("second", 2.0, 4.0, 1.0, "cut"),
        segment("first", 0.0, 2.0, 1.0, "cut"),
    ]);
    fs::write(
        fixture.root.join("edits/timeline.json"),
        serde_json::to_vec(&edit).unwrap(),
    )
    .unwrap();
    let output = render::export_package(&fixture.root, "original").unwrap();
    for time in [0.5, 2.5] {
        let pixels = frame(&output, time);
        let white = pixels
            .chunks_exact(3)
            .filter(|p| p[0] > 170 && p[1] > 170 && p[2] > 170)
            .count();
        assert!(white > 20, "missing burned caption at {time}: {white}");
        if time < 2.0 {
            assert!(pixels[2] > 200);
        } else {
            assert!(pixels[0] > 200);
        }
    }
    fixture.assert_raw_unchanged();
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn mixed_cut_and_crossfade_work_with_and_without_audio() {
    for audio in [false, true] {
        let fixture = Fixture::new(audio);
        for (middle, last) in [("crossfade", "cut"), ("cut", "crossfade")] {
            let edit = timeline(vec![
                segment("a", 0.0, 1.0, 1.0, "cut"),
                segment("b", 2.0, 3.0, 1.0, middle),
                segment("c", 0.0, 1.0, 1.0, last),
            ]);
            let output = render::render_package(&fixture.root, &edit).unwrap();
            let duration = post::ffprobe_duration(&output).unwrap();
            assert!((duration - 2.7).abs() < 0.15, "duration={duration}");
            assert_eq!(post::has_audio(&output).unwrap(), audio);
        }
    }
}

#[test]
#[ignore = "requires local ffmpeg with H.264 and HEVC encoders"]
fn presets_preserve_dimensions_and_apply_codec_and_fps_caps() {
    let fixture = Fixture::new(false);
    for (preset, codec, max_fps) in [("balanced", "h264", 30.0), ("light", "hevc", 24.0)] {
        let output = render::export_package(&fixture.root, preset).unwrap();
        let probe = streams(&output);
        let video = &probe["streams"][0];
        assert_eq!(video["width"], 320);
        assert_eq!(video["height"], 180);
        assert_eq!(video["codec_name"], codec);
        let fraction: Vec<f64> = video["avg_frame_rate"]
            .as_str()
            .unwrap()
            .split('/')
            .map(|n| n.parse().unwrap())
            .collect();
        assert!(fraction[0] / fraction[1] <= max_fps + 0.01);
    }
}

#[test]
#[ignore = "requires local ffmpeg"]
fn concat_and_mix_failure_are_errors_not_first_segment_fallbacks() {
    let fixture = Fixture::new(false);
    let job = fixture.root.join("previews");
    fs::create_dir_all(&job).unwrap();
    fs::write(job.join("corrupt.mp4"), b"not a video").unwrap();
    assert!(post::concat_segments(
        &job,
        &["corrupt.mp4".into(), "missing.mp4".into()],
        &job.join("concat.mp4")
    )
    .is_err());
    assert!(post::mix_audio(
        &fixture.root.join("raw/segments/z-first.mp4"),
        Some(&job.join("corrupt.mp4")),
        None,
        &job.join("mixed.mp4")
    )
    .is_err());
    assert!(post::concat_segments(
        &fixture.root.join("raw/segments"),
        &["z-first.mp4".into(), "missing.mp4".into()],
        &job.join("missing-tail.mp4")
    )
    .is_err());
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn short_and_long_audio_never_change_screen_duration() {
    let fixture = Fixture::new(true);
    for duration in [1, 6] {
        ffmpeg(
            &[
                "-f",
                "lavfi",
                "-i",
                &format!("sine=frequency=440:sample_rate=48000:duration={duration}"),
                "-c:a",
                "pcm_s16le",
            ],
            &fixture.root.join("raw/system-loopback.wav"),
        );
        let output = render::export_package(&fixture.root, "original").unwrap();
        let probe = streams(&output);
        for stream in probe["streams"].as_array().unwrap() {
            let actual: f64 = stream["duration"].as_str().unwrap().parse().unwrap();
            assert!(
                (actual - 4.0).abs() < 0.12,
                "input audio={duration}, output={actual}"
            );
        }
        assert!(frame(&output, 3.8)[2] > 200);
    }
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn camera_pip_and_ducked_audio_are_synthesized_into_render() {
    let fixture = Fixture::new(true);
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=green:s=160x120:r=30:d=4",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ],
        &fixture.root.join("raw/camera.mp4"),
    );
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=880:sample_rate=48000:duration=4",
            "-c:a",
            "pcm_s16le",
        ],
        &fixture.root.join("raw/microphone.wav"),
    );
    lens_project::finalize_recording_package_full(
        &fixture.root,
        &lens_project::new_uuid(),
        320,
        180,
        4.0,
        &["z-first.mp4".into(), "a-second.mp4".into()],
        true,
        true,
        true,
        None,
    )
    .unwrap();

    let timeline = VideoEditTimeline {
        schema_version: "0.1".into(),
        segments: vec![segment("s1", 0.0, 4.0, 1.0, "cut")],
    };
    let output = render::render_package(&fixture.root, &timeline).unwrap();
    assert!(output.is_file());

    let probe = streams(&output);
    let s_arr = probe["streams"].as_array().unwrap();
    let has_video = s_arr.iter().any(|s| s["codec_type"] == "video");
    let has_audio = s_arr.iter().any(|s| s["codec_type"] == "audio");
    assert!(has_video, "rendered package must have video stream");
    assert!(has_audio, "rendered package must have audio stream");

    // Verify picture-in-picture visual placement by pixel inspection
    // At t=0.5s: main screen is red, camera is green.
    let f05 = frame(&output, 0.5);
    let lt = pixel_at(&f05, 320, 30, 30);
    assert!(
        lt.0 > 180 && lt.1 < 50 && lt.2 < 50,
        "left-top should be main screen red, got {lt:?}"
    );
    let rb = pixel_at(&f05, 320, 320 - 24 - 15, 180 - 24 - 10);
    assert!(
        rb.1 > 100 && rb.0 < 50 && rb.2 < 50,
        "right-bottom should be camera green PiP, got {rb:?}"
    );

    // At t=2.5s: main screen is blue, camera is green.
    let f25 = frame(&output, 2.5);
    let lt2 = pixel_at(&f25, 320, 30, 30);
    assert!(
        lt2.2 > 180 && lt2.0 < 50 && lt2.1 < 50,
        "left-top should be main screen blue, got {lt2:?}"
    );
    let rb2 = pixel_at(&f25, 320, 320 - 24 - 15, 180 - 24 - 10);
    assert!(
        rb2.1 > 100 && rb2.0 < 50 && rb2.2 < 50,
        "right-bottom should remain camera green PiP, got {rb2:?}"
    );

    fixture.assert_raw_unchanged();
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn camera_zoompan_keyframes_affect_rendered_pixels() {
    let temp = std::env::temp_dir().join(format!("lens_test_zoom_{}", lens_project::new_uuid()));
    fs::create_dir_all(&temp).unwrap();
    let video = temp.join("split_color.mp4");
    let output = temp.join("zoomed_output.mp4");
    let disabled_output = temp.join("zoom_disabled_output.mp4");

    // Left half (0..160) is red, right half (160..320) is blue
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=red:s=160x180:r=30:d=3",
            "-f",
            "lavfi",
            "-i",
            "color=c=blue:s=160x180:r=30:d=3",
            "-filter_complex",
            "[0:v][1:v]hstack[v]",
            "-map",
            "[v]",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ],
        &video,
    );

    // Zoom to left half at t=1.5s with scale=2.5, center=(0.25, 0.5)
    let cam_plan = lens_core::edit::CameraPlan {
        mode: "auto".into(),
        zoom_scale: 2.5,
        keyframes: vec![
            lens_core::edit::CameraKeyframe {
                time: 0.0,
                scale: 1.0,
                center: lens_core::edit::LensPoint { x: 0.5, y: 0.5 },
                easing: "easeInOut".into(),
                reason: "initial".into(),
            },
            lens_core::edit::CameraKeyframe {
                time: 1.5,
                scale: 2.5,
                center: lens_core::edit::LensPoint { x: 0.25, y: 0.5 },
                easing: "easeInOut".into(),
                reason: "focus_left".into(),
            },
            lens_core::edit::CameraKeyframe {
                time: 2.8,
                scale: 1.0,
                center: lens_core::edit::LensPoint { x: 0.5, y: 0.5 },
                easing: "easeInOut".into(),
                reason: "return".into(),
            },
        ],
        pip: None,
    };

    let options = post::MixOptions {
        pip: None,
        camera_plan: Some(&cam_plan),
        audio_config: None,
    };
    post::mix_audio_and_pip_ext(&video, None, None, None, &options, &output).unwrap();
    assert!(output.is_file());

    // At t=0.5s: before zoom, right side (240, 90) must be blue
    let f05 = frame(&output, 0.5);
    let right05 = pixel_at(&f05, 320, 240, 90);
    assert!(
        right05.2 > 180 && right05.0 < 50,
        "t=0.5 right side should be blue, got {right05:?}"
    );

    // At t=1.5s: zoomed in 2.5x into left half (red). Center and right must now be red!
    let f15 = frame(&output, 1.5);
    let center15 = pixel_at(&f15, 320, 160, 90);
    assert!(
        center15.0 > 180 && center15.2 < 50,
        "t=1.5 center should be zoomed red, got {center15:?}"
    );
    let right15 = pixel_at(&f15, 320, 240, 90);
    assert!(
        right15.0 > 180 && right15.2 < 50,
        "t=1.5 right should also be zoomed red, got {right15:?}"
    );

    // At t=2.9s: returned to 1.0x, right side must be blue again
    let f29 = frame(&output, 2.9);
    let right29 = pixel_at(&f29, 320, 240, 90);
    assert!(
        right29.2 > 180 && right29.0 < 50,
        "t=2.9 right side should return to blue, got {right29:?}"
    );

    let mut disabled_plan = cam_plan.clone();
    disabled_plan.mode = "off".into();
    let disabled_options = post::MixOptions {
        pip: None,
        camera_plan: Some(&disabled_plan),
        audio_config: None,
    };
    post::mix_audio_and_pip_ext(
        &video,
        None,
        None,
        None,
        &disabled_options,
        &disabled_output,
    )
    .unwrap();
    let disabled = frame(&disabled_output, 1.5);
    let disabled_right = pixel_at(&disabled, 320, 240, 90);
    assert!(
        disabled_right.2 > 180 && disabled_right.0 < 50,
        "camera.mode=off must preserve the full blue right half, got {disabled_right:?}"
    );

    let _ = fs::remove_dir_all(&temp);
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn camera_mode_toggle_preserves_keyframes_and_controls_render_pipeline() {
    let temp =
        std::env::temp_dir().join(format!("lens_test_cam_toggle_{}", lens_project::new_uuid()));
    fs::create_dir_all(&temp).unwrap();
    let package = temp.join("test.lens");
    fs::create_dir_all(package.join("raw")).unwrap();
    fs::create_dir_all(package.join("edits")).unwrap();
    fs::create_dir_all(package.join("previews")).unwrap();

    let source = package.join("raw/screen.mp4");
    // Split video: left 160x180 red, right 160x180 blue (total 320x180)
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=red:s=160x180:r=30:d=2",
            "-f",
            "lavfi",
            "-i",
            "color=c=blue:s=160x180:r=30:d=2",
            "-filter_complex",
            "[0:v][1:v]hstack[v]",
            "-map",
            "[v]",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ],
        &source,
    );

    let raw_bytes = fs::read(&source).unwrap();

    let manifest = serde_json::json!({
        "schemaVersion": "0.9",
        "id": lens_project::new_uuid(),
        "kind": "recording",
        "createdAt": "2026-09-11T00:00:00Z",
        "title": "Camera toggle test",
        "state": "ready",
        "durationSeconds": 2.0,
        "assets": [
            { "role": "screenVideo", "relativePath": "raw/screen.mp4" }
        ]
    });
    fs::write(
        package.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();

    let timeline = lens_core::edit::VideoEditTimeline {
        schema_version: "0.1".into(),
        segments: vec![lens_core::edit::VideoEditSegment {
            id: "one".into(),
            source_start_seconds: 0.0,
            source_end_seconds: 2.0,
            playback_rate: 1.0,
            is_enabled: true,
            transition: "cut".into(),
        }],
    };

    let keyframes = vec![lens_core::edit::CameraKeyframe {
        time: 0.0,
        scale: 2.5,
        center: lens_core::edit::LensPoint { x: 0.25, y: 0.5 },
        easing: "easeInOut".into(),
        reason: "test".into(),
    }];

    // 1. Mode: "event-driven" -> Zoomed in on left red area
    let plan_on = lens_core::edit::AutoEditPlan {
        schema_version: "1.2".into(),
        preset: "natural".into(),
        camera: lens_core::edit::CameraPlan {
            mode: "event-driven".into(),
            zoom_scale: 2.5,
            keyframes: keyframes.clone(),
            pip: None,
        },
        captions: lens_core::edit::CaptionPlan {
            is_enabled: false,
            max_characters_per_cue: 42,
            cues: vec![],
        },
        timeline: timeline.clone(),
        audio: None,
    };
    fs::write(
        package.join("edits/edit-plan.json"),
        serde_json::to_vec_pretty(&plan_on).unwrap(),
    )
    .unwrap();

    let out1 = lens_project::render::render_package(&package, &timeline).unwrap();
    let f1 = frame(&out1, 0.5);
    let right1 = pixel_at(&f1, 320, 240, 90);
    assert!(
        right1.0 > 180 && right1.2 < 50,
        "mode='event-driven' must zoom into red half, got {right1:?}"
    );

    // 2. Mode: "off" -> Preserves keyframes in edit-plan.json, but outputs unzoomed full field of view
    let mut plan_off = plan_on.clone();
    plan_off.camera.mode = "off".into();
    fs::write(
        package.join("edits/edit-plan.json"),
        serde_json::to_vec_pretty(&plan_off).unwrap(),
    )
    .unwrap();

    let out2 = lens_project::render::render_package(&package, &timeline).unwrap();
    let f2 = frame(&out2, 0.5);
    let right2 = pixel_at(&f2, 320, 240, 90);
    assert!(
        right2.2 > 180 && right2.0 < 50,
        "mode='off' must restore full field of view (blue on right half), got {right2:?}"
    );

    // Verify keyframes were preserved in the plan
    let saved_plan: lens_core::edit::AutoEditPlan =
        serde_json::from_slice(&fs::read(package.join("edits/edit-plan.json")).unwrap()).unwrap();
    assert_eq!(
        saved_plan.camera.keyframes.len(),
        1,
        "keyframes must be retained in plan"
    );

    // 3. Re-enable mode: "event-driven" -> Zoom effect restored immediately using preserved keyframes
    let mut plan_re_on = plan_off.clone();
    plan_re_on.camera.mode = "event-driven".into();
    fs::write(
        package.join("edits/edit-plan.json"),
        serde_json::to_vec_pretty(&plan_re_on).unwrap(),
    )
    .unwrap();

    let out3 = lens_project::render::render_package(&package, &timeline).unwrap();
    let f3 = frame(&out3, 0.5);
    let right3 = pixel_at(&f3, 320, 240, 90);
    assert!(
        right3.0 > 180 && right3.2 < 50,
        "re-enabling camera mode must immediately restore zoom, got {right3:?}"
    );

    // 4. Verify raw video file was never modified or overwritten
    assert_eq!(
        fs::read(&source).unwrap(),
        raw_bytes,
        "raw screen video must be untouched"
    );

    let _ = fs::remove_dir_all(&temp);
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn sidechain_ducking_attenuates_system_audio_during_speech() {
    let temp = std::env::temp_dir().join(format!("lens_test_duck_{}", lens_project::new_uuid()));
    fs::create_dir_all(&temp).unwrap();
    let video = temp.join("video.mp4");
    let sys_audio = temp.join("system.wav");
    let mic_audio = temp.join("mic.wav");
    let out_ducked = temp.join("ducked.mp4");
    let out_noduck = temp.join("noduck.mp4");
    let out_weak = temp.join("ducked-weak.mp4");

    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x180:r=30:d=4",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ],
        &video,
    );
    // Constant 440Hz system tone
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000:duration=4",
            "-c:a",
            "pcm_s16le",
        ],
        &sys_audio,
    );
    // Mic active between 1.0s and 2.5s only
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=880:sample_rate=48000:duration=1.5",
            "-filter_complex",
            "[0:a]adelay=1000|1000,apad=whole_dur=4[out]",
            "-map",
            "[out]",
            "-c:a",
            "pcm_s16le",
        ],
        &mic_audio,
    );

    let opt_ducked = post::MixOptions {
        pip: None,
        camera_plan: None,
        audio_config: Some(&lens_core::edit::AudioEnhanceConfig {
            ducking_enabled: true,
            ducking_attenuation_db: -12.0,
            normalize_enabled: false,
        }),
    };
    let opt_noduck = post::MixOptions {
        pip: None,
        camera_plan: None,
        audio_config: Some(&lens_core::edit::AudioEnhanceConfig {
            ducking_enabled: false,
            ducking_attenuation_db: -12.0,
            normalize_enabled: false,
        }),
    };
    let opt_weak = post::MixOptions {
        pip: None,
        camera_plan: None,
        audio_config: Some(&lens_core::edit::AudioEnhanceConfig {
            ducking_enabled: true,
            ducking_attenuation_db: -6.0,
            normalize_enabled: false,
        }),
    };

    post::mix_audio_and_pip_ext(
        &video,
        Some(&sys_audio),
        Some(&mic_audio),
        None,
        &opt_ducked,
        &out_ducked,
    )
    .unwrap();
    post::mix_audio_and_pip_ext(
        &video,
        Some(&sys_audio),
        Some(&mic_audio),
        None,
        &opt_weak,
        &out_weak,
    )
    .unwrap();
    post::mix_audio_and_pip_ext(
        &video,
        Some(&sys_audio),
        Some(&mic_audio),
        None,
        &opt_noduck,
        &out_noduck,
    )
    .unwrap();

    // In silent section (t=0.2 to 0.8), both ducked and noduck should have virtually identical RMS
    let rms_silent_ducked = audio_rms_segment(&out_ducked, 0.2, 0.6);
    let rms_silent_noduck = audio_rms_segment(&out_noduck, 0.2, 0.6);
    assert!(
        (rms_silent_ducked - rms_silent_noduck).abs() / rms_silent_noduck < 0.15,
        "silent section RMS should match: ducked={rms_silent_ducked}, noduck={rms_silent_noduck}"
    );

    // Measure the 440 Hz system component directly from product outputs. The
    // 880 Hz microphone is rejected by the narrow band-pass measurement.
    let before_ducked = audio_band_rms_segment(&out_ducked, 440, 0.2, 0.6);
    let during_ducked = audio_band_rms_segment(&out_ducked, 440, 1.3, 0.8);
    let after_ducked = audio_band_rms_segment(&out_ducked, 440, 3.2, 0.6);
    let during_noduck = audio_band_rms_segment(&out_noduck, 440, 1.3, 0.8);
    let during_weak = audio_band_rms_segment(&out_weak, 440, 1.3, 0.8);
    assert!(
        during_ducked < during_noduck * 0.72,
        "product output must duck system tone during speech: ducked={during_ducked}, off={during_noduck}"
    );
    assert!(
        during_ducked < during_weak * 0.9,
        "stronger attenuation must reduce more: strong={during_ducked}, weak={during_weak}"
    );
    assert!(
        after_ducked > during_ducked * 1.5 && before_ducked > during_ducked * 1.5,
        "system tone must recover outside speech: before={before_ducked}, during={during_ducked}, after={after_ducked}"
    );

    let _ = fs::remove_dir_all(&temp);
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn sidechain_ducking_attenuates_system_audio_in_rendered_and_exported_package() {
    let temp =
        std::env::temp_dir().join(format!("lens_test_duck_pkg_{}", lens_project::new_uuid()));
    fs::create_dir_all(&temp).unwrap();
    let package = temp.join("duck_test.lens");
    fs::create_dir_all(package.join("raw")).unwrap();
    fs::create_dir_all(package.join("edits")).unwrap();
    fs::create_dir_all(package.join("previews")).unwrap();

    let video = package.join("raw/screen.mp4");
    let sys_audio = package.join("raw/system-loopback.wav");
    let mic_audio = package.join("raw/microphone.wav");

    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x180:r=30:d=4",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ],
        &video,
    );
    // Constant 440Hz system tone
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000:duration=4",
            "-c:a",
            "pcm_s16le",
        ],
        &sys_audio,
    );
    // Mic 880Hz active between 1.0s and 2.5s only
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=880:sample_rate=48000:duration=1.5",
            "-filter_complex",
            "[0:a]adelay=1000|1000,apad=whole_dur=4[out]",
            "-map",
            "[out]",
            "-c:a",
            "pcm_s16le",
        ],
        &mic_audio,
    );

    let manifest = serde_json::json!({
        "schemaVersion": "0.9",
        "id": lens_project::new_uuid(),
        "kind": "recording",
        "createdAt": "2026-09-11T00:00:00Z",
        "title": "Ducking package test",
        "state": "ready",
        "durationSeconds": 4.0,
        "assets": [
            { "role": "screenVideo", "relativePath": "raw/screen.mp4" },
            { "role": "systemAudio", "relativePath": "raw/system-loopback.wav" },
            { "role": "microphone", "relativePath": "raw/microphone.wav" }
        ]
    });
    fs::write(
        package.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();

    let timeline = lens_core::edit::VideoEditTimeline {
        schema_version: "0.1".into(),
        segments: vec![lens_core::edit::VideoEditSegment {
            id: "one".into(),
            source_start_seconds: 0.0,
            source_end_seconds: 4.0,
            playback_rate: 1.0,
            is_enabled: true,
            transition: "cut".into(),
        }],
    };

    // 1. Ducking enabled: -12dB attenuation, normalize disabled for crisp measurement
    let plan_ducked = lens_core::edit::AutoEditPlan {
        schema_version: "1.2".into(),
        preset: "natural".into(),
        camera: lens_core::edit::CameraPlan {
            mode: "off".into(),
            zoom_scale: 1.0,
            keyframes: vec![],
            pip: None,
        },
        captions: lens_core::edit::CaptionPlan {
            is_enabled: false,
            max_characters_per_cue: 42,
            cues: vec![],
        },
        timeline: timeline.clone(),
        audio: Some(lens_core::edit::AudioEnhanceConfig {
            ducking_enabled: true,
            ducking_attenuation_db: -12.0,
            normalize_enabled: false,
        }),
    };
    fs::write(
        package.join("edits/edit-plan.json"),
        serde_json::to_vec_pretty(&plan_ducked).unwrap(),
    )
    .unwrap();

    // Render package
    let rendered_mp4 = lens_project::render::render_package(&package, &timeline).unwrap();
    let before_ducked = audio_band_rms_segment(&rendered_mp4, 440, 0.2, 0.6);
    let during_ducked = audio_band_rms_segment(&rendered_mp4, 440, 1.3, 0.8);
    let after_ducked = audio_band_rms_segment(&rendered_mp4, 440, 3.2, 0.6);

    assert!(
        during_ducked < before_ducked * 0.72,
        "rendered package output must duck 440Hz system tone during speech: during={during_ducked}, before={before_ducked}"
    );
    assert!(
        after_ducked > during_ducked * 1.4,
        "rendered package output must recover after speech ends: during={during_ducked}, after={after_ducked}"
    );

    // Export package
    let exported_mp4 = lens_project::render::export_package(&package, "original").unwrap();
    let before_exported = audio_band_rms_segment(&exported_mp4, 440, 0.2, 0.6);
    let during_exported = audio_band_rms_segment(&exported_mp4, 440, 1.3, 0.8);
    assert!(
        during_exported < before_exported * 0.72,
        "exported package output must duck system tone during speech: during={during_exported}, before={before_exported}"
    );

    // 2. Ducking disabled in plan
    let mut plan_noduck = plan_ducked.clone();
    plan_noduck.audio = Some(lens_core::edit::AudioEnhanceConfig {
        ducking_enabled: false,
        ducking_attenuation_db: -12.0,
        normalize_enabled: false,
    });
    fs::write(
        package.join("edits/edit-plan.json"),
        serde_json::to_vec_pretty(&plan_noduck).unwrap(),
    )
    .unwrap();

    let rendered_noduck = lens_project::render::render_package(&package, &timeline).unwrap();
    let before_noduck = audio_band_rms_segment(&rendered_noduck, 440, 0.2, 0.6);
    let during_noduck = audio_band_rms_segment(&rendered_noduck, 440, 1.3, 0.8);

    assert!(
        (during_noduck - before_noduck).abs() / before_noduck < 0.15,
        "when ducking is disabled in plan, system tone must not be attenuated during speech: during={during_noduck}, before={before_noduck}"
    );

    let _ = fs::remove_dir_all(&temp);
}

fn audio_has_sound(path: &Path) -> bool {
    let out = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"])
        .output()
        .unwrap();
    if !out.status.success() || out.stdout.is_empty() {
        return false;
    }
    let pcm = &out.stdout;
    let mut non_zero = 0;
    for chunk in pcm.chunks_exact(2) {
        let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
        if sample.abs() > 100 {
            non_zero += 1;
        }
    }
    non_zero > 100
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn mix_audio_and_pip_preserves_embedded_audio_without_sidecars() {
    let temp = std::env::temp_dir().join(format!("lens_test_embed_{}", lens_project::new_uuid()));
    fs::create_dir_all(&temp).unwrap();
    let video = temp.join("video_with_audio.mp4");
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=320x180:rate=30",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000",
            "-c:v",
            "libx264",
            "-c:a",
            "aac",
            "-t",
            "3",
        ],
        &video,
    );
    assert!(post::has_audio(&video).unwrap());
    assert!(audio_has_sound(&video));

    let output = temp.join("out_embedded.mp4");
    post::mix_audio_and_pip(&video, None, None, None, None, &output).unwrap();
    assert!(output.is_file());
    assert!(
        post::has_audio(&output).unwrap(),
        "embedded audio must be preserved"
    );
    assert!(
        audio_has_sound(&output),
        "embedded audio must contain audible non-silent content"
    );

    let dur_v = post::ffprobe_duration(&video).unwrap();
    let dur_o = post::ffprobe_duration(&output).unwrap();
    assert!(
        (dur_o - dur_v).abs() < 0.15,
        "output duration must match input"
    );

    let _ = fs::remove_dir_all(&temp);
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn mix_audio_and_pip_mixes_embedded_audio_with_microphone() {
    let temp =
        std::env::temp_dir().join(format!("lens_test_embed_mic_{}", lens_project::new_uuid()));
    fs::create_dir_all(&temp).unwrap();
    let video = temp.join("video_with_audio.mp4");
    let mic = temp.join("mic.wav");
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x180:r=30:d=3",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000:duration=3",
            "-c:v",
            "libx264",
            "-c:a",
            "aac",
        ],
        &video,
    );
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=880:sample_rate=48000:duration=3",
            "-c:a",
            "pcm_s16le",
        ],
        &mic,
    );

    let output = temp.join("out_mixed.mp4");
    post::mix_audio_and_pip(&video, None, Some(&mic), None, None, &output).unwrap();
    assert!(output.is_file());
    assert!(post::has_audio(&output).unwrap());
    assert!(
        audio_has_sound(&output),
        "mixed audio must contain audible content"
    );
    assert!(
        audio_band_rms(&output, 440) > 100.0,
        "embedded 440 Hz content was lost"
    );
    assert!(
        audio_band_rms(&output, 880) > 100.0,
        "microphone 880 Hz content was lost"
    );

    let dur_o = post::ffprobe_duration(&output).unwrap();
    assert!((dur_o - 3.0).abs() < 0.15);

    let _ = fs::remove_dir_all(&temp);
}

#[test]
#[ignore = "requires local ffmpeg/ffprobe"]
fn mix_audio_and_pip_preserves_embedded_audio_when_camera_pip_enabled() {
    let temp =
        std::env::temp_dir().join(format!("lens_test_embed_pip_{}", lens_project::new_uuid()));
    fs::create_dir_all(&temp).unwrap();
    let video = temp.join("video_with_audio.mp4");
    let camera = temp.join("camera.mp4");
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=red:s=320x180:r=30:d=3",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000:duration=3",
            "-c:v",
            "libx264",
            "-c:a",
            "aac",
        ],
        &video,
    );
    ffmpeg(
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=blue:s=160x120:r=30:d=3",
            "-c:v",
            "libx264",
        ],
        &camera,
    );

    let pip_cfg = lens_core::edit::CameraPipConfig {
        is_enabled: true,
        position: "bottomRight".into(),
        scale: 0.25,
        shape: "roundedRect".into(),
    };

    let output = temp.join("out_pip.mp4");
    post::mix_audio_and_pip(&video, None, None, Some(&camera), Some(&pip_cfg), &output).unwrap();
    assert!(output.is_file());
    assert!(
        post::has_audio(&output).unwrap(),
        "audio must not be lost when pip is enabled"
    );
    assert!(audio_has_sound(&output), "output audio must be audible");

    let dur_o = post::ffprobe_duration(&output).unwrap();
    assert!((dur_o - 3.0).abs() < 0.15);

    let _ = fs::remove_dir_all(&temp);
}
