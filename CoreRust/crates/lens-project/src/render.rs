//! One package-to-movie path for edited previews and final exports.

use crate::{new_uuid, post, ProjectError};
use lens_core::{
    edit::{cues_to_vtt, vtt_to_cues, CaptionCue, VideoEditTimeline},
    manifest::LensManifest,
    project::resolve_within_root,
};
use std::{
    fs,
    path::{Path, PathBuf},
};

struct RenderJob(PathBuf);
impl RenderJob {
    fn new(root: &Path) -> Result<Self, ProjectError> {
        let dir = root.join("previews").join(format!("render-{}", new_uuid()));
        fs::create_dir_all(&dir)?;
        Ok(Self(dir))
    }

    fn for_task(root: &Path, task_id: &str) -> Result<Self, ProjectError> {
        let dir = task_workspace(root, task_id)?;
        if dir.exists() {
            fs::remove_dir_all(&dir)?;
        }
        fs::create_dir_all(&dir)?;
        Ok(Self(dir))
    }
}
impl Drop for RenderJob {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn task_workspace(root: &Path, task_id: &str) -> Result<PathBuf, ProjectError> {
    if task_id.is_empty()
        || task_id.len() > 128
        || !task_id
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'-' | b'_' | b'.'))
    {
        return Err(ProjectError::Manifest("invalid render task id".into()));
    }
    Ok(root.join("previews").join(format!("render-{task_id}")))
}

pub fn cleanup_task_workspace(root: &Path, task_id: &str) -> Result<(), ProjectError> {
    let dir = task_workspace(root, task_id)?;
    if dir.is_dir() {
        fs::remove_dir_all(dir)?;
    }
    Ok(())
}

fn asset(root: &Path, relative: &str) -> Result<PathBuf, ProjectError> {
    resolve_within_root(root, relative)
        .map_err(|e| ProjectError::Manifest(format!("missing or unsafe asset {relative}: {e}")))
}

/// Always reconstruct from original assets; old cached previews may be incomplete.
fn prepare_source(root: &Path, job: &Path) -> Result<PathBuf, ProjectError> {
    let manifest: LensManifest = serde_json::from_slice(&fs::read(root.join("manifest.json"))?)?;
    manifest
        .validate()
        .map_err(|e| ProjectError::Manifest(e.to_string()))?;
    let parts: Vec<_> = manifest
        .assets
        .iter()
        .filter(|a| a.role == "screenVideoSegment")
        .collect();
    let screen = if parts.is_empty() {
        let video = manifest
            .assets
            .iter()
            .find(|a| a.role == "screenVideo")
            .ok_or_else(|| ProjectError::Manifest("no screen video in manifest".into()))?;
        asset(root, &video.relative_path)?
    } else {
        let paths = parts
            .iter()
            .map(|a| {
                asset(root, &a.relative_path).map(|p| p.to_string_lossy().replace("\\\\?\\", ""))
            })
            .collect::<Result<Vec<_>, _>>()?;
        post::concat_segments(job, &paths, &job.join("screen.mp4"))?
    };
    let track = |role: &str| -> Result<Option<PathBuf>, ProjectError> {
        manifest
            .assets
            .iter()
            .find(|a| a.role == role)
            .map(|a| asset(root, &a.relative_path))
            .transpose()
    };
    let system = track("systemAudio")?;
    let mic = track("microphone")?;
    let camera = track("camera")?;
    let plan = load_auto_edit_plan(root)?;
    let mix_options = post::MixOptions {
        pip: plan.as_ref().and_then(|p| p.camera.pip.as_ref()),
        camera_plan: plan.as_ref().map(|p| &p.camera),
        audio_config: plan.as_ref().and_then(|p| p.audio.as_ref()),
    };
    post::mix_audio_and_pip_ext(
        &screen,
        system.as_deref(),
        mic.as_deref(),
        camera.as_deref(),
        &mix_options,
        &job.join("program.mp4"),
    )
}

pub fn load_auto_edit_plan(
    root: &Path,
) -> Result<Option<lens_core::edit::AutoEditPlan>, ProjectError> {
    let plan = root.join("edits/edit-plan.json");
    if plan.exists() {
        let value: serde_json::Value = serde_json::from_slice(&fs::read(plan)?)?;
        if let Ok(loaded) = serde_json::from_value(value) {
            return Ok(Some(loaded));
        }
    }
    Ok(None)
}

pub fn load_timeline(root: &Path) -> Result<Option<VideoEditTimeline>, ProjectError> {
    let timeline = root.join("edits/timeline.json");
    if timeline.exists() {
        return Ok(Some(serde_json::from_slice(&fs::read(timeline)?)?));
    }
    let plan = root.join("edits/edit-plan.json");
    if plan.exists() {
        let value: serde_json::Value = serde_json::from_slice(&fs::read(plan)?)?;
        if let Some(timeline) = value.get("timeline") {
            return Ok(Some(serde_json::from_value(timeline.clone())?));
        }
    }
    Ok(None)
}

pub fn captions_for_segment(
    cues: &[CaptionCue],
    start: f64,
    end: f64,
    rate: f64,
) -> Vec<CaptionCue> {
    cues.iter()
        .filter_map(|cue| {
            let left = cue.start_seconds.max(start);
            let right = cue.end_seconds.min(end);
            (left < right && !cue.text.trim().is_empty()).then(|| CaptionCue {
                start_seconds: (left - start) / rate,
                end_seconds: (right - start) / rate,
                text: cue.text.clone(),
            })
        })
        .collect()
}

fn render_in_job(
    root: &Path,
    job: &Path,
    timeline: Option<&VideoEditTimeline>,
) -> Result<PathBuf, ProjectError> {
    let source = prepare_source(root, job)?;
    let Some(timeline) = timeline else {
        return Ok(source);
    };
    let edited = root.join("edits/captions.vtt");
    let caption_path = if edited.exists() {
        edited
    } else {
        root.join("analysis/captions.vtt")
    };
    let cues = if caption_path.exists() {
        vtt_to_cues(&fs::read_to_string(caption_path)?)
    } else {
        vec![]
    };
    let source_duration = post::ffprobe_duration(&source)
        .ok_or_else(|| ProjectError::Manifest("cannot read source duration".into()))?;
    let mut clips = Vec::new();
    for (index, segment) in timeline
        .segments
        .iter()
        .filter(|s| s.is_enabled)
        .enumerate()
    {
        let start = segment.source_start_seconds;
        let end = segment.source_end_seconds;
        let rate = segment.playback_rate;
        if !start.is_finite()
            || !end.is_finite()
            || !rate.is_finite()
            || start < 0.0
            || end <= start
            || end > source_duration + 0.15
            || !(0.5..=3.0).contains(&rate)
            || !matches!(segment.transition.as_str(), "" | "cut" | "crossfade")
        {
            return Err(ProjectError::Manifest(format!(
                "invalid timeline segment {}",
                segment.id
            )));
        }
        let end = end.min(source_duration);
        let mapped = captions_for_segment(&cues, start, end, rate);
        let vtt = job.join(format!("captions-{index}.vtt"));
        if !mapped.is_empty() {
            fs::write(&vtt, cues_to_vtt(&mapped))?;
        }
        let file = format!("part-{index}.mp4");
        post::export_timeline(
            &source,
            start,
            end - start,
            rate,
            (!mapped.is_empty()).then_some(vtt.as_path()),
            &job.join(&file),
        )?;
        clips.push(post::ConcatClip {
            file,
            duration: (end - start) / rate,
            transition: segment.transition.clone(),
        });
    }
    post::concat_clips(job, &clips, &job.join("edited.mp4"))
}

pub fn render_package(root: &Path, timeline: &VideoEditTimeline) -> Result<PathBuf, ProjectError> {
    let job = RenderJob::new(root)?;
    render_package_in_job(root, timeline, job)
}

pub fn render_package_for_task(
    root: &Path,
    timeline: &VideoEditTimeline,
    task_id: &str,
) -> Result<PathBuf, ProjectError> {
    let job = RenderJob::for_task(root, task_id)?;
    render_package_in_job(root, timeline, job)
}

fn render_package_in_job(
    root: &Path,
    timeline: &VideoEditTimeline,
    job: RenderJob,
) -> Result<PathBuf, ProjectError> {
    let rendered = render_in_job(root, &job.0, Some(timeline))?;
    let output = root.join("previews/edited.mp4");
    // Publish only after the complete render succeeds. Existing previews survive failures.
    fs::rename(rendered, &output)?;
    Ok(output)
}

pub fn export_package(root: &Path, preset: &str) -> Result<PathBuf, ProjectError> {
    let job = RenderJob::new(root)?;
    export_package_in_job(root, preset, job)
}

pub fn export_package_for_task(
    root: &Path,
    preset: &str,
    task_id: &str,
) -> Result<PathBuf, ProjectError> {
    let job = RenderJob::for_task(root, task_id)?;
    export_package_in_job(root, preset, job)
}

fn export_package_in_job(
    root: &Path,
    preset: &str,
    job: RenderJob,
) -> Result<PathBuf, ProjectError> {
    let normalized = match preset {
        "original" => "original",
        "balanced" => "balanced",
        "light" | "lightweight" => "light",
        _ => return Err(ProjectError::Manifest("unknown export preset".into())),
    };
    let timeline = load_timeline(root)?;
    let rendered = render_in_job(root, &job.0, timeline.as_ref())?;
    let staged = job.0.join("export.mp4");
    post::export_preset(&rendered, normalized, &staged)?;
    let output = root.join(format!("previews/export-{normalized}.mp4"));
    fs::rename(staged, &output)?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_workspace_is_scoped_and_cleanup_preserves_siblings() {
        let root = std::env::temp_dir().join(format!("lens-render-task-{}", new_uuid()));
        let task = root.join("previews/render-export-123");
        let sibling = root.join("previews/keep.txt");
        fs::create_dir_all(&task).unwrap();
        fs::write(task.join("partial.mp4"), b"partial").unwrap();
        fs::write(&sibling, b"keep").unwrap();

        cleanup_task_workspace(&root, "export-123").unwrap();
        assert!(!task.exists());
        assert_eq!(fs::read(&sibling).unwrap(), b"keep");
        assert!(cleanup_task_workspace(&root, "../escape").is_err());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn captions_clip_and_retime_each_source_segment() {
        let cues = vec![
            CaptionCue {
                start_seconds: 1.0,
                end_seconds: 4.0,
                text: "first".into(),
            },
            CaptionCue {
                start_seconds: 5.0,
                end_seconds: 7.0,
                text: "second".into(),
            },
        ];
        let fast = captions_for_segment(&cues, 2.0, 6.0, 2.0);
        assert_eq!((fast[0].start_seconds, fast[0].end_seconds), (0.0, 1.0));
        assert_eq!((fast[1].start_seconds, fast[1].end_seconds), (1.5, 2.0));
        let repeated = captions_for_segment(&cues, 5.0, 7.0, 0.5);
        assert_eq!(
            (repeated[0].start_seconds, repeated[0].end_seconds),
            (0.0, 4.0)
        );
        assert_eq!(repeated[0].text, "second");
    }
}
