use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use serde::{Deserialize, Serialize};
use windows::core::{Result, HSTRING};
use windows::Win32::Foundation::E_FAIL;
use windows::Win32::Media::MediaFoundation::{
    IMFActivate, IMFAttributes, IMFMediaSource, IMFSample, IMFSinkWriter, IMFSourceReader,
    MFCreateAttributes, MFCreateMediaType, MFCreateSinkWriterFromURL,
    MFCreateSourceReaderFromMediaSource, MFEnumDeviceSources, MFMediaType_Video, MFShutdown,
    MFStartup, MFVideoFormat_H264, MFVideoFormat_RGB32, MFVideoInterlace_Progressive,
    MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_HW_SOURCE,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, MF_MT_AVG_BITRATE,
    MF_MT_FRAME_RATE, MF_MT_FRAME_SIZE, MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE,
    MF_MT_SUBTYPE, MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,
    MF_SOURCE_READERF_ENDOFSTREAM, MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,
    MF_SOURCE_READER_FIRST_VIDEO_STREAM, MFSTARTUP_LITE, MF_VERSION,
};
use windows::Win32::System::Com::{
    CoInitializeEx, CoTaskMemFree, CoUninitialize, COINIT_MULTITHREADED,
};

/// One Media Foundation video capture device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoCaptureDeviceInfo {
    pub friendly_name: String,
    pub symbolic_link: String,
    pub hardware_source: bool,
}

/// Outcome of attempting to record a camera track.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraTrackStats {
    pub output_path: String,
    pub device_name: String,
    pub width: u32,
    pub height: u32,
    pub frames_written: u64,
    pub elapsed: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CameraTrackOutcome {
    Captured(CameraTrackStats),
    Degraded(String),
}

/// Enumerates video capture sources known to Media Foundation.
///
/// An empty result is a valid hardware state: the machine has no camera. It
/// must be surfaced as "camera unavailable" by callers, never replaced by a
/// mock capture stream.
pub fn enumerate_video_capture_devices() -> Result<Vec<VideoCaptureDeviceInfo>> {
    // Tauri and other hosts initialize their own COM apartment on the calling
    // thread. MF device enumeration requires MTA, so isolate it instead of
    // changing the host thread's apartment model (RPC_E_CHANGED_MODE).
    let worker = thread::spawn(enumerate_on_worker_thread);
    worker
        .join()
        .unwrap_or_else(|_| Err(windows::core::Error::from(E_FAIL)))
}

fn enumerate_on_worker_thread() -> Result<Vec<VideoCaptureDeviceInfo>> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(windows::core::Error::from(apartment));
    }
    unsafe { MFStartup(MF_VERSION, MFSTARTUP_LITE)? };
    let result = enumerate_inner();
    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    result
}

fn enumerate_inner() -> Result<Vec<VideoCaptureDeviceInfo>> {
    unsafe {
        let mut attributes: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attributes, 1)?;
        let attributes = attributes.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
        attributes.SetGUID(
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
        )?;

        let mut activations: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut count = 0_u32;
        MFEnumDeviceSources(&attributes, &mut activations, &mut count)?;
        if activations.is_null() || count == 0 {
            // MFEnumDeviceSources can return a null array when no capture
            // devices exist; that is a valid hardware state.
            CoTaskMemFree(Some(activations.cast()));
            return Ok(Vec::new());
        }
        let items = std::slice::from_raw_parts(activations, count as usize);
        let mut devices = Vec::new();
        for item in items {
            let Some(activate) = item else { continue };
            let friendly_name = read_string(activate, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME)
                .unwrap_or_else(|_| "Unknown camera".to_string());
            let symbolic_link = read_string(
                activate,
                &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
            )
            .unwrap_or_default();
            let hardware_source = activate
                .GetUINT32(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_HW_SOURCE)
                .map(|value| value != 0)
                .unwrap_or(false);
            devices.push(VideoCaptureDeviceInfo {
                friendly_name,
                symbolic_link,
                hardware_source,
            });
        }

        // ActivateArray is allocated with CoTaskMemAlloc; the COM wrappers
        // above released their references when dropped.
        CoTaskMemFree(Some(activations.cast()));
        Ok(devices)
    }
}

fn read_string(attributes: &IMFAttributes, key: &windows::core::GUID) -> Result<String> {
    unsafe {
        let length = attributes.GetStringLength(key)? as usize;
        let mut buffer = vec![0_u16; length + 1];
        attributes.GetString(key, &mut buffer, None)?;
        let end = buffer
            .iter()
            .position(|char| *char == 0)
            .unwrap_or(buffer.len());
        Ok(String::from_utf16_lossy(&buffer[..end]))
    }
}

pub fn record_camera_track_until(
    output_path: &Path,
    device_symbolic_link: Option<String>,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    target_fps: u32,
) -> Result<CameraTrackOutcome> {
    let path = output_path.to_path_buf();
    let worker = thread::spawn(move || {
        record_camera_on_worker_thread(&path, device_symbolic_link, stop, paused, target_fps)
    });
    worker
        .join()
        .unwrap_or_else(|_| Err(windows::core::Error::from(E_FAIL)))
}

fn record_camera_on_worker_thread(
    output_path: &Path,
    device_symbolic_link: Option<String>,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    target_fps: u32,
) -> Result<CameraTrackOutcome> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(windows::core::Error::from(apartment));
    }
    unsafe { MFStartup(MF_VERSION, MFSTARTUP_LITE)? };
    let result = record_camera_inner(output_path, device_symbolic_link, stop, paused, target_fps);
    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    result
}

fn record_camera_inner(
    output_path: &Path,
    device_symbolic_link: Option<String>,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    target_fps: u32,
) -> Result<CameraTrackOutcome> {
    let started = Instant::now();
    unsafe {
        let mut attributes: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attributes, 1)?;
        let attributes = attributes.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
        attributes.SetGUID(
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
        )?;

        let mut activations: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut count = 0_u32;
        MFEnumDeviceSources(&attributes, &mut activations, &mut count)?;
        if activations.is_null() || count == 0 {
            CoTaskMemFree(Some(activations.cast()));
            return Ok(CameraTrackOutcome::Degraded(
                "未检测到摄像头设备，摄像头轨已显式降级".into(),
            ));
        }

        let items = std::slice::from_raw_parts(activations, count as usize);
        let mut selected_activate: Option<IMFActivate> = None;
        let mut device_name = "Camera".to_string();

        for item in items {
            let Some(activate) = item else { continue };
            let name = read_string(activate, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME)
                .unwrap_or_else(|_| "Camera".to_string());
            let link = read_string(
                activate,
                &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
            )
            .unwrap_or_default();
            if let Some(target) = &device_symbolic_link {
                if &link == target {
                    selected_activate = Some(activate.clone());
                    device_name = name;
                    break;
                }
            } else if selected_activate.is_none() {
                selected_activate = Some(activate.clone());
                device_name = name;
            }
        }
        CoTaskMemFree(Some(activations.cast()));

        let Some(activate) = selected_activate else {
            return Ok(CameraTrackOutcome::Degraded(
                "未找到匹配的摄像头设备，摄像头轨已显式降级".into(),
            ));
        };

        let media_source: IMFMediaSource = match activate.ActivateObject() {
            Ok(src) => src,
            Err(err) => {
                return Ok(CameraTrackOutcome::Degraded(format!(
                    "无法激活摄像头设备 {}: {}",
                    device_name,
                    err.message()
                )));
            }
        };

        let mut reader_attributes: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut reader_attributes, 2)?;
        let reader_attr = reader_attributes.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
        reader_attr.SetUINT32(&MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1)?;
        reader_attr.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;

        let reader: IMFSourceReader =
            match MFCreateSourceReaderFromMediaSource(&media_source, &reader_attr) {
                Ok(r) => r,
                Err(err) => {
                    let _ = media_source.Shutdown();
                    return Ok(CameraTrackOutcome::Degraded(format!(
                        "创建摄像头 SourceReader 失败: {}",
                        err.message()
                    )));
                }
            };

        let out_type = MFCreateMediaType()?;
        out_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        out_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32)?;
        if let Err(err) = reader.SetCurrentMediaType(
            MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
            None,
            &out_type,
        ) {
            let _ = media_source.Shutdown();
            return Ok(CameraTrackOutcome::Degraded(format!(
                "配置摄像头媒体格式失败: {}",
                err.message()
            )));
        }

        let cur_type = reader.GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32)?;
        let mut width = 1280_u32;
        let mut height = 720_u32;
        if let Ok(size) = cur_type.GetUINT64(&MF_MT_FRAME_SIZE) {
            let w = (size >> 32) as u32;
            let h = (size & 0xFFFF_FFFF) as u32;
            if w >= 2 && h >= 2 {
                width = (w & !1).max(2);
                height = (h & !1).max(2);
            }
        }

        if let Some(parent) = output_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        let absolute = if output_path.is_absolute() {
            output_path.to_path_buf()
        } else {
            std::env::current_dir()?.join(output_path)
        };
        let url = HSTRING::from(absolute.to_string_lossy().as_ref());
        let mut writer_attributes: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut writer_attributes, 2)?;
        let writer_attr = writer_attributes.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
        writer_attr.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;

        let writer: IMFSinkWriter = match MFCreateSinkWriterFromURL(&url, None, &writer_attr) {
            Ok(w) => w,
            Err(err) => {
                let _ = media_source.Shutdown();
                return Ok(CameraTrackOutcome::Degraded(format!(
                    "创建摄像头 MP4 写入器失败: {}",
                    err.message()
                )));
            }
        };

        let target_fps_u64 = u64::from(target_fps.max(15).min(60));
        let bitrate = 6_000_000_u32;

        let sink_out_type = MFCreateMediaType()?;
        sink_out_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        sink_out_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
        sink_out_type.SetUINT64(&MF_MT_FRAME_SIZE, (width as u64) << 32 | height as u64)?;
        sink_out_type.SetUINT64(&MF_MT_FRAME_RATE, target_fps_u64 << 32 | 1)?;
        sink_out_type.SetUINT32(&MF_MT_AVG_BITRATE, bitrate)?;
        sink_out_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        let stream_index = writer.AddStream(&sink_out_type)?;

        let sink_in_type = MFCreateMediaType()?;
        sink_in_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        sink_in_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32)?;
        sink_in_type.SetUINT64(&MF_MT_FRAME_SIZE, (width as u64) << 32 | height as u64)?;
        sink_in_type.SetUINT64(&MF_MT_FRAME_RATE, target_fps_u64 << 32 | 1)?;
        sink_in_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        writer.SetInputMediaType(stream_index, &sink_in_type, None)?;
        writer.BeginWriting()?;

        let mut origin_100ns: Option<i64> = None;
        let mut pause_shift = 0_i64;
        let mut pause_mark: Option<i64> = None;
        let mut frames_written = 0_u64;

        while !stop.load(Ordering::SeqCst) {
            let mut stream_flags = 0_u32;
            let mut timestamp_100ns = 0_i64;
            let mut sample: Option<IMFSample> = None;

            let hr = reader.ReadSample(
                MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                0,
                None,
                Some(&mut stream_flags),
                Some(&mut timestamp_100ns),
                Some(&mut sample),
            );

            if hr.is_err() || (stream_flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0) {
                thread::sleep(Duration::from_millis(10));
                continue;
            }

            if paused.load(Ordering::SeqCst) {
                if pause_mark.is_none() {
                    pause_mark = Some(timestamp_100ns);
                }
                continue;
            } else if let Some(begin) = pause_mark.take() {
                pause_shift += timestamp_100ns.saturating_sub(begin);
            }

            if let Some(sample) = sample {
                if origin_100ns.is_none() {
                    origin_100ns = Some(timestamp_100ns);
                }
                let origin = origin_100ns.unwrap_or(timestamp_100ns);
                let pts = (timestamp_100ns - origin - pause_shift).max(0);
                sample.SetSampleTime(pts)?;
                sample.SetSampleDuration(10_000_000_i64 / target_fps as i64)?;
                if writer.WriteSample(stream_index, &sample).is_ok() {
                    frames_written += 1;
                }
            }
        }

        let _ = writer.Finalize();
        let _ = media_source.Shutdown();

        if frames_written == 0 {
            let _ = std::fs::remove_file(output_path);
            return Ok(CameraTrackOutcome::Degraded(
                "摄像头捕获未获得有效视频帧，已降级".into(),
            ));
        }

        Ok(CameraTrackOutcome::Captured(CameraTrackStats {
            output_path: output_path.to_string_lossy().into_owned(),
            device_name,
            width,
            height,
            frames_written,
            elapsed: started.elapsed(),
        }))
    }
}
