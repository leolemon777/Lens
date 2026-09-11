//! Portable auto-edit, captions, and timeline rules (Mac LensCore subset).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LensPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraKeyframe {
    pub time: f64,
    pub scale: f64,
    pub center: LensPoint,
    pub easing: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionCue {
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptSegment {
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub text: String,
    pub confidence: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptDocument {
    pub schema_version: String,
    pub engine: String,
    pub generated_at: String,
    pub locale_identifier: String,
    pub is_on_device: bool,
    pub source_role: String,
    pub full_text: String,
    pub segments: Vec<TranscriptSegment>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoEditSegment {
    pub id: String,
    pub source_start_seconds: f64,
    pub source_end_seconds: f64,
    pub playback_rate: f64,
    pub is_enabled: bool,
    /// `cut` or `crossfade`. Empty means a hard cut.
    #[serde(default)]
    pub transition: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoEditTimeline {
    pub schema_version: String,
    pub segments: Vec<VideoEditSegment>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraPipConfig {
    #[serde(default = "default_true")]
    pub is_enabled: bool,
    /// "bottomRight", "bottomLeft", "topRight", "topLeft"
    #[serde(default = "default_bottom_right")]
    pub position: String,
    /// fraction of screen width, e.g. 0.22
    #[serde(default = "default_pip_scale")]
    pub scale: f64,
    /// "circle", "roundedRect"
    #[serde(default = "default_rounded_rect")]
    pub shape: String,
}

fn default_true() -> bool {
    true
}
fn default_bottom_right() -> String {
    "bottomRight".into()
}
fn default_pip_scale() -> f64 {
    0.22
}
fn default_rounded_rect() -> String {
    "roundedRect".into()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioEnhanceConfig {
    #[serde(default = "default_true")]
    pub ducking_enabled: bool,
    #[serde(default = "default_ducking_attenuation")]
    pub ducking_attenuation_db: f64,
    #[serde(default = "default_true")]
    pub normalize_enabled: bool,
}

fn default_ducking_attenuation() -> f64 {
    -12.0
}

impl Default for AudioEnhanceConfig {
    fn default() -> Self {
        Self {
            ducking_enabled: true,
            ducking_attenuation_db: -12.0,
            normalize_enabled: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraPlan {
    pub mode: String,
    pub zoom_scale: f64,
    pub keyframes: Vec<CameraKeyframe>,
    #[serde(default)]
    pub pip: Option<CameraPipConfig>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoEditPlan {
    pub schema_version: String,
    pub preset: String,
    pub camera: CameraPlan,
    pub captions: CaptionPlan,
    pub timeline: VideoEditTimeline,
    #[serde(default)]
    pub audio: Option<AudioEnhanceConfig>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionPlan {
    pub is_enabled: bool,
    pub max_characters_per_cue: usize,
    pub cues: Vec<CaptionCue>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InsightsDocument {
    pub schema_version: String,
    pub engine: String,
    pub suggested_title: String,
    pub summary: String,
    pub tags: Vec<String>,
}

/// Natural-mode auto camera: overview, a mid-shot focus, then return.
/// Click-driven focus is applied when `clicks` is non-empty (normalized 0..1).
pub fn plan_auto_camera(duration: f64, clicks: &[(f64, LensPoint)]) -> Vec<CameraKeyframe> {
    let duration = duration.max(0.1);
    let overview = LensPoint { x: 0.5, y: 0.5 };
    let mut keys = vec![CameraKeyframe {
        time: 0.0,
        scale: 1.0,
        center: overview,
        easing: "linear".into(),
        reason: "baseline".into(),
    }];
    if clicks.is_empty() {
        if duration >= 4.0 {
            keys.push(CameraKeyframe {
                time: (duration * 0.28).min(duration - 1.4).max(0.4),
                scale: 1.6,
                center: LensPoint { x: 0.5, y: 0.42 },
                easing: "easeInOut".into(),
                reason: "clickFocus".into(),
            });
            keys.push(CameraKeyframe {
                time: (duration - 0.95).max(keys.last().map(|k| k.time + 0.4).unwrap_or(1.0)),
                scale: 1.0,
                center: overview,
                easing: "easeInOut".into(),
                reason: "returnToOverview".into(),
            });
        }
        return keys;
    }
    for (index, (time, point)) in clicks.iter().enumerate() {
        let t = time.clamp(0.0, duration);
        let is_last = index + 1 == clicks.len();
        keys.push(CameraKeyframe {
            time: t,
            scale: 1.6,
            center: LensPoint {
                x: point.x.clamp(0.2, 0.8),
                y: point.y.clamp(0.2, 0.8),
            },
            easing: "easeInOut".into(),
            reason: "clickFocus".into(),
        });
        if is_last && duration - t >= 1.2 {
            keys.push(CameraKeyframe {
                time: (t + 1.15).min(duration),
                scale: 1.0,
                center: overview,
                easing: "easeInOut".into(),
                reason: "returnToOverview".into(),
            });
        }
    }
    keys
}

/// Interpolates camera scale and center at a given timestamp using easeInOut.
pub fn interpolate_camera(keyframes: &[CameraKeyframe], time: f64) -> (f64, LensPoint) {
    if keyframes.is_empty() {
        return (1.0, LensPoint { x: 0.5, y: 0.5 });
    }
    if time <= keyframes[0].time {
        return (keyframes[0].scale, keyframes[0].center);
    }
    if time >= keyframes.last().unwrap().time {
        let last = keyframes.last().unwrap();
        return (last.scale, last.center);
    }
    let mut prev = &keyframes[0];
    let mut next = &keyframes[0];
    for kf in keyframes {
        if kf.time <= time {
            prev = kf;
        } else {
            next = kf;
            break;
        }
    }
    let dt = (next.time - prev.time).max(0.001);
    let mut factor = ((time - prev.time) / dt).clamp(0.0, 1.0);
    if prev.easing == "easeInOut" || next.easing == "easeInOut" {
        factor = factor * factor * (3.0 - 2.0 * factor);
    }
    let scale = prev.scale + (next.scale - prev.scale) * factor;
    let center = LensPoint {
        x: prev.center.x + (next.center.x - prev.center.x) * factor,
        y: prev.center.y + (next.center.y - prev.center.y) * factor,
    };
    (scale, center)
}

/// Groups transcript segments into caption cues with a character budget.
pub fn plan_captions(segments: &[TranscriptSegment], max_chars: usize) -> Vec<CaptionCue> {
    let max_chars = max_chars.max(12);
    let mut cues = Vec::new();
    let mut buf = String::new();
    let mut start = 0.0;
    let mut end = 0.0;
    for segment in segments {
        if segment.text.trim().is_empty() {
            continue;
        }
        if buf.is_empty() {
            start = segment.start_seconds;
            buf = segment.text.clone();
            end = segment.end_seconds;
            continue;
        }
        let candidate = format!("{buf} {}", segment.text);
        if candidate.chars().count() > max_chars {
            cues.push(CaptionCue {
                start_seconds: start,
                end_seconds: end,
                text: buf.trim().to_string(),
            });
            start = segment.start_seconds;
            buf = segment.text.clone();
        } else {
            buf = candidate;
        }
        end = segment.end_seconds;
    }
    if !buf.trim().is_empty() {
        cues.push(CaptionCue {
            start_seconds: start,
            end_seconds: end,
            text: buf.trim().to_string(),
        });
    }
    cues
}

pub fn default_timeline(id: String, duration: f64) -> VideoEditTimeline {
    VideoEditTimeline {
        schema_version: "0.1".into(),
        segments: vec![VideoEditSegment {
            id,
            source_start_seconds: 0.0,
            source_end_seconds: duration.max(0.0),
            playback_rate: 1.0,
            is_enabled: true,
            transition: String::new(),
        }],
    }
}

pub fn output_duration(timeline: &VideoEditTimeline) -> f64 {
    timeline
        .segments
        .iter()
        .filter(|segment| segment.is_enabled)
        .map(|segment| {
            let source = (segment.source_end_seconds - segment.source_start_seconds).max(0.0);
            source / segment.playback_rate.max(0.25)
        })
        .sum()
}

pub fn make_auto_edit_plan(duration: f64, clicks: &[(f64, LensPoint)]) -> AutoEditPlan {
    let keyframes = plan_auto_camera(duration, clicks);
    AutoEditPlan {
        schema_version: "1.2".into(),
        preset: "natural".into(),
        camera: CameraPlan {
            mode: "event-driven".into(),
            zoom_scale: 1.6,
            keyframes,
            pip: Some(CameraPipConfig {
                is_enabled: true,
                position: "bottomRight".into(),
                scale: 0.22,
                shape: "roundedRect".into(),
            }),
        },
        captions: CaptionPlan {
            is_enabled: true,
            max_characters_per_cue: 42,
            cues: Vec::new(),
        },
        timeline: default_timeline("main".into(), duration),
        audio: Some(AudioEnhanceConfig::default()),
    }
}

pub fn organize_insights(title_hint: &str, transcript: &str, ocr: &str) -> InsightsDocument {
    let text = if !transcript.trim().is_empty() {
        transcript
    } else {
        ocr
    };
    let summary = text
        .chars()
        .take(140)
        .collect::<String>()
        .trim()
        .to_string();
    let tags = {
        let mut tags = Vec::new();
        if !transcript.is_empty() {
            tags.push("转写".into());
        }
        if !ocr.is_empty() {
            tags.push("OCR".into());
        }
        if tags.is_empty() {
            tags.push("录屏".into());
        }
        tags
    };
    InsightsDocument {
        schema_version: "0.2".into(),
        engine: "LensLocalOrganizer/0.1".into(),
        suggested_title: if title_hint.is_empty() {
            "Lens 记录".into()
        } else {
            title_hint.into()
        },
        summary,
        tags,
    }
}

/// Writes WebVTT from caption cues.
pub fn cues_to_vtt(cues: &[CaptionCue]) -> String {
    let mut out = String::from("WEBVTT\n\n");
    for (index, cue) in cues.iter().enumerate() {
        out.push_str(&format!(
            "{}\n{} --> {}\n{}\n\n",
            index + 1,
            vtt_timestamp(cue.start_seconds),
            vtt_timestamp(cue.end_seconds),
            cue.text
        ));
    }
    out
}

/// Parses a WebVTT produced by `cues_to_vtt`. Unknown cue shapes are skipped.
pub fn vtt_to_cues(vtt: &str) -> Vec<CaptionCue> {
    let mut cues = Vec::new();
    for block in vtt.split("\n\n") {
        let lines: Vec<&str> = block
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && *line != "WEBVTT")
            .collect();
        let Some(time_line) = lines.iter().find(|line| line.contains("-->")) else {
            continue;
        };
        let mut parts = time_line.split("-->");
        let start = parse_vtt_timestamp(parts.next().unwrap_or("").trim());
        let end = parse_vtt_timestamp(parts.next().unwrap_or("").trim());
        let text = lines
            .iter()
            .skip_while(|line| !line.contains("-->"))
            .skip(1)
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        if text.is_empty() {
            continue;
        }
        cues.push(CaptionCue {
            start_seconds: start,
            end_seconds: end,
            text,
        });
    }
    cues
}

fn parse_vtt_timestamp(value: &str) -> f64 {
    let parts: Vec<&str> = value.split(':').collect();
    match parts.as_slice() {
        [hours, minutes, seconds] => {
            hours.parse().unwrap_or(0.0) * 3600.0
                + minutes.parse().unwrap_or(0.0) * 60.0
                + seconds.parse().unwrap_or(0.0)
        }
        [minutes, seconds] => minutes.parse().unwrap_or(0.0) * 60.0 + seconds.parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

pub fn split_timeline(timeline: &VideoEditTimeline, at_seconds: f64) -> VideoEditTimeline {
    let mut segments = Vec::new();
    for segment in &timeline.segments {
        if !segment.is_enabled
            || at_seconds <= segment.source_start_seconds + 0.05
            || at_seconds >= segment.source_end_seconds - 0.05
        {
            segments.push(segment.clone());
            continue;
        }
        let mut left = segment.clone();
        left.id = format!("{}-a", segment.id);
        left.source_end_seconds = at_seconds;
        let mut right = segment.clone();
        right.id = format!("{}-b", segment.id);
        right.source_start_seconds = at_seconds;
        right.transition = "cut".into();
        segments.push(left);
        segments.push(right);
    }
    VideoEditTimeline {
        schema_version: timeline.schema_version.clone(),
        segments,
    }
}

fn vtt_timestamp(seconds: f64) -> String {
    let total_ms = (seconds.max(0.0) * 1000.0).round() as u64;
    let hours = total_ms / 3_600_000;
    let minutes = (total_ms / 60_000) % 60;
    let secs = (total_ms / 1000) % 60;
    let ms = total_ms % 1000;
    format!("{hours:02}:{minutes:02}:{secs:02}.{ms:03}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_camera_returns_to_overview_on_long_takes() {
        let keys = plan_auto_camera(12.0, &[]);
        assert_eq!(keys.first().unwrap().reason, "baseline");
        assert_eq!(keys.last().unwrap().reason, "returnToOverview");
        assert!(keys.last().unwrap().scale <= 1.01);
    }

    #[test]
    fn captions_respect_character_budget() {
        let segments = vec![
            TranscriptSegment {
                start_seconds: 0.0,
                end_seconds: 1.0,
                text: "hello".into(),
                confidence: 1.0,
            },
            TranscriptSegment {
                start_seconds: 1.0,
                end_seconds: 2.0,
                text: "world from the other side of the sentence".into(),
                confidence: 1.0,
            },
        ];
        let cues = plan_captions(&segments, 16);
        assert!(cues.len() >= 2);
        assert!(cues.iter().all(|cue| cue.text.chars().count() <= 48));
    }

    #[test]
    fn timeline_output_duration_scales_with_rate() {
        let timeline = VideoEditTimeline {
            schema_version: "0.1".into(),
            segments: vec![VideoEditSegment {
                id: "a".into(),
                source_start_seconds: 0.0,
                source_end_seconds: 10.0,
                playback_rate: 2.0,
                is_enabled: true,
                transition: String::new(),
            }],
        };
        assert!((output_duration(&timeline) - 5.0).abs() < 1e-9);
    }

    #[test]
    fn vtt_roundtrip_preserves_cue_text_and_times() {
        let original = vec![CaptionCue {
            start_seconds: 1.5,
            end_seconds: 3.25,
            text: "你好世界".into(),
        }];
        let parsed = vtt_to_cues(&cues_to_vtt(&original));
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].text, "你好世界");
        assert!((parsed[0].start_seconds - 1.5).abs() < 0.002);
        assert!((parsed[0].end_seconds - 3.25).abs() < 0.002);
    }

    #[test]
    fn split_timeline_keeps_both_halves_enabled() {
        let timeline = default_timeline("main".into(), 10.0);
        let split = split_timeline(&timeline, 4.0);
        assert_eq!(split.segments.len(), 2);
        assert_eq!(split.segments[0].source_end_seconds, 4.0);
        assert_eq!(split.segments[1].source_start_seconds, 4.0);
    }

    #[test]
    fn camera_interpolation_smoothly_transitions() {
        let keyframes = vec![
            CameraKeyframe {
                time: 0.0,
                scale: 1.0,
                center: LensPoint { x: 0.5, y: 0.5 },
                easing: "linear".into(),
                reason: "overview".into(),
            },
            CameraKeyframe {
                time: 2.0,
                scale: 2.0,
                center: LensPoint { x: 0.8, y: 0.2 },
                easing: "easeInOut".into(),
                reason: "focus".into(),
            },
        ];
        let (s0, c0) = interpolate_camera(&keyframes, 0.0);
        assert_eq!(s0, 1.0);
        assert_eq!(c0.x, 0.5);

        let (s_mid, c_mid) = interpolate_camera(&keyframes, 1.0);
        // At mid-point of smoothstep, value should be exactly midway: 1.5, x=0.65
        assert!((s_mid - 1.5).abs() < 1e-6);
        assert!((c_mid.x - 0.65).abs() < 1e-6);
        assert!((c_mid.y - 0.35).abs() < 1e-6);

        let (s2, c2) = interpolate_camera(&keyframes, 2.5);
        assert_eq!(s2, 2.0);
        assert_eq!(c2.x, 0.8);
    }
}
