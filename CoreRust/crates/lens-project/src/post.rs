//! Post-record ffmpeg helpers: concat, mix, recovery playlist, timeline export.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::ProjectError;
use lens_core::edit::{AudioEnhanceConfig, CameraKeyframe, CameraPipConfig, CameraPlan};

#[derive(Debug, Clone, Default)]
pub struct MixOptions<'a> {
    pub pip: Option<&'a CameraPipConfig>,
    pub camera_plan: Option<&'a CameraPlan>,
    pub audio_config: Option<&'a AudioEnhanceConfig>,
}

pub fn find_tool(name: &str) -> PathBuf {
    let binary_name = if cfg!(windows) && !name.ends_with(".exe") {
        format!("{name}.exe")
    } else {
        name.to_string()
    };

    let env_var = format!("LENS_{}_PATH", name.to_ascii_uppercase());
    if let Ok(val) = std::env::var(&env_var) {
        let p = PathBuf::from(val);
        if p.is_file() {
            return p;
        }
    }

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidates = [
                dir.join(&binary_name),
                dir.join("bin").join(&binary_name),
                dir.join("tools").join(&binary_name),
                dir.join("resources").join(&binary_name),
                dir.join("resources").join("bin").join(&binary_name),
            ];
            for c in candidates {
                if c.is_file() {
                    return c;
                }
            }
        }
    }

    PathBuf::from(name)
}

fn ffmpeg() -> Command {
    let mut command = Command::new(find_tool("ffmpeg"));
    command.args(["-hide_banner", "-loglevel", "error", "-nostdin"]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
}

fn ffprobe() -> Command {
    let mut command = Command::new(find_tool("ffprobe"));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
}

pub fn video_dimensions(path: &Path) -> Result<(u32, u32), ProjectError> {
    let result = ffprobe()
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=p=0:s=x",
        ])
        .arg(path)
        .output()?;
    let text = String::from_utf8_lossy(&result.stdout);
    let parts: Vec<&str> = text.trim().split('x').collect();
    if result.status.success() && parts.len() == 2 {
        if let (Ok(w), Ok(h)) = (parts[0].parse::<u32>(), parts[1].parse::<u32>()) {
            if w > 0 && h > 0 {
                return Ok((w, h));
            }
        }
    }
    Err(ProjectError::Manifest(
        "cannot determine video dimensions".into(),
    ))
}

pub fn run_ffmpeg(command: &mut Command) -> Result<(), ProjectError> {
    let result = command.output()?;
    if !result.status.success() {
        return Err(ProjectError::Manifest(format!(
            "FFmpeg failed: {}",
            String::from_utf8_lossy(&result.stderr)
        )));
    }
    Ok(())
}

/// Verifies that the first video stream can be decoded from beginning to end.
/// A successful container probe is not sufficient: truncated/corrupt MP4 files
/// can still advertise a duration while failing once their packets are read.
pub fn verify_video_decodable(path: &Path) -> Result<(), ProjectError> {
    if !path.is_file() || fs::metadata(path)?.len() == 0 {
        return Err(ProjectError::Manifest(format!(
            "missing or empty video: {}",
            path.display()
        )));
    }
    video_dimensions(path)?;
    let duration = ffprobe_duration(path).ok_or_else(|| {
        ProjectError::Manifest(format!(
            "cannot determine video duration: {}",
            path.display()
        ))
    })?;
    if !duration.is_finite() || duration <= 0.05 {
        return Err(ProjectError::Manifest(format!(
            "video duration is invalid: {}",
            path.display()
        )));
    }

    let result = ffmpeg()
        .args(["-v", "error", "-xerror", "-i"])
        .arg(path)
        .args(["-map", "0:v:0", "-an", "-f", "null", "-"])
        .output()?;
    if !result.status.success() {
        return Err(ProjectError::Manifest(format!(
            "video decode failed for {}: {}",
            path.display(),
            String::from_utf8_lossy(&result.stderr).trim()
        )));
    }
    Ok(())
}

pub fn concat_segments(
    segment_dir: &Path,
    files: &[String],
    output: &Path,
) -> Result<PathBuf, ProjectError> {
    if files.is_empty() {
        return Err(ProjectError::Manifest("no segments to concat".into()));
    }
    for file in files {
        let path = segment_dir.join(file);
        if !path.is_file() || fs::metadata(&path)?.len() == 0 {
            return Err(ProjectError::Manifest(format!(
                "missing or empty segment: {}",
                path.display()
            )));
        }
    }
    if files.len() == 1 {
        let src = segment_dir.join(&files[0]);
        if let Some(parent) = output.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&src, output)?;
        return Ok(output.to_path_buf());
    }
    let list = segment_dir.join("concat.txt");
    let mut body = String::new();
    for file in files {
        body.push_str(&format!(
            "file '{}'\n",
            file.replace('\\', "/").replace('\'', "'\\''")
        ));
    }
    fs::write(&list, body)?;
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    run_ffmpeg(
        ffmpeg()
            .args(["-y", "-f", "concat", "-safe", "0", "-i"])
            .arg(&list)
            .args(["-c", "copy"])
            .arg(output),
    )?;
    Ok(output.to_path_buf())
}

pub fn build_camera_zoompan_filter(
    keyframes: &[CameraKeyframe],
    width: u32,
    height: u32,
    fps: f64,
) -> Option<String> {
    if keyframes.is_empty() {
        return None;
    }
    let has_effective_zoom = keyframes.iter().any(|k| (k.scale - 1.0).abs() > 0.01);
    if !has_effective_zoom {
        return None;
    }

    let mut sorted = keyframes.to_vec();
    sorted.sort_by(|a, b| {
        a.time
            .partial_cmp(&b.time)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    fn build_expr<F>(keyframes: &[CameraKeyframe], val_extractor: F) -> String
    where
        F: Fn(&CameraKeyframe) -> f64,
    {
        let n = keyframes.len();
        if n == 1 {
            return format!("{:.4}", val_extractor(&keyframes[0]));
        }
        let mut expr = format!("{:.4}", val_extractor(&keyframes[n - 1]));
        for i in (0..n - 1).rev() {
            let kf1 = &keyframes[i];
            let kf2 = &keyframes[i + 1];
            let v1 = val_extractor(kf1);
            let v2 = val_extractor(kf2);
            let dt = (kf2.time - kf1.time).max(0.001);
            let t1 = kf1.time;
            let ease = kf1.easing == "easeInOut" || kf2.easing == "easeInOut";
            let norm_t = format!("min(1,max(0,(time-{t1:.3})/{dt:.3}))");
            let interp = if ease {
                let s = format!("({norm_t}*{norm_t}*(3-2*{norm_t}))");
                format!("({v1:.4}+({v2:.4}-{v1:.4})*{s})")
            } else {
                format!("({v1:.4}+({v2:.4}-{v1:.4})*{norm_t})")
            };
            expr = format!(
                "if(lte(time,{t1:.3}),{v1:.4},if(lte(time,{:.3}),{interp},{expr}))",
                kf2.time
            );
        }
        expr
    }

    let z_expr = build_expr(&sorted, |k| k.scale.clamp(1.0, 5.0));
    let cx_expr = build_expr(&sorted, |k| k.center.x.clamp(0.05, 0.95));
    let cy_expr = build_expr(&sorted, |k| k.center.y.clamp(0.05, 0.95));

    let fps = if fps > 0.0 && fps.is_finite() {
        fps
    } else {
        30.0
    };
    Some(format!(
        "zoompan=z='{z_expr}':x='max(0,min(iw-iw/zoom,({cx_expr})*iw-(iw/zoom/2)))':y='max(0,min(ih-ih/zoom,({cy_expr})*ih-(ih/zoom/2)))':d=1:s={width}x{height}:fps={fps:.2}"
    ))
}

pub fn mix_audio_and_pip_ext(
    video: &Path,
    system: Option<&Path>,
    mic: Option<&Path>,
    camera: Option<&Path>,
    options: &MixOptions,
    output: &Path,
) -> Result<PathBuf, ProjectError> {
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    for path in [system, mic, camera].into_iter().flatten() {
        if !path.is_file() {
            return Err(ProjectError::Manifest(format!(
                "missing media track: {}",
                path.display()
            )));
        }
    }

    let video_has_audio = has_audio(video).unwrap_or(false);

    let mut cmd = ffmpeg();
    cmd.arg("-y").arg("-i").arg(video);

    let mut next_input_idx = 1;
    let system_idx = if let Some(path) = system {
        cmd.arg("-i").arg(path);
        let idx = next_input_idx;
        next_input_idx += 1;
        Some(idx)
    } else {
        None
    };

    let mic_idx = if let Some(path) = mic {
        cmd.arg("-i").arg(path);
        let idx = next_input_idx;
        next_input_idx += 1;
        Some(idx)
    } else {
        None
    };

    let camera_idx = if let Some(path) = camera {
        cmd.arg("-i").arg(path);
        Some(next_input_idx)
    } else {
        None
    };

    let mut filter_complex = Vec::new();

    // 1. Camera zoompan filter on main screen video
    let mut v_filter_in = "0:v".to_string();
    let mut v_mapped = "0:v".to_string();
    let mut has_video_filtering = false;

    if let Some(cam_plan) = options.camera_plan {
        let is_disabled = cam_plan.mode.trim().is_empty()
            || cam_plan.mode.eq_ignore_ascii_case("off")
            || cam_plan.mode.eq_ignore_ascii_case("none")
            || cam_plan.mode.eq_ignore_ascii_case("disabled");
        if !is_disabled && !cam_plan.keyframes.is_empty() {
            if let Ok((width, height)) = video_dimensions(video) {
                let fps = video_fps(video).unwrap_or(30.0);
                if let Some(zoom_filter) =
                    build_camera_zoompan_filter(&cam_plan.keyframes, width, height, fps)
                {
                    filter_complex.push(format!("[0:v]{zoom_filter}[v_zoomed]"));
                    v_filter_in = "v_zoomed".to_string();
                    v_mapped = "[v_zoomed]".to_string();
                    has_video_filtering = true;
                }
            }
        }
    }

    // 2. Picture-in-picture overlay
    let pip_config = options.pip;
    let has_pip = camera_idx.is_some() && pip_config.map(|c| c.is_enabled).unwrap_or(true);
    let v_out = if has_pip {
        let cam_i = camera_idx.unwrap();
        let scale = pip_config.map(|c| c.scale).unwrap_or(0.22).clamp(0.1, 0.5);
        let pos = pip_config
            .map(|c| c.position.as_str())
            .unwrap_or("bottomRight");
        let (overlay_x, overlay_y) = match pos {
            "bottomLeft" => ("24", "H-h-24"),
            "topRight" => ("W-w-24", "24"),
            "topLeft" => ("24", "24"),
            _ => ("W-w-24", "H-h-24"),
        };
        filter_complex.push(format!("[{cam_i}:v]scale=iw*{scale:.3}:-1[cam_scaled]"));
        filter_complex.push(format!(
            "[{v_filter_in}][cam_scaled]overlay={overlay_x}:{overlay_y}[v_pip]"
        ));
        has_video_filtering = true;
        "[v_pip]".to_string()
    } else {
        v_mapped
    };

    // 3. Audio handling with Ducking and Normalization
    enum SysAudioSource {
        External(usize),
        Embedded,
        None,
    }
    let sys_source = if let Some(idx) = system_idx {
        SysAudioSource::External(idx)
    } else if video_has_audio {
        SysAudioSource::Embedded
    } else {
        SysAudioSource::None
    };

    let audio_cfg = options.audio_config;
    let ducking_enabled = audio_cfg.map(|a| a.ducking_enabled).unwrap_or(true);
    let ducking_attenuation_db = audio_cfg.map(|a| a.ducking_attenuation_db).unwrap_or(-12.0);
    let normalize_enabled = audio_cfg.map(|a| a.normalize_enabled).unwrap_or(true);

    let norm_single = if normalize_enabled { "dynaudnorm," } else { "" };
    let norm_suffix = if normalize_enabled { ",dynaudnorm" } else { "" };

    let a_out: Option<String> = match (sys_source, mic_idx) {
        (SysAudioSource::None, None) => None,
        (SysAudioSource::External(s_idx), None) => {
            filter_complex.push(format!("[{s_idx}:a]{norm_single}apad[a_single]"));
            Some("[a_single]".to_string())
        }
        (SysAudioSource::Embedded, None) => {
            if has_video_filtering || normalize_enabled {
                filter_complex.push(format!("[0:a:0]{norm_single}apad[a_single]"));
                Some("[a_single]".to_string())
            } else {
                Some("0:a:0".to_string())
            }
        }
        (SysAudioSource::None, Some(m_idx)) => {
            filter_complex.push(format!("[{m_idx}:a]{norm_single}apad[a_single]"));
            Some("[a_single]".to_string())
        }
        (SysAudioSource::External(s_idx), Some(m_idx)) => {
            let sys_ref = format!("{s_idx}:a");
            let mic_ref = format!("{m_idx}:a");
            if ducking_enabled {
                let ratio = (ducking_attenuation_db.abs() / 2.0).clamp(2.0, 16.0);
                filter_complex.push(format!(
                    "[{mic_ref}]apad,asplit=2[m_sidechain][m_audible];\
                     [{sys_ref}]apad[s_padded];\
                     [s_padded][m_sidechain]sidechaincompress=threshold=0.06:ratio={ratio:.1}:attack=20:release=350[ducked_sys];\
                     [m_audible]volume=1.25[m_a];\
                     [ducked_sys][m_a]amix=inputs=2:duration=longest{norm_suffix},apad[a_mixed]"
                ));
            } else {
                filter_complex.push(format!(
                    "[{sys_ref}]volume=0.9[s_a];[{mic_ref}]volume=1.25[m_a];\
                     [s_a][m_a]amix=inputs=2:duration=longest{norm_suffix},apad[a_mixed]"
                ));
            }
            Some("[a_mixed]".to_string())
        }
        (SysAudioSource::Embedded, Some(m_idx)) => {
            let sys_ref = "0:a:0".to_string();
            let mic_ref = format!("{m_idx}:a");
            if ducking_enabled {
                let ratio = (ducking_attenuation_db.abs() / 2.0).clamp(2.0, 16.0);
                filter_complex.push(format!(
                    "[{mic_ref}]apad,asplit=2[m_sidechain][m_audible];\
                     [{sys_ref}]apad[s_padded];\
                     [s_padded][m_sidechain]sidechaincompress=threshold=0.06:ratio={ratio:.1}:attack=20:release=350[ducked_sys];\
                     [m_audible]volume=1.25[m_a];\
                     [ducked_sys][m_a]amix=inputs=2:duration=longest{norm_suffix},apad[a_mixed]"
                ));
            } else {
                filter_complex.push(format!(
                    "[{sys_ref}]volume=0.9[s_a];[{mic_ref}]volume=1.25[m_a];\
                     [s_a][m_a]amix=inputs=2:duration=longest{norm_suffix},apad[a_mixed]"
                ));
            }
            Some("[a_mixed]".to_string())
        }
    };

    if !filter_complex.is_empty() {
        cmd.args(["-filter_complex", &filter_complex.join(";")]);
        cmd.args(["-map", &v_out]);
        if let Some(ref a) = a_out {
            cmd.args(["-map", a]);
        }
        if has_video_filtering {
            cmd.args(["-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p"]);
        } else {
            cmd.args(["-c:v", "copy"]);
        }
        if a_out.is_some() {
            cmd.args(["-c:a", "aac"]);
        }
    } else {
        cmd.args(["-map", "0:v", "-c:v", "copy"]);
        if let Some(ref a) = a_out {
            cmd.args(["-map", a, "-c:a", "copy"]);
        }
    }

    let duration = ffprobe_duration(video).ok_or_else(|| {
        ProjectError::Manifest("cannot read screen duration for audio mix".into())
    })?;
    cmd.arg("-t").arg(format!("{duration:.6}"));
    cmd.arg(output);
    run_ffmpeg(&mut cmd)?;
    Ok(output.to_path_buf())
}

pub fn mix_audio_and_pip(
    video: &Path,
    system: Option<&Path>,
    mic: Option<&Path>,
    camera: Option<&Path>,
    pip_config: Option<&lens_core::edit::CameraPipConfig>,
    output: &Path,
) -> Result<PathBuf, ProjectError> {
    mix_audio_and_pip_ext(
        video,
        system,
        mic,
        camera,
        &MixOptions {
            pip: pip_config,
            camera_plan: None,
            audio_config: None,
        },
        output,
    )
}

pub fn mix_audio(
    video: &Path,
    system: Option<&Path>,
    mic: Option<&Path>,
    output: &Path,
) -> Result<PathBuf, ProjectError> {
    mix_audio_and_pip(video, system, mic, None, None, output)
}

pub fn export_timeline(
    source: &Path,
    start: f64,
    duration: f64,
    rate: f64,
    vtt: Option<&Path>,
    output: &Path,
) -> Result<PathBuf, ProjectError> {
    if !start.is_finite()
        || start < 0.0
        || !duration.is_finite()
        || duration <= 0.0
        || !rate.is_finite()
        || !(0.5..=3.0).contains(&rate)
    {
        return Err(ProjectError::Manifest(
            "invalid timeline range or playback rate".into(),
        ));
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut cmd = ffmpeg();
    cmd.arg("-y")
        .arg("-ss")
        .arg(format!("{start:.3}"))
        .arg("-t")
        .arg(format!("{duration:.3}"))
        .arg("-i")
        .arg(source);
    let mut filters = vec![format!("setpts=(PTS-STARTPTS)/{rate}")];
    if let Some(vtt) = vtt.filter(|path| path.exists()) {
        let escaped = vtt.to_string_lossy().replace('\\', "/").replace(':', "\\:");
        filters.push(format!("subtitles='{escaped}'"));
    }
    cmd.args(["-map", "0:v:0", "-map", "0:a:0?"]);
    cmd.arg("-vf").arg(filters.join(","));
    if has_audio(source)? {
        let tempo = if rate > 2.0 {
            format!("atempo=2,atempo={}", rate / 2.0)
        } else {
            format!("atempo={rate}")
        };
        cmd.arg("-af").arg(format!("asetpts=PTS-STARTPTS,{tempo}"));
    }
    // Re-encode even a cut at 1x so trims are frame accurate and parts share codecs.
    cmd.args([
        "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac",
    ]);
    cmd.arg(output);
    run_ffmpeg(&mut cmd)?;
    Ok(output.to_path_buf())
}

pub fn write_concat_recovery(
    segment_dir: &Path,
    recoverable: &[String],
    output: &Path,
) -> Result<PathBuf, ProjectError> {
    concat_segments(segment_dir, recoverable, output)
}

#[derive(Debug, Clone)]
pub struct ConcatClip {
    pub file: String,
    pub duration: f64,
    pub transition: String,
}

pub fn concat_clips(
    dir: &Path,
    clips: &[ConcatClip],
    output: &Path,
) -> Result<PathBuf, ProjectError> {
    if clips.is_empty() {
        return Err(ProjectError::Manifest("no clips to concat".into()));
    }
    let needs_xfade = clips.len() > 1
        && clips
            .iter()
            .skip(1)
            .any(|clip| clip.transition.eq_ignore_ascii_case("crossfade"));
    if needs_xfade {
        concat_xfade(dir, clips, output)
    } else {
        let files: Vec<String> = clips.iter().map(|clip| clip.file.clone()).collect();
        concat_segments(dir, &files, output)
    }
}

/// Builds the ffmpeg xfade/acrossfade graph. Fade is 0.3s, clamped to the shorter clip.
pub fn xfade_filter_graph(clips: &[ConcatClip], fade: f64) -> String {
    transition_graph(clips, fade, true, 30.0)
}

fn transition_graph(clips: &[ConcatClip], fade: f64, with_audio: bool, fps: f64) -> String {
    let fade = fade.max(0.05);
    let mut video = clips
        .iter()
        .enumerate()
        .map(|(index, _)| {
            format!("[{index}:v]fps={fps},settb=AVTB,setpts=PTS-STARTPTS[basev{index}]")
        })
        .collect::<Vec<_>>()
        .join(";");
    let mut audio = String::new();
    let mut running = clips[0].duration.max(fade + 0.05);
    let mut last_v = "basev0".to_string();
    let mut last_a = "0:a".to_string();
    for (index, clip) in clips.iter().enumerate().skip(1) {
        let this_fade = fade.min(running * 0.45).min(clip.duration.max(0.1) * 0.45);
        let offset = (running - this_fade).max(0.0);
        let v_out = format!("v{index}");
        let a_out = format!("a{index}");
        if !video.is_empty() {
            video.push(';');
            if !audio.is_empty() {
                audio.push(';');
            }
        }
        if clip.transition.eq_ignore_ascii_case("crossfade") {
            video.push_str(&format!(
            "[{last_v}][basev{index}]xfade=transition=fade:duration={this_fade:.3}:offset={offset:.3},fps={fps},settb=AVTB,setpts=PTS-STARTPTS[{v_out}]"
        ));
            audio.push_str(&format!(
                "[{last_a}][{index}:a]acrossfade=d={this_fade:.3}[{a_out}]"
            ));
            running += clip.duration.max(0.1) - this_fade;
        } else {
            video.push_str(&format!("[{last_v}][basev{index}]concat=n=2:v=1:a=0,fps={fps},settb=AVTB,setpts=PTS-STARTPTS[{v_out}]"));
            audio.push_str(&format!("[{last_a}][{index}:a]concat=n=2:v=0:a=1[{a_out}]"));
            running += clip.duration.max(0.1);
        }
        last_v = v_out;
        last_a = a_out;
    }
    if with_audio {
        format!("{video};{audio}")
    } else {
        video
    }
}

fn concat_xfade(dir: &Path, clips: &[ConcatClip], output: &Path) -> Result<PathBuf, ProjectError> {
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let with_audio = has_audio(&dir.join(&clips[0].file))?;
    let fps = video_fps(&dir.join(&clips[0].file))?;
    let graph = transition_graph(clips, 0.3, with_audio, fps);
    let last = clips.len() - 1;
    let mut cmd = ffmpeg();
    cmd.arg("-y");
    for clip in clips {
        cmd.arg("-i").arg(dir.join(&clip.file));
    }
    cmd.args([
        "-filter_complex",
        &graph,
        "-map",
        &format!("[v{last}]"),
        "-c:v",
        "libx264",
        "-c:a",
        "aac",
    ]);
    if with_audio {
        cmd.args(["-map", &format!("[a{last}]")]);
    }
    cmd.arg(output);
    run_ffmpeg(&mut cmd)?;
    Ok(output.to_path_buf())
}

pub fn has_audio(path: &Path) -> Result<bool, ProjectError> {
    let result = ffprobe()
        .args([
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=index",
            "-of",
            "csv=p=0",
        ])
        .arg(path)
        .output()?;
    if !result.status.success() {
        return Err(ProjectError::Manifest(format!(
            "ffprobe failed: {}",
            String::from_utf8_lossy(&result.stderr)
        )));
    }
    Ok(!result.stdout.is_empty())
}

fn video_fps(path: &Path) -> Result<f64, ProjectError> {
    let result = ffprobe()
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=r_frame_rate",
            "-of",
            "csv=p=0",
        ])
        .arg(path)
        .output()?;
    let text = String::from_utf8_lossy(&result.stdout);
    let values: Vec<_> = text
        .trim()
        .split('/')
        .filter_map(|value| value.parse::<f64>().ok())
        .collect();
    if result.status.success() && values.len() == 2 && values[1] > 0.0 {
        let fps = values[0] / values[1];
        if fps.is_finite() && fps > 0.0 {
            return Ok(fps);
        }
    }
    Err(ProjectError::Manifest(
        "cannot determine source frame rate".into(),
    ))
}

pub fn export_preset(source: &Path, preset: &str, output: &Path) -> Result<PathBuf, ProjectError> {
    let mut cmd = ffmpeg();
    cmd.args(["-y", "-i"])
        .arg(source)
        .args(["-map", "0:v:0", "-map", "0:a:0?"]);
    match preset {
        "original" => {
            cmd.args(["-c", "copy"]);
        }
        "balanced" => {
            cmd.args([
                "-vf",
                "fps=fps='min(source_fps,30)'",
                "-c:v",
                "libx264",
                "-crf",
                "23",
                "-c:a",
                "aac",
            ]);
        }
        "light" | "lightweight" => {
            cmd.args([
                "-vf",
                "fps=fps='min(source_fps,24)'",
                "-c:v",
                "libx265",
                "-crf",
                "28",
                "-tag:v",
                "hvc1",
                "-c:a",
                "aac",
            ]);
        }
        _ => return Err(ProjectError::Manifest("unknown export preset".into())),
    }
    cmd.args(["-movflags", "+faststart"]).arg(output);
    run_ffmpeg(&mut cmd)?;
    Ok(output.to_path_buf())
}

/// Reads duration via ffprobe. Never writes or rewrites `path`.
pub fn ffprobe_duration(path: &Path) -> Option<f64> {
    let output = ffprobe()
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout).trim().parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xfade_graph_chains_two_clips() {
        let clips = vec![
            ConcatClip {
                file: "a.mp4".into(),
                duration: 10.0,
                transition: "cut".into(),
            },
            ConcatClip {
                file: "b.mp4".into(),
                duration: 8.0,
                transition: "crossfade".into(),
            },
        ];
        let graph = xfade_filter_graph(&clips, 0.3);
        assert!(graph.contains("xfade=transition=fade"));
        assert!(graph.contains("acrossfade"));
        assert!(graph.contains("[basev0][basev1]"));
        assert!(graph.contains("[v1]"));
    }
}
