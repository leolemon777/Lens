use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::audio::{self, AudioCaptureConfig, DualAudioStats};
use crate::camera::{self, CameraTrackOutcome};
use crate::capture::CaptureError;
use crate::encode::{self, SegmentedRecordingStats};
pub use crate::encode::VideoSource;
use crate::events::{EventRecorder, EventTrack};
use crate::overlay::PhysicalRegion;
use crate::screenshot;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecordingConfig {
    pub audio: AudioCaptureConfig,
    pub enable_camera: bool,
    pub camera_device_link: Option<String>,
    pub fps: u32,
}

impl Default for SessionRecordingConfig {
    fn default() -> Self {
        Self {
            audio: AudioCaptureConfig::default(),
            enable_camera: false,
            camera_device_link: None,
            fps: 30,
        }
    }
}

pub struct LiveRecording {
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    started: Instant,
    paused_at: Mutex<Option<Instant>>,
    paused_total: Mutex<Duration>,
    output_dir: PathBuf,
    video: JoinHandle<std::result::Result<SegmentedRecordingStats, CaptureError>>,
    audio: JoinHandle<windows::core::Result<DualAudioStats>>,
    camera: Option<JoinHandle<windows::core::Result<CameraTrackOutcome>>>,
    events: EventRecorder,
}

impl LiveRecording {
    pub fn start(output_dir: PathBuf) -> Self {
        Self::start_source(output_dir, VideoSource::PrimaryMonitor)
    }

    pub fn start_region_fps(output_dir: PathBuf, region: PhysicalRegion, fps: u32) -> Self {
        let source = video_source_for_region(region).unwrap_or(VideoSource::PrimaryMonitor);
        Self::start_source_fps(output_dir, source, fps)
    }

    pub fn start_window_fps(output_dir: PathBuf, hwnd: isize, fps: u32) -> Self {
        Self::start_source_fps(output_dir, VideoSource::Window { hwnd }, fps)
    }

    pub fn start_source(output_dir: PathBuf, source: VideoSource) -> Self {
        Self::start_source_fps(output_dir, source, 30)
    }

    pub fn start_source_fps(output_dir: PathBuf, source: VideoSource, fps: u32) -> Self {
        Self::start_source_full(
            output_dir,
            source,
            SessionRecordingConfig {
                fps,
                ..Default::default()
            },
        )
    }

    pub fn start_source_full(
        output_dir: PathBuf,
        source: VideoSource,
        config: SessionRecordingConfig,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let paused = Arc::new(AtomicBool::new(false));
        let video_stop = Arc::clone(&stop);
        let audio_stop = Arc::clone(&stop);
        let events_stop = Arc::clone(&stop);
        let video_paused = Arc::clone(&paused);
        let audio_paused = Arc::clone(&paused);
        let events_paused = Arc::clone(&paused);
        let video_dir = output_dir.join("raw").join("segments");
        let audio_dir = output_dir.join("raw");
        let bounds = event_bounds(source);
        let fps = config.fps.max(15).min(60);

        let video = std::thread::spawn(move || {
            encode::record_source_h264_segmented_until(
                &video_dir,
                Duration::from_secs(8 * 60 * 60),
                Duration::from_secs(5),
                video_stop,
                video_paused,
                false,
                source,
                fps,
            )
        });

        let audio_cfg = config.audio.clone();
        let audio = std::thread::spawn(move || {
            audio::capture_audio_with_config_until(
                &audio_dir,
                Duration::from_secs(8 * 60 * 60),
                false,
                audio_stop,
                audio_paused,
                &audio_cfg,
            )
        });

        let camera = if config.enable_camera {
            let camera_stop = Arc::clone(&stop);
            let camera_paused = Arc::clone(&paused);
            let camera_path = output_dir.join("raw").join("camera.mp4");
            let link = config.camera_device_link.clone();
            Some(std::thread::spawn(move || {
                camera::record_camera_track_until(&camera_path, link, camera_stop, camera_paused, fps)
            }))
        } else {
            None
        };

        let tracking_hwnd = match source {
            VideoSource::Window { hwnd } => Some(hwnd),
            _ => None,
        };
        let events = EventRecorder::start_with_window(bounds, tracking_hwnd, events_paused, events_stop);

        Self {
            stop,
            paused,
            started: Instant::now(),
            paused_at: Mutex::new(None),
            paused_total: Mutex::new(Duration::ZERO),
            output_dir,
            video,
            audio,
            camera,
            events,
        }
    }

    pub fn elapsed(&self) -> Duration {
        let paused_total = self
            .paused_total
            .lock()
            .map(|value| *value)
            .unwrap_or(Duration::ZERO);
        let current_pause = self
            .paused_at
            .lock()
            .ok()
            .and_then(|guard| *guard)
            .map(|started| started.elapsed())
            .unwrap_or(Duration::ZERO);
        self.started
            .elapsed()
            .saturating_sub(paused_total + current_pause)
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    pub fn output_dir(&self) -> &PathBuf {
        &self.output_dir
    }

    pub fn set_paused(&self, paused: bool) {
        let was = self.paused.swap(paused, Ordering::SeqCst);
        if paused && !was {
            if let Ok(mut mark) = self.paused_at.lock() {
                *mark = Some(Instant::now());
            }
        } else if !paused && was {
            if let Ok(mut mark) = self.paused_at.lock() {
                if let Some(started) = mark.take() {
                    if let Ok(mut total) = self.paused_total.lock() {
                        *total += started.elapsed();
                    }
                }
            }
        }
    }

    pub fn request_stop(&self) {
        self.paused.store(false, Ordering::SeqCst);
        self.stop.store(true, Ordering::SeqCst);
    }

    pub fn join(self) -> Result<FinishedRecording, CaptureError> {
        let elapsed = self.elapsed();
        self.request_stop();
        let video = self.video.join().map_err(|_| {
            CaptureError::Windows(windows::core::Error::from(
                windows::Win32::Foundation::E_FAIL,
            ))
        })??;
        let audio = self
            .audio
            .join()
            .map_err(|_| {
                CaptureError::Windows(windows::core::Error::from(
                    windows::Win32::Foundation::E_FAIL,
                ))
            })?
            .ok();
        let camera = if let Some(th) = self.camera {
            th.join()
                .map_err(|_| {
                    CaptureError::Windows(windows::core::Error::from(
                        windows::Win32::Foundation::E_FAIL,
                    ))
                })?
                .ok()
        } else {
            None
        };
        let events = self.events.join();
        let _ = events.write_jsonl(&self.output_dir.join("events"));
        Ok(FinishedRecording {
            output_dir: self.output_dir,
            elapsed,
            video,
            audio,
            camera,
            events,
        })
    }
}

pub struct FinishedRecording {
    pub output_dir: PathBuf,
    pub elapsed: Duration,
    pub video: SegmentedRecordingStats,
    pub audio: Option<DualAudioStats>,
    pub camera: Option<CameraTrackOutcome>,
    pub events: EventTrack,
}

pub fn video_source_for_region(region: PhysicalRegion) -> Option<VideoSource> {
    let displays = crate::display::enumerate_displays().ok()?;
    let display = screenshot::display_covering(&displays, region)?;
    let crop_x = (region.x - display.left).max(0) as u32;
    let crop_y = (region.y - display.top).max(0) as u32;
    Some(VideoSource::MonitorRegion {
        handle: display.handle,
        crop_x,
        crop_y,
        crop_w: region.width.max(2) as u32,
        crop_h: region.height.max(2) as u32,
    })
}

fn event_bounds(source: VideoSource) -> (i32, i32, i32, i32) {
    match source {
        VideoSource::Window { hwnd } => crate::windows::enumerate_capturable_windows()
            .ok()
            .into_iter()
            .flatten()
            .find(|item| item.hwnd == hwnd)
            .map(|item| (item.left, item.top, item.right, item.bottom))
            .unwrap_or((0, 0, 1920, 1080)),
        VideoSource::MonitorRegion {
            handle,
            crop_x,
            crop_y,
            crop_w,
            crop_h,
        } => crate::display::enumerate_displays()
            .ok()
            .into_iter()
            .flatten()
            .find(|item| item.handle == handle)
            .map(|item| {
                (
                    item.left + crop_x as i32,
                    item.top + crop_y as i32,
                    item.left + crop_x as i32 + crop_w as i32,
                    item.top + crop_y as i32 + crop_h as i32,
                )
            })
            .unwrap_or((0, 0, 1920, 1080)),
        VideoSource::PrimaryMonitor => crate::display::enumerate_displays()
            .ok()
            .into_iter()
            .flatten()
            .find(|item| item.is_primary)
            .map(|item| (item.left, item.top, item.right, item.bottom))
            .unwrap_or((0, 0, 1920, 1080)),
    }
}
