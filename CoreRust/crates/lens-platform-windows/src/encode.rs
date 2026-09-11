//! Media Foundation H.264 encoder discovery.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use std::time::Instant;

use serde::{Deserialize, Serialize};
use windows::core::{Interface, Result, HSTRING};
use windows::Win32::Foundation::{E_FAIL, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, InvalidateRect, PAINTSTRUCT,
};
use windows::Win32::Media::MediaFoundation::{
    IMFActivate, IMFAttributes, IMFDXGIDeviceManager, IMFSample, IMFSinkWriter, MFCreateAttributes,
    MFCreateDXGIDeviceManager, MFCreateDXGISurfaceBuffer, MFCreateMediaType, MFCreateSample,
    MFCreateSinkWriterFromURL, MFCreateSourceReaderFromURL, MFMediaType_Video, MFShutdown,
    MFStartup, MFTEnumEx, MFT_FRIENDLY_NAME_Attribute, MFVideoFormat_ARGB32, MFVideoFormat_H264,
    MFVideoFormat_RGB32, MFVideoInterlace_Progressive, MF_TRANSFORM_FLAGS_Attribute,
    MFSTARTUP_LITE, MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_ALL, MFT_ENUM_FLAG_HARDWARE,
    MFT_REGISTER_TYPE_INFO, MF_MT_AVG_BITRATE, MF_MT_FRAME_RATE, MF_MT_FRAME_SIZE,
    MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE, MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,
    MF_SINK_WRITER_D3D_MANAGER, MF_SOURCE_READERF_ENDOFSTREAM,
    MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, MF_VERSION,
};
use windows::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::WinRT::Direct3D11::CreateDirect3D11DeviceFromDXGIDevice;
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetClientRect, KillTimer,
    PeekMessageW, RegisterClassExW, SetTimer, ShowWindow, TranslateMessage, MSG, PM_REMOVE,
    SW_SHOWNORMAL, WM_PAINT, WM_TIMER, WS_OVERLAPPEDWINDOW, WS_VISIBLE,
};

use crate::capture::CaptureError;
use crate::graphics::create_video_device;

/// Where product recording pulls frames from. Primary-monitor remains the
/// default used by prototypes and tests.
#[derive(Debug, Clone, Copy)]
pub enum VideoSource {
    PrimaryMonitor,
    MonitorRegion {
        handle: isize,
        crop_x: u32,
        crop_y: u32,
        crop_w: u32,
        crop_h: u32,
    },
    Window {
        hwnd: isize,
    },
}

/// One discovered H.264-capable encoder MFT.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncoderInfo {
    pub name: String,
    pub hardware: bool,
}

/// Statistics from one WGC -> H.264 recording pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordingStats {
    pub output_path: String,
    pub width: u32,
    pub height: u32,
    pub frames_written: u64,
    pub frames_arrived: u64,
    pub last_handler_error: Option<String>,
    pub elapsed: Duration,
}

/// Frame-level decode verification for an MP4 produced by the recorder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodeReport {
    pub frames_decoded: u64,
    pub first_timestamp_100ns: Option<i64>,
    pub last_timestamp_100ns: Option<i64>,
    pub total_bytes: u64,
    pub saw_nonzero_pixels: bool,
}

#[derive(Default)]
struct RecordingCounters {
    frames_arrived: u64,
    frames_written: u64,
    last_handler_error: Option<String>,
}

/// IMFSinkWriter is documented as callable from multiple threads for distinct
/// samples; windows-rs exposes it as a raw COM pointer without auto-Send.
struct SendSinkWriter(IMFSinkWriter);

unsafe impl Send for SendSinkWriter {}

/// Enumerates video encoder MFTs that can emit H.264.
///
/// `MFT_ENUM_FLAG_ALL` includes both hardware and software transforms; the
/// hardware bit is then read from each activation's transform flags.
pub fn enumerate_h264_encoders() -> Result<Vec<EncoderInfo>> {
    unsafe {
        let output_type = MFT_REGISTER_TYPE_INFO {
            guidMajorType: MFMediaType_Video,
            guidSubtype: MFVideoFormat_H264,
        };
        let mut activations: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut count = 0_u32;
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_ALL,
            None,
            Some(&output_type),
            &mut activations,
            &mut count,
        )?;

        let items = std::slice::from_raw_parts(activations, count as usize);
        let mut encoders = Vec::new();
        for item in items {
            let Some(activate) = item else { continue };
            let name = read_attribute_string(activate, &MFT_FRIENDLY_NAME_Attribute)
                .unwrap_or_else(|_| "Unknown encoder".to_string());
            let flags = activate
                .GetUINT32(&MF_TRANSFORM_FLAGS_Attribute)
                .unwrap_or(0);
            encoders.push(EncoderInfo {
                name,
                hardware: (flags & MFT_ENUM_FLAG_HARDWARE.0 as u32) != 0,
            });
        }

        // MFTEnumEx allocates the activation array with CoTaskMemAlloc; the
        // individual COM references have been released by dropping the wrappers.
        windows::Win32::System::Com::CoTaskMemFree(Some(activations.cast()));
        Ok(encoders)
    }
}

fn read_attribute_string(attributes: &IMFAttributes, key: &windows::core::GUID) -> Result<String> {
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

/// Records the primary monitor to an H.264 MP4 using the GPU sink-writer path.
///
/// A small test-pattern window animates during the burst so WGC has real
/// changing content even on an otherwise static desktop. The output file is
/// never deleted implicitly; recordings are treated as user data.
pub fn record_primary_monitor_h264(
    output_path: &Path,
    duration: Duration,
) -> std::result::Result<RecordingStats, CaptureError> {
    let output_path = output_path.to_path_buf();
    let worker = thread::spawn(move || record_on_worker_thread(&output_path, duration));
    worker
        .join()
        .map_err(|_| CaptureError::Windows(windows::core::Error::from(E_FAIL)))?
}

fn record_on_worker_thread(
    output_path: &Path,
    duration: Duration,
) -> std::result::Result<RecordingStats, CaptureError> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(windows::core::Error::from(apartment).into());
    }
    unsafe { MFStartup(MF_VERSION, MFSTARTUP_LITE)? };
    let result = record_inner(output_path, duration);
    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    result
}

fn record_inner(
    output_path: &Path,
    duration: Duration,
) -> std::result::Result<RecordingStats, CaptureError> {
    let started = Instant::now();
    let created = create_video_device()?;
    let dxgi_device: IDXGIDevice = created.device.cast()?;
    let d3d_device: windows::Graphics::DirectX::Direct3D11::IDirect3DDevice =
        unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi_device) }?.cast()?;

    // The sink writer owns D3D device access for encoding through this manager.
    let mut reset_token = 0_u32;
    let mut manager: Option<IMFDXGIDeviceManager> = None;
    unsafe { MFCreateDXGIDeviceManager(&mut reset_token, &mut manager)? };
    let manager = manager.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    unsafe { manager.ResetDevice(&created.device, reset_token)? };

    let mut writer_attributes: Option<IMFAttributes> = None;
    unsafe { MFCreateAttributes(&mut writer_attributes, 4)? };
    let writer_attributes = writer_attributes.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    unsafe {
        writer_attributes.SetUnknown(&MF_SINK_WRITER_D3D_MANAGER, &manager)?;
        writer_attributes.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;
    }

    let monitor = crate::capture::primary_monitor_handle()?;
    let interop: IGraphicsCaptureItemInterop = windows::core::factory::<
        windows::Graphics::Capture::GraphicsCaptureItem,
        IGraphicsCaptureItemInterop,
    >()?;
    let item: windows::Graphics::Capture::GraphicsCaptureItem =
        unsafe { interop.CreateForMonitor(monitor) }?;
    let size = item.Size()?;
    let width = size.Width as u32;
    let height = size.Height as u32;
    let frame_rate = 15_u64;
    let bitrate = 12_000_000_u32;

    let absolute = if output_path.is_absolute() {
        output_path.to_path_buf()
    } else {
        std::env::current_dir()?.join(output_path)
    };
    let url = HSTRING::from(absolute.to_string_lossy().as_ref());
    let writer: IMFSinkWriter =
        unsafe { MFCreateSinkWriterFromURL(&url, None, &writer_attributes)? };

    let output_type = unsafe { MFCreateMediaType()? };
    unsafe {
        output_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        output_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
        output_type.SetUINT64(&MF_MT_FRAME_SIZE, (width as u64) << 32 | height as u64)?;
        output_type.SetUINT64(&MF_MT_FRAME_RATE, frame_rate << 32 | 1)?;
        output_type.SetUINT32(&MF_MT_AVG_BITRATE, bitrate)?;
        output_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
    }
    let stream_index = unsafe { writer.AddStream(&output_type)? };

    let input_type = unsafe { MFCreateMediaType()? };
    unsafe {
        input_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        input_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_ARGB32)?;
        input_type.SetUINT64(&MF_MT_FRAME_SIZE, (width as u64) << 32 | height as u64)?;
        input_type.SetUINT64(&MF_MT_FRAME_RATE, frame_rate << 32 | 1)?;
        input_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
    }
    unsafe { writer.SetInputMediaType(stream_index, &input_type, None)? };

    // Test-pattern window drives real per-frame desktop changes.
    let pattern = TestPatternWindow::show("Lens H.264 capture probe")?;

    let frame_pool = windows::Graphics::Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
        &d3d_device,
        windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
        2,
        size,
    )?;
    let session: windows::Graphics::Capture::GraphicsCaptureSession =
        frame_pool.CreateCaptureSession(&item)?;

    let counters = Arc::new(Mutex::new(RecordingCounters::default()));
    let handler_counters = Arc::clone(&counters);
    let handler_writer = SendSinkWriter(writer.clone());
    const fn assert_send<T: Send>() {}
    let _ = assert_send::<SendSinkWriter>;
    let handler = windows::Foundation::TypedEventHandler::<
        windows::Graphics::Capture::Direct3D11CaptureFramePool,
        windows::core::IInspectable,
    >::new(move |sender, _args| {
        let outcome = write_arrived_frame(sender, &handler_writer, stream_index, frame_rate);
        let mut counters = handler_counters
            .lock()
            .expect("recording counters mutex poisoned");
        match outcome {
            Ok(()) => {
                counters.frames_arrived += 1;
                counters.frames_written += 1;
            }
            Err(err) => {
                counters.last_handler_error = Some(err.to_string());
            }
        }
        Ok(())
    });

    let token = frame_pool.FrameArrived(&handler)?;
    session.StartCapture()?;
    unsafe { writer.BeginWriting()? };
    // Give the first composition frame time to arrive before the short burst
    // ends; the sink writer rejects Finalize when it has processed no samples.
    thread::sleep(Duration::from_millis(250));

    pump_messages_until(pattern.hwnd(), started + duration);

    unsafe {
        let _ = session.Close();
        let _ = frame_pool.RemoveFrameArrived(token);
        let _ = frame_pool.Close();
        if let Err(err) = writer.Finalize() {
            let guard = counters.lock().expect("recording counters mutex poisoned");
            let message = format!(
                "{}; frames_arrived={}, frames_written={}, last_handler_error={:?}",
                err.message(),
                guard.frames_arrived,
                guard.frames_written,
                guard.last_handler_error
            );
            return Err(windows::core::Error::new(err.code(), message).into());
        }
    }
    pattern.close();

    let (frames_arrived, frames_written, last_handler_error) = {
        let guard = counters.lock().expect("recording counters mutex poisoned");
        (
            guard.frames_arrived,
            guard.frames_written,
            guard.last_handler_error.clone(),
        )
    };
    Ok(RecordingStats {
        output_path: output_path.to_string_lossy().into_owned(),
        width,
        height,
        frames_arrived,
        frames_written,
        last_handler_error,
        elapsed: started.elapsed(),
    })
}

fn write_arrived_frame(
    sender: windows::core::Ref<windows::Graphics::Capture::Direct3D11CaptureFramePool>,
    writer: &SendSinkWriter,
    stream_index: u32,
    frame_rate: u64,
) -> Result<()> {
    fn labeled(step: &str, err: windows::core::Error) -> windows::core::Error {
        windows::core::Error::new(err.code(), format!("{step}: {}", err.message()))
    }
    let Some(pool) = sender.as_ref() else {
        return Err(windows::core::Error::from(E_FAIL));
    };
    let frame = pool
        .TryGetNextFrame()
        .map_err(|e| labeled("TryGetNextFrame", e))?;
    let timestamp = frame
        .SystemRelativeTime()
        .map_err(|e| labeled("SystemRelativeTime", e))?;
    let surface = frame.Surface().map_err(|e| labeled("Surface", e))?;
    let access: windows::Win32::System::WinRT::Direct3D11::IDirect3DDxgiInterfaceAccess = surface
        .cast()
        .map_err(|e| labeled("cast-DxgiInterfaceAccess", e))?;
    let texture: windows::Win32::Graphics::Direct3D11::ID3D11Texture2D =
        unsafe { access.GetInterface() }.map_err(|e| labeled("GetInterface-ID3D11Texture2D", e))?;
    let buffer = unsafe {
        MFCreateDXGISurfaceBuffer(
            &windows::Win32::Graphics::Direct3D11::ID3D11Texture2D::IID,
            &texture,
            0,
            false,
        )
        .map_err(|e| labeled("MFCreateDXGISurfaceBuffer", e))?
    };
    unsafe {
        let max_length = buffer
            .GetMaxLength()
            .map_err(|e| labeled("GetMaxLength", e))?;
        buffer
            .SetCurrentLength(max_length)
            .map_err(|e| labeled("SetCurrentLength", e))?;
    }
    let sample: IMFSample =
        unsafe { MFCreateSample() }.map_err(|e| labeled("MFCreateSample", e))?;
    unsafe {
        sample
            .AddBuffer(&buffer)
            .map_err(|e| labeled("AddBuffer", e))?;
        sample
            .SetSampleTime(timestamp.Duration)
            .map_err(|e| labeled("SetSampleTime", e))?;
        sample
            .SetSampleDuration(10_000_000_i64 / frame_rate as i64)
            .map_err(|e| labeled("SetSampleDuration", e))?;
        writer
            .0
            .WriteSample(stream_index, &sample)
            .map_err(|e| labeled("WriteSample", e))?;
    }
    Ok(())
}

/// Animated window that guarantees WGC has changing content.
struct TestPatternWindow {
    hwnd: HWND,
}

static PAINT_COUNTER: AtomicU32 = AtomicU32::new(0);
static WINDOW_CLASS_REGISTERED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

impl TestPatternWindow {
    fn show(title: &str) -> Result<Self> {
        unsafe {
            let instance = GetModuleHandleW(None)?;
            let class_name = windows::core::w!("LensCaptureProbeWindow");
            if !WINDOW_CLASS_REGISTERED.load(Ordering::SeqCst) {
                let window_class = windows::Win32::UI::WindowsAndMessaging::WNDCLASSEXW {
                    lpfnWndProc: Some(test_pattern_wnd_proc),
                    hInstance: instance.into(),
                    lpszClassName: class_name,
                    cbSize: std::mem::size_of::<windows::Win32::UI::WindowsAndMessaging::WNDCLASSEXW>(
                    ) as u32,
                    ..Default::default()
                };
                let atom = RegisterClassExW(&window_class);
                if atom == 0 {
                    return Err(windows::core::Error::from(E_FAIL));
                }
                WINDOW_CLASS_REGISTERED.store(true, Ordering::SeqCst);
            }
            let title_h = HSTRING::from(title);
            let hwnd = CreateWindowExW(
                Default::default(),
                class_name,
                &title_h,
                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                64,
                64,
                640,
                480,
                None,
                None,
                Some(instance.into()),
                None,
            )?;
            let _ = ShowWindow(hwnd, SW_SHOWNORMAL);
            // 15 Hz animation matches the encoder frame-rate target.
            let timer = SetTimer(Some(hwnd), 1, 66, None);
            if timer == 0 {
                return Err(windows::core::Error::from(E_FAIL));
            }
            Ok(Self { hwnd })
        }
    }

    fn hwnd(&self) -> HWND {
        self.hwnd
    }

    fn close(self) {
        unsafe {
            let _ = KillTimer(Some(self.hwnd), 1);
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

unsafe extern "system" fn test_pattern_wnd_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_TIMER => {
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            LRESULT(0)
        }
        WM_PAINT => {
            let mut paint = PAINTSTRUCT::default();
            let hdc = unsafe { BeginPaint(hwnd, &mut paint) };
            let value = PAINT_COUNTER.fetch_add(1, Ordering::Relaxed);
            let red = value % 256;
            let green = 200_u32;
            let blue = (value / 7) % 256;
            let brush = unsafe {
                CreateSolidBrush(windows::Win32::Foundation::COLORREF(
                    (red & 0xFF) | ((green & 0xFF) << 8) | ((blue & 0xFF) << 16),
                ))
            };
            let mut client = RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut client) };
            unsafe { FillRect(hdc, &client, brush) };
            unsafe {
                let _ = DeleteObject(brush.into());
                let _ = EndPaint(hwnd, &paint);
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn pump_messages_until(hwnd: HWND, deadline: Instant) {
    while Instant::now() < deadline {
        unsafe {
            let mut message = MSG::default();
            while PeekMessageW(&mut message, Some(hwnd), 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// Verifies that an MP4 decodes to actual frame data.
///
/// The source reader is configured for RGB32 video processing, so every
/// returned sample has been decoded to pixels; stream metadata alone is not
/// accepted as decode evidence.
pub fn verify_h264_decoding(path: &Path) -> Result<DecodeReport> {
    unsafe {
        MFStartup(MF_VERSION, MFSTARTUP_LITE)?;
        let result = verify_decoding_inner(path);
        let _ = MFShutdown();
        result
    }
}

fn verify_decoding_inner(path: &Path) -> Result<DecodeReport> {
    unsafe {
        let mut attributes: Option<IMFAttributes> = None;
        MFCreateAttributes(&mut attributes, 2)?;
        let attributes = attributes.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
        attributes.SetUINT32(&MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1)?;

        let absolute = normalize_absolute_path(path)?;
        let url = HSTRING::from(absolute.to_string_lossy().as_ref());
        let reader = MFCreateSourceReaderFromURL(&url, &attributes)?;

        let output_type = MFCreateMediaType()?;
        output_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        output_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32)?;
        reader.SetCurrentMediaType(0, None, &output_type)?;

        let mut frames_decoded = 0_u64;
        let mut first_timestamp = None;
        let mut last_timestamp = None;
        let mut total_bytes = 0_u64;
        let mut saw_nonzero_pixels = false;
        let mut end_of_stream = false;

        while !end_of_stream {
            let mut stream_flags = 0_u32;
            let mut timestamp = 0_i64;
            let mut sample: Option<IMFSample> = None;
            reader.ReadSample(
                0,
                0,
                None,
                Some(&mut stream_flags),
                Some(&mut timestamp),
                Some(&mut sample),
            )?;

            if (stream_flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32) != 0 {
                end_of_stream = true;
            }
            let Some(sample) = sample else {
                continue;
            };
            let sample_bytes = sample.GetTotalLength()?;
            total_bytes += sample_bytes as u64;
            frames_decoded += 1;
            first_timestamp.get_or_insert(timestamp);
            last_timestamp = Some(timestamp);

            let buffer = sample.ConvertToContiguousBuffer()?;
            let mut data = std::ptr::null_mut();
            buffer.Lock(&mut data, None, None)?;
            let slice = std::slice::from_raw_parts(data, sample_bytes as usize);
            if slice.iter().any(|byte| *byte != 0) {
                saw_nonzero_pixels = true;
            }
            buffer.Unlock()?;
        }

        Ok(DecodeReport {
            frames_decoded,
            first_timestamp_100ns: first_timestamp,
            last_timestamp_100ns: last_timestamp,
            total_bytes,
            saw_nonzero_pixels,
        })
    }
}

fn normalize_absolute_path(path: &Path) -> Result<std::path::PathBuf> {
    let canonical = path.canonicalize()?;
    let text = canonical.to_string_lossy().into_owned();
    let stripped = text
        .strip_prefix(r"\\?\UNC\")
        .map(|rest| format!(r"\\{rest}"))
        .or_else(|| text.strip_prefix(r"\\?\").map(str::to_owned))
        .unwrap_or(text);
    Ok(Path::new(&stripped).to_path_buf())
}

/// Journal entry for one recording segment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SegmentInfo {
    pub index: u32,
    pub file: String,
    pub state: String,
    pub frames: u64,
    pub started_at_100ns: i64,
    pub ended_at_100ns: Option<i64>,
}

/// On-disk journal describing a segmented recording.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordingManifest {
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub frame_rate: u32,
    pub segments: Vec<SegmentInfo>,
}

/// Recovery assessment for one journaled segment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SegmentRecoveryReport {
    pub index: u32,
    pub file: String,
    pub journal_state: String,
    pub decodable: bool,
    pub decoded_frames: u64,
    pub saw_nonzero_pixels: bool,
    pub error: Option<String>,
}

/// Read-only recovery assessment for a segmented recording directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RecoveryReport {
    pub manifest_path: String,
    pub segments: Vec<SegmentRecoveryReport>,
    pub recoverable_frames: u64,
    pub broken_segments: Vec<u32>,
}

/// Statistics from one segmented recording pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SegmentedRecordingStats {
    pub output_dir: String,
    pub width: u32,
    pub height: u32,
    pub segments: Vec<SegmentInfo>,
    pub frames_written: u64,
    pub elapsed: Duration,
}

#[derive(Default)]
struct SegmentedCounters {
    frames_arrived: u64,
    frames_written: u64,
    last_handler_error: Option<String>,
}

struct ActiveSegment {
    writer: SendSinkWriter,
    stream_index: u32,
    index: u32,
    origin_100ns: Option<i64>,
    last_timestamp_100ns: i64,
    frames: u64,
}

/// Records the primary monitor into independently decodable MP4 segments.
///
/// A `manifest.json` journal is atomically updated beside the segments:
/// each segment starts as `writing`, and only becomes `confirmed` after its
/// writer finalized and its file decoded frame-by-frame back to pixels. This
/// is the normal-path building block for crash recovery; forced-termination
/// scanning is handled separately.
pub fn record_primary_monitor_h264_segmented(
    output_dir: &Path,
    total_duration: Duration,
    segment_duration: Duration,
) -> std::result::Result<SegmentedRecordingStats, CaptureError> {
    record_primary_monitor_h264_segmented_until(
        output_dir,
        total_duration,
        segment_duration,
        Arc::new(AtomicBool::new(false)),
        Arc::new(AtomicBool::new(false)),
        true,
    )
}

/// Same pipeline as the duration-based recorder, but stops when `stop` is set
/// or `max_duration` elapses. Product recording must pass `show_test_pattern =
/// false` so the test window is not captured.
pub fn record_primary_monitor_h264_segmented_until(
    output_dir: &Path,
    max_duration: Duration,
    segment_duration: Duration,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    show_test_pattern: bool,
) -> std::result::Result<SegmentedRecordingStats, CaptureError> {
    record_source_h264_segmented_until(
        output_dir,
        max_duration,
        segment_duration,
        stop,
        paused,
        show_test_pattern,
        VideoSource::PrimaryMonitor,
        15,
    )
}

pub fn record_source_h264_segmented_until(
    output_dir: &Path,
    max_duration: Duration,
    segment_duration: Duration,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    show_test_pattern: bool,
    source: VideoSource,
    frame_rate: u32,
) -> std::result::Result<SegmentedRecordingStats, CaptureError> {
    let output_dir = output_dir.to_path_buf();
    let worker = thread::spawn(move || {
        record_segmented_on_worker_thread(
            &output_dir,
            max_duration,
            segment_duration,
            stop,
            paused,
            show_test_pattern,
            source,
            frame_rate,
        )
    });
    worker
        .join()
        .map_err(|_| CaptureError::Windows(windows::core::Error::from(E_FAIL)))?
}

fn record_segmented_on_worker_thread(
    output_dir: &Path,
    total_duration: Duration,
    segment_duration: Duration,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    show_test_pattern: bool,
    source: VideoSource,
    frame_rate: u32,
) -> std::result::Result<SegmentedRecordingStats, CaptureError> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(windows::core::Error::from(apartment).into());
    }
    unsafe { MFStartup(MF_VERSION, MFSTARTUP_LITE)? };
    let result = record_segmented_inner(
        output_dir,
        total_duration,
        segment_duration,
        stop,
        paused,
        show_test_pattern,
        source,
        frame_rate,
    );
    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    result
}

fn even_dim(value: u32) -> u32 {
    (value & !1).max(2)
}

fn crop_texture_for_encode(
    source: &windows::Win32::Graphics::Direct3D11::ID3D11Texture2D,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) -> Result<windows::Win32::Graphics::Direct3D11::ID3D11Texture2D> {
    use windows::Win32::Graphics::Direct3D11::{D3D11_BOX, D3D11_TEXTURE2D_DESC};
    let device = unsafe { source.GetDevice() }?;
    let context = unsafe { device.GetImmediateContext() }?;
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { source.GetDesc(&mut desc) };
    desc.Width = width;
    desc.Height = height;
    desc.MiscFlags = 0;
    let mut dest: Option<windows::Win32::Graphics::Direct3D11::ID3D11Texture2D> = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut dest))? };
    let dest = dest.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    let region = D3D11_BOX {
        left: x,
        top: y,
        front: 0,
        right: x + width,
        bottom: y + height,
        back: 1,
    };
    unsafe {
        context.CopySubresourceRegion(&dest, 0, 0, 0, 0, source, 0, Some(&region));
    }
    Ok(dest)
}

fn record_segmented_inner(
    output_dir: &Path,
    total_duration: Duration,
    segment_duration: Duration,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    show_test_pattern: bool,
    source: VideoSource,
    frame_rate: u32,
) -> std::result::Result<SegmentedRecordingStats, CaptureError> {
    let started = Instant::now();
    std::fs::create_dir_all(output_dir)?;

    let created = create_video_device()?;
    let dxgi_device: IDXGIDevice = created.device.cast()?;
    let d3d_device: windows::Graphics::DirectX::Direct3D11::IDirect3DDevice =
        unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi_device) }?.cast()?;

    let mut reset_token = 0_u32;
    let mut manager_option: Option<IMFDXGIDeviceManager> = None;
    unsafe { MFCreateDXGIDeviceManager(&mut reset_token, &mut manager_option)? };
    let manager = manager_option.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    unsafe { manager.ResetDevice(&created.device, reset_token)? };

    let mut writer_attributes_option: Option<IMFAttributes> = None;
    unsafe { MFCreateAttributes(&mut writer_attributes_option, 4)? };
    let writer_attributes =
        writer_attributes_option.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    unsafe {
        writer_attributes.SetUnknown(&MF_SINK_WRITER_D3D_MANAGER, &manager)?;
        writer_attributes.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;
    }

    let interop: IGraphicsCaptureItemInterop = windows::core::factory::<
        windows::Graphics::Capture::GraphicsCaptureItem,
        IGraphicsCaptureItemInterop,
    >()?;
    let item: windows::Graphics::Capture::GraphicsCaptureItem = match source {
        VideoSource::Window { hwnd } => unsafe {
            interop.CreateForWindow(HWND(hwnd as *mut std::ffi::c_void))?
        },
        VideoSource::MonitorRegion { handle, .. } => unsafe {
            interop.CreateForMonitor(windows::Win32::Graphics::Gdi::HMONITOR(
                handle as *mut std::ffi::c_void,
            ))?
        },
        VideoSource::PrimaryMonitor => {
            let monitor = crate::capture::primary_monitor_handle()?;
            unsafe { interop.CreateForMonitor(monitor)? }
        }
    };
    let size = item.Size()?;
    let full_w = size.Width as u32;
    let full_h = size.Height as u32;
    let (crop, width, height) = match source {
        VideoSource::MonitorRegion {
            crop_x,
            crop_y,
            crop_w,
            crop_h,
            ..
        } => {
            let w = even_dim(crop_w.min(full_w.saturating_sub(crop_x)));
            let h = even_dim(crop_h.min(full_h.saturating_sub(crop_y)));
            (Some((crop_x, crop_y, w, h)), w, h)
        }
        _ => {
            let w = even_dim(full_w);
            let h = even_dim(full_h);
            let crop = if w != full_w || h != full_h {
                Some((0_u32, 0_u32, w, h))
            } else {
                None
            };
            (crop, w, h)
        }
    };
    let frame_rate = u64::from(frame_rate.max(15).min(60));
    let bitrate = 12_000_000_u32;

    let manifest_path = output_dir.join("manifest.json");
    let mut manifest = RecordingManifest {
        version: 1,
        width,
        height,
        frame_rate: frame_rate as u32,
        segments: Vec::new(),
    };

    let open_segment = |index: u32| -> Result<ActiveSegment> {
        let file_name = format!("seg-{index:06}.mp4");
        let path = output_dir.join(&file_name);
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()?.join(path)
        };
        let url = HSTRING::from(absolute.to_string_lossy().as_ref());
        let writer: IMFSinkWriter =
            unsafe { MFCreateSinkWriterFromURL(&url, None, &writer_attributes)? };

        let output_type = unsafe { MFCreateMediaType()? };
        unsafe {
            output_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            output_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
            output_type.SetUINT64(&MF_MT_FRAME_SIZE, (width as u64) << 32 | height as u64)?;
            output_type.SetUINT64(&MF_MT_FRAME_RATE, frame_rate << 32 | 1)?;
            output_type.SetUINT32(&MF_MT_AVG_BITRATE, bitrate)?;
            output_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        }
        let stream_index = unsafe { writer.AddStream(&output_type)? };

        let input_type = unsafe { MFCreateMediaType()? };
        unsafe {
            input_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            input_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_ARGB32)?;
            input_type.SetUINT64(&MF_MT_FRAME_SIZE, (width as u64) << 32 | height as u64)?;
            input_type.SetUINT64(&MF_MT_FRAME_RATE, frame_rate << 32 | 1)?;
            input_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        }
        unsafe { writer.SetInputMediaType(stream_index, &input_type, None)? };
        unsafe { writer.BeginWriting()? };

        Ok(ActiveSegment {
            writer: SendSinkWriter(writer),
            stream_index,
            index,
            origin_100ns: None,
            last_timestamp_100ns: 0,
            frames: 0,
        })
    };

    let append_journal = |manifest: &mut RecordingManifest, segment: &SegmentInfo| -> Result<()> {
        // Keep exactly one entry per index; rotation rewrites the same slot.
        if let Some(existing) = manifest
            .segments
            .iter_mut()
            .find(|item| item.index == segment.index)
        {
            *existing = segment.clone();
        } else {
            manifest.segments.push(segment.clone());
        }
        write_manifest_atomically(&manifest_path, manifest)
    };

    let active = open_segment(0).map_err(|err| {
        windows::core::Error::new(err.code(), format!("open segment 0: {}", err.message()))
    })?;
    append_journal(
        &mut manifest,
        &SegmentInfo {
            index: 0,
            file: "seg-000000.mp4".to_string(),
            state: "writing".to_string(),
            frames: 0,
            started_at_100ns: 0,
            ended_at_100ns: None,
        },
    )?;

    let pattern = if show_test_pattern {
        Some(TestPatternWindow::show("Lens segmented capture probe")?)
    } else {
        None
    };
    let frame_pool = windows::Graphics::Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
        &d3d_device,
        windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
        2,
        size,
    )?;
    let session: windows::Graphics::Capture::GraphicsCaptureSession =
        frame_pool.CreateCaptureSession(&item)?;

    let counters = Arc::new(Mutex::new(SegmentedCounters::default()));
    let handler_counters = Arc::clone(&counters);
    let shared_active: Arc<Mutex<Option<ActiveSegment>>> = Arc::new(Mutex::new(Some(active)));
    let handler_active = Arc::clone(&shared_active);
    let handler_paused = Arc::clone(&paused);
    let handler_crop = crop;
    let pause_shift = Arc::new(Mutex::new(0_i64));
    let pause_mark = Arc::new(Mutex::new(None::<i64>));
    let handler_shift = Arc::clone(&pause_shift);
    let handler_mark = Arc::clone(&pause_mark);
    let handler = windows::Foundation::TypedEventHandler::<
        windows::Graphics::Capture::Direct3D11CaptureFramePool,
        windows::core::IInspectable,
    >::new(move |sender, _args| {
        let outcome = (|| -> Result<()> {
            let Some(pool) = sender.as_ref() else {
                return Err(windows::core::Error::from(E_FAIL));
            };
            let frame = pool.TryGetNextFrame()?;
            let timestamp = frame.SystemRelativeTime()?.Duration;
            if handler_paused.load(Ordering::SeqCst) {
                let mut mark = handler_mark.lock().expect("pause mark poisoned");
                if mark.is_none() {
                    *mark = Some(timestamp);
                }
                return Ok(());
            } else if let Some(begin) = handler_mark.lock().expect("pause mark poisoned").take() {
                *handler_shift.lock().expect("pause shift poisoned") += timestamp - begin;
            }
            let surface = frame.Surface()?;
            let access: windows::Win32::System::WinRT::Direct3D11::IDirect3DDxgiInterfaceAccess =
                surface.cast()?;
            let texture: windows::Win32::Graphics::Direct3D11::ID3D11Texture2D =
                unsafe { access.GetInterface() }?;
            let encode_texture = if let Some((x, y, w, h)) = handler_crop {
                crop_texture_for_encode(&texture, x, y, w, h)?
            } else {
                texture
            };
            let buffer = unsafe {
                MFCreateDXGISurfaceBuffer(
                    &windows::Win32::Graphics::Direct3D11::ID3D11Texture2D::IID,
                    &encode_texture,
                    0,
                    false,
                )?
            };
            unsafe {
                let max_length = buffer.GetMaxLength()?;
                buffer.SetCurrentLength(max_length)?;
            }
            let sample: IMFSample = unsafe { MFCreateSample()? };

            let mut guard = handler_active
                .lock()
                .expect("segment writer mutex poisoned");
            let Some(segment) = guard.as_mut() else {
                return Ok(()); // rotation window; frame intentionally skipped
            };
            if segment.origin_100ns.is_none() {
                segment.origin_100ns = Some(timestamp);
            }
            let origin = segment.origin_100ns.unwrap_or(timestamp);
            unsafe {
                sample.AddBuffer(&buffer)?;
                let shift = *handler_shift.lock().expect("pause shift poisoned");
                sample.SetSampleTime(timestamp - origin - shift)?;
                sample.SetSampleDuration(10_000_000_i64 / frame_rate as i64)?;
                segment
                    .writer
                    .0
                    .WriteSample(segment.stream_index, &sample)?;
            }
            segment.last_timestamp_100ns = timestamp;
            segment.frames += 1;
            Ok(())
        })();

        let mut counters = handler_counters
            .lock()
            .expect("segment counters mutex poisoned");
        counters.frames_arrived += 1;
        match outcome {
            Ok(()) => counters.frames_written += 1,
            Err(err) => counters.last_handler_error = Some(err.to_string()),
        }
        Ok(())
    });

    let token = frame_pool.FrameArrived(&handler)?;
    session.StartCapture()?;

    let finalize_segment =
        |segment: ActiveSegment, manifest: &mut RecordingManifest| -> Result<SegmentInfo> {
            let writer = segment.writer.0;
            unsafe { writer.Finalize() }.map_err(|err| {
                windows::core::Error::new(
                    err.code(),
                    format!("finalize segment {}: {}", segment.index, err.message()),
                )
            })?;
            let file_name = format!("seg-{:06}.mp4", segment.index);
            let path = output_dir.join(&file_name);
            let decoded = verify_h264_decoding(&path).map_err(|err| {
                windows::core::Error::new(
                    err.code(),
                    format!(
                        "decode segment {} ({} bytes): {}",
                        segment.index,
                        std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0),
                        err.message()
                    ),
                )
            })?;
            if decoded.frames_decoded == 0 || !decoded.saw_nonzero_pixels {
                return Err(windows::core::Error::new(
                    E_FAIL,
                    format!(
                        "segment {} decoded {} frames, nonzero={}",
                        segment.index, decoded.frames_decoded, decoded.saw_nonzero_pixels
                    ),
                ));
            }
            let info = SegmentInfo {
                index: segment.index,
                file: file_name,
                state: "confirmed".to_string(),
                frames: decoded.frames_decoded,
                started_at_100ns: segment.origin_100ns.unwrap_or(0),
                ended_at_100ns: Some(segment.last_timestamp_100ns),
            };
            append_journal(manifest, &info)?;
            Ok(info)
        };

    let deadline = started + total_duration;
    let mut next_rotation = started + segment_duration;
    let mut next_index = 1_u32;
    let mut confirmed: Vec<SegmentInfo> = Vec::new();
    let mut last_disk_check = Instant::now();
    let window_hwnd = match source {
        VideoSource::Window { hwnd } => Some(HWND(hwnd as *mut std::ffi::c_void)),
        _ => None,
    };

    while Instant::now() < deadline && !stop.load(Ordering::SeqCst) {
        if let Some(pattern) = &pattern {
            pump_messages_briefly(pattern.hwnd());
        }
        let now = Instant::now();

        // 1. 低磁盘保护：周期检测磁盘剩余空间，低于 1 GiB 时主动安全停止，杜绝文件损坏
        if now.saturating_duration_since(last_disk_check) >= Duration::from_secs(1) {
            last_disk_check = now;
            if let Ok(free) = crate::disk::free_bytes(output_dir) {
                if crate::disk::status(free) == crate::disk::DiskStatus::Stop {
                    stop.store(true, Ordering::SeqCst);
                    break;
                }
            }
        }

        // 2. 窗口录制存活检查：若被捕获窗口已关闭/销毁，安全停止并保存已录制分片
        if let Some(hwnd) = window_hwnd {
            if unsafe { !windows::Win32::UI::WindowsAndMessaging::IsWindow(Some(hwnd)).as_bool() } {
                stop.store(true, Ordering::SeqCst);
                break;
            }
        }

        if now >= next_rotation && deadline - now > Duration::from_millis(500) {
            let replacement = open_segment(next_index)?;
            append_journal(
                &mut manifest,
                &SegmentInfo {
                    index: next_index,
                    file: format!("seg-{next_index:06}.mp4"),
                    state: "writing".to_string(),
                    frames: 0,
                    started_at_100ns: 0,
                    ended_at_100ns: None,
                },
            )?;
            let old = {
                let mut guard = shared_active.lock().expect("segment writer mutex poisoned");
                guard.replace(replacement)
            };
            if let Some(old) = old {
                let index = old.index;
                confirmed.push(finalize_segment(old, &mut manifest).map_err(|err| {
                    windows::core::Error::new(
                        err.code(),
                        format!("rotate finalize segment {index}: {}", err.message()),
                    )
                })?);
            }
            next_index += 1;
            next_rotation = now + segment_duration;
        } else {
            thread::sleep(Duration::from_millis(10));
        }
    }

    let _ = session.Close();
    let _ = frame_pool.RemoveFrameArrived(token);
    let _ = frame_pool.Close();
    let final_segment = {
        let mut guard = shared_active.lock().expect("segment writer mutex poisoned");
        guard.take()
    };
    if let Some(segment) = final_segment {
        let index = segment.index;
        confirmed.push(finalize_segment(segment, &mut manifest).map_err(|err| {
            windows::core::Error::new(
                err.code(),
                format!("final segment {index}: {}", err.message()),
            )
        })?);
    }
    if let Some(pattern) = pattern {
        pattern.close();
    }

    let (frames_arrived, frames_written, last_handler_error) = {
        let guard = counters.lock().expect("segment counters mutex poisoned");
        (
            guard.frames_arrived,
            guard.frames_written,
            guard.last_handler_error.clone(),
        )
    };
    if let Some(error) = last_handler_error {
        return Err(CaptureError::Windows(windows::core::Error::new(
            E_FAIL,
            format!(
                "segment handler error: {error}; arrived={frames_arrived}, written={frames_written}"
            ),
        )));
    }

    let frames_total: u64 = confirmed.iter().map(|segment| segment.frames).sum();
    Ok(SegmentedRecordingStats {
        output_dir: output_dir.to_string_lossy().into_owned(),
        width,
        height,
        segments: confirmed,
        frames_written: frames_total,
        elapsed: started.elapsed(),
    })
}

fn write_manifest_atomically(path: &Path, manifest: &RecordingManifest) -> Result<()> {
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(manifest)
        .map_err(|err| windows::core::Error::new(E_FAIL, err.to_string()))?;
    std::fs::write(&temporary, bytes)?;
    unsafe {
        MoveFileExW(
            &HSTRING::from(temporary.to_string_lossy().as_ref()),
            &HSTRING::from(path.to_string_lossy().as_ref()),
            MOVEFILE_REPLACE_EXISTING,
        )?;
    }
    Ok(())
}

/// Scans a segmented recording directory without modifying any file.
///
/// Every journaled segment is opened and decoded frame-by-frame regardless of
/// its journal state: a `writing` segment whose file happens to be complete
/// still counts as recoverable, while a `confirmed` segment that no longer
/// decodes is reported as broken. Original files are never rewritten here.
pub fn scan_segmented_recording(output_dir: &Path) -> Result<RecoveryReport> {
    let manifest_path = output_dir.join("manifest.json");
    let manifest_text = std::fs::read_to_string(&manifest_path)?;
    let manifest: RecordingManifest = serde_json::from_str(&manifest_text)
        .map_err(|err| windows::core::Error::new(E_FAIL, err.to_string()))?;

    let mut segments = Vec::new();
    let mut recoverable_frames = 0_u64;
    let mut broken_segments = Vec::new();
    for entry in &manifest.segments {
        let path = output_dir.join(&entry.file);
        let (decodable, decoded_frames, saw_nonzero_pixels, error) = if path.is_file() {
            match verify_h264_decoding(&path) {
                Ok(report) if report.frames_decoded > 0 && report.saw_nonzero_pixels => {
                    (true, report.frames_decoded, report.saw_nonzero_pixels, None)
                }
                Ok(report) => (
                    false,
                    report.frames_decoded,
                    report.saw_nonzero_pixels,
                    Some(format!(
                        "decoded {} frames, nonzero={}",
                        report.frames_decoded, report.saw_nonzero_pixels
                    )),
                ),
                Err(err) => (false, 0, false, Some(err.message().to_string())),
            }
        } else {
            (false, 0, false, Some("segment file is missing".to_string()))
        };

        if decodable {
            recoverable_frames += decoded_frames;
        } else {
            broken_segments.push(entry.index);
        }
        segments.push(SegmentRecoveryReport {
            index: entry.index,
            file: entry.file.clone(),
            journal_state: entry.state.clone(),
            decodable,
            decoded_frames,
            saw_nonzero_pixels,
            error,
        });
    }

    Ok(RecoveryReport {
        manifest_path: manifest_path.to_string_lossy().into_owned(),
        segments,
        recoverable_frames,
        broken_segments,
    })
}

fn pump_messages_briefly(hwnd: HWND) {
    unsafe {
        let mut message = MSG::default();
        while PeekMessageW(&mut message, Some(hwnd), 0, 0, PM_REMOVE).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}
