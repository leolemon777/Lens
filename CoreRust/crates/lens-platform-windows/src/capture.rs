//! Windows Graphics Capture probes and frame acquisition.

use std::thread;
use std::time::Duration;
use std::time::Instant;

use windows::core::{factory, Error, Interface, Result};
use windows::Foundation::TypedEventHandler;
use windows::Graphics::Capture::{
    Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession,
};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Win32::Foundation::{E_FAIL, RPC_E_CHANGED_MODE};
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_CPU_ACCESS_READ,
    D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::Win32::Graphics::Gdi::HMONITOR;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::System::WinRT::Direct3D11::{
    CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess,
};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

use crate::graphics::create_video_device;

/// A tightly packed BGRA8 frame copied out of a Windows Graphics Capture
/// texture. This is real captured desktop content, not a mock surface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedFrame {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum CaptureError {
    #[error("no capture frame arrived within {0:?}")]
    Timeout(Duration),
    #[error(transparent)]
    Windows(#[from] Error),
    #[error("filesystem error: {0}")]
    Io(#[from] std::io::Error),
}

/// Statistics from an event-driven capture burst. Callback thread ids prove
/// which OS threads delivered `FrameArrived`; a free-threaded frame pool must
/// invoke handlers off the creating thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameStreamStats {
    pub requested_duration: Duration,
    pub elapsed: Duration,
    pub worker_thread_id: u32,
    pub frames_arrived: u64,
    pub frames_drained: u64,
    pub callback_thread_ids: Vec<u32>,
}

#[derive(Default)]
struct FrameStreamCounters {
    frames_arrived: u64,
    frames_drained: u64,
    callback_thread_ids: Vec<u32>,
}

type CaptureResult<T> = std::result::Result<T, CaptureError>;

/// Reports whether Windows Graphics Capture can run in the current session.
///
/// The probe initializes an STA apartment for its own duration so it can be
/// called from plain test and tool threads. RPC_E_CHANGED_MODE means another
/// apartment model is already active on the thread; the WinRT call itself is
/// still valid in that state, so the probe continues.
pub fn is_wgc_supported() -> Result<bool> {
    unsafe {
        let apartment = CoInitializeEx(None, windows::Win32::System::Com::COINIT_APARTMENTTHREADED);
        if apartment.is_err() && apartment != RPC_E_CHANGED_MODE {
            return Err(Error::from(apartment));
        }
        let must_uninitialize = apartment.is_ok();

        let supported = GraphicsCaptureSession::IsSupported().unwrap_or(false);
        if must_uninitialize {
            CoUninitialize();
        }
        Ok(supported)
    }
}

/// Captures one frame from the primary monitor.
///
/// The whole WGC pipeline runs on a dedicated MTA thread so callers do not
/// need to manage COM apartment state. DPI awareness must already be enabled
/// by the process entry point for monitor geometry to be physical pixels.
pub fn capture_primary_monitor_frame(timeout: Duration) -> CaptureResult<CapturedFrame> {
    let handle = primary_monitor_handle().map_err(CaptureError::from)?;
    capture_monitor_frame(handle.0 as isize, timeout)
}

/// Captures one frame from the monitor identified by a runtime HMONITOR value.
pub fn capture_monitor_frame(
    monitor_handle: isize,
    timeout: Duration,
) -> CaptureResult<CapturedFrame> {
    let worker = thread::spawn(move || {
        capture_on_worker_thread(CaptureTarget::Monitor(monitor_handle), timeout)
    });
    worker
        .join()
        .map_err(|_| CaptureError::Windows(Error::from(E_FAIL)))?
}

/// Captures one frame from a top-level HWND via Windows Graphics Capture.
pub fn capture_window_frame(hwnd: isize, timeout: Duration) -> CaptureResult<CapturedFrame> {
    let worker =
        thread::spawn(move || capture_on_worker_thread(CaptureTarget::Window(hwnd), timeout));
    worker
        .join()
        .map_err(|_| CaptureError::Windows(Error::from(E_FAIL)))?
}

enum CaptureTarget {
    Monitor(isize),
    Window(isize),
}

/// Crops a packed BGRA frame to a monitor-local rectangle.
pub fn crop_frame(
    frame: &CapturedFrame,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) -> CaptureResult<CapturedFrame> {
    if width <= 0 || height <= 0 {
        return Err(CaptureError::Windows(Error::from(E_FAIL)));
    }
    let left = x.max(0) as u32;
    let top = y.max(0) as u32;
    let right = (x + width).clamp(0, frame.width as i32) as u32;
    let bottom = (y + height).clamp(0, frame.height as i32) as u32;
    if right <= left || bottom <= top {
        return Err(CaptureError::Windows(Error::from(E_FAIL)));
    }
    let crop_w = right - left;
    let crop_h = bottom - top;
    let mut bgra = vec![0_u8; (crop_w * crop_h * 4) as usize];
    for row in 0..crop_h {
        let src_start = (((top + row) * frame.width + left) * 4) as usize;
        let dst_start = (row * crop_w * 4) as usize;
        let len = (crop_w * 4) as usize;
        bgra[dst_start..dst_start + len].copy_from_slice(&frame.bgra[src_start..src_start + len]);
    }
    Ok(CapturedFrame {
        width: crop_w,
        height: crop_h,
        bgra,
    })
}

/// Runs an event-driven capture burst on the primary monitor.
///
/// Uses a free-threaded frame pool so `FrameArrived` is delivered on capture
/// runtime threads, exercising the callback-thread model the recorder will
/// need, and drains every frame inside the handler to keep the pool healthy.
/// The burst stops by closing the session, removing the handler, and closing
/// the frame pool in that order.
pub fn capture_primary_monitor_frame_stream(duration: Duration) -> CaptureResult<FrameStreamStats> {
    let worker = thread::spawn(move || capture_stream_on_worker_thread(duration));
    worker
        .join()
        .map_err(|_| CaptureError::Windows(Error::from(E_FAIL)))?
}

fn capture_stream_on_worker_thread(duration: Duration) -> CaptureResult<FrameStreamStats> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(Error::from(apartment).into());
    }
    let result = capture_stream_inner(duration);
    unsafe { CoUninitialize() };
    result
}

fn capture_stream_inner(duration: Duration) -> CaptureResult<FrameStreamStats> {
    let worker_thread_id = unsafe { GetCurrentThreadId() };
    let started = Instant::now();

    let created = create_video_device()?;
    let dxgi_device: IDXGIDevice = created.device.cast()?;
    let d3d_device: IDirect3DDevice =
        unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi_device) }?.cast()?;

    let monitor = primary_monitor_handle()?;
    let interop: IGraphicsCaptureItemInterop =
        factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
    let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(monitor) }?;
    let size = item.Size()?;

    let frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        &d3d_device,
        DirectXPixelFormat::B8G8R8A8UIntNormalized,
        2,
        size,
    )?;
    let session: GraphicsCaptureSession = frame_pool.CreateCaptureSession(&item)?;

    let counters = std::sync::Arc::new(std::sync::Mutex::new(FrameStreamCounters::default()));
    let handler_counters = std::sync::Arc::clone(&counters);
    let handler = TypedEventHandler::<Direct3D11CaptureFramePool, windows::core::IInspectable>::new(
        move |sender, _args| {
            let thread_id = unsafe { GetCurrentThreadId() };
            let pool = sender.as_ref();
            let drained = pool
                .map(Direct3D11CaptureFramePool::TryGetNextFrame)
                .map(|frame| frame.is_ok());

            let mut counters = handler_counters
                .lock()
                .expect("frame counters mutex poisoned");
            counters.frames_arrived += 1;
            if drained == Some(true) {
                counters.frames_drained += 1;
            }
            if !counters.callback_thread_ids.contains(&thread_id) {
                counters.callback_thread_ids.push(thread_id);
            }
            Ok(())
        },
    );

    let token = frame_pool.FrameArrived(&handler)?;
    session.StartCapture()?;
    thread::sleep(duration);

    // Stop semantics: close the session first so no new frames enter the pool,
    // remove the handler, then close the pool itself.
    let _ = session.Close();
    let _ = frame_pool.RemoveFrameArrived(token);
    let _ = frame_pool.Close();

    let counters = {
        let guard = counters.lock().expect("frame counters mutex poisoned");
        FrameStreamCounters {
            frames_arrived: guard.frames_arrived,
            frames_drained: guard.frames_drained,
            callback_thread_ids: guard.callback_thread_ids.clone(),
        }
    };
    Ok(FrameStreamStats {
        requested_duration: duration,
        elapsed: started.elapsed(),
        worker_thread_id,
        frames_arrived: counters.frames_arrived,
        frames_drained: counters.frames_drained,
        callback_thread_ids: counters.callback_thread_ids,
    })
}

fn capture_on_worker_thread(
    target: CaptureTarget,
    timeout: Duration,
) -> CaptureResult<CapturedFrame> {
    // WGC WinRT objects require an initialized apartment; MTA matches the
    // free-threaded capture runtime used by the C++ prototype.
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(Error::from(apartment).into());
    }
    let result = capture_frame_inner(target, timeout);
    unsafe { CoUninitialize() };
    result
}

fn capture_frame_inner(target: CaptureTarget, timeout: Duration) -> CaptureResult<CapturedFrame> {
    let created = create_video_device()?;
    let dxgi_device: IDXGIDevice = created.device.cast()?;
    let d3d_device: IDirect3DDevice =
        unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi_device) }?.cast()?;
    let interop: IGraphicsCaptureItemInterop =
        factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
    let item: GraphicsCaptureItem = match target {
        CaptureTarget::Monitor(handle) => {
            unsafe { interop.CreateForMonitor(HMONITOR(handle as *mut _)) }?
        }
        CaptureTarget::Window(handle) => {
            unsafe { interop.CreateForWindow(windows::Win32::Foundation::HWND(handle as *mut _)) }?
        }
    };
    let size = item.Size()?;

    let frame_pool = Direct3D11CaptureFramePool::Create(
        &d3d_device,
        DirectXPixelFormat::B8G8R8A8UIntNormalized,
        2,
        size,
    )?;
    let session: GraphicsCaptureSession = frame_pool.CreateCaptureSession(&item)?;
    session.StartCapture()?;

    let deadline = std::time::Instant::now() + timeout;
    let frame = loop {
        match frame_pool.TryGetNextFrame() {
            Ok(frame) => break frame,
            Err(_) if std::time::Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => {
                let _ = session.Close();
                let _ = frame_pool.Close();
                return Err(CaptureError::Timeout(timeout));
            }
        }
    };

    let surface = frame.Surface()?;
    let access: IDirect3DDxgiInterfaceAccess = surface.cast()?;
    let texture: ID3D11Texture2D = unsafe { access.GetInterface() }?;
    let result = copy_texture_to_staging(&created.device, &created.context, &texture);

    // Release the frame back to the pool before closing the pipeline.
    drop(frame);
    let _ = session.Close();
    let _ = frame_pool.Close();

    let bgra = result?;
    Ok(CapturedFrame {
        width: size.Width as u32,
        height: size.Height as u32,
        bgra,
    })
}

pub(crate) fn primary_monitor_handle() -> Result<HMONITOR> {
    let displays = crate::display::enumerate_displays()?;
    let primary = displays
        .iter()
        .find(|display| display.is_primary)
        .or_else(|| displays.first())
        .ok_or_else(|| Error::from(E_FAIL))?;
    Ok(HMONITOR(primary.handle as *mut _))
}

fn copy_texture_to_staging(
    device: &ID3D11Device,
    context: &ID3D11DeviceContext,
    source: &ID3D11Texture2D,
) -> Result<Vec<u8>> {
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe { source.GetDesc(&mut desc) };
    let height = desc.Height as usize;

    let staging_desc = D3D11_TEXTURE2D_DESC {
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
        MiscFlags: 0,
        ..desc
    };

    let mut staging: Option<ID3D11Texture2D> = None;
    unsafe { device.CreateTexture2D(&staging_desc, None, Some(&mut staging))? };
    let staging = staging.ok_or_else(|| Error::from(E_FAIL))?;

    let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe {
        context.CopyResource(&staging, source);
        context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
    }

    let row_bytes = desc.Width as usize * 4;
    let mut pixels = vec![0_u8; row_bytes * height];
    for row in 0..height {
        let source_row = unsafe {
            std::slice::from_raw_parts(
                (mapped.pData as *const u8).add(row * mapped.RowPitch as usize),
                row_bytes,
            )
        };
        pixels[row * row_bytes..(row + 1) * row_bytes].copy_from_slice(source_row);
    }

    unsafe { context.Unmap(&staging, 0) };
    Ok(pixels)
}

#[cfg(test)]
mod tests {
    use super::{crop_frame, CapturedFrame};

    fn solid_frame(width: u32, height: u32, b: u8, g: u8, r: u8, a: u8) -> CapturedFrame {
        let mut bgra = Vec::with_capacity((width * height * 4) as usize);
        for _ in 0..(width * height) {
            bgra.extend_from_slice(&[b, g, r, a]);
        }
        CapturedFrame {
            width,
            height,
            bgra,
        }
    }

    #[test]
    fn crop_keeps_requested_physical_size() {
        let frame = solid_frame(100, 80, 10, 20, 30, 255);
        let cropped = crop_frame(&frame, 10, 15, 40, 25).expect("crop");
        assert_eq!(cropped.width, 40);
        assert_eq!(cropped.height, 25);
        assert_eq!(cropped.bgra.len(), 40 * 25 * 4);
        assert_eq!(&cropped.bgra[0..4], &[10, 20, 30, 255]);
    }

    #[test]
    fn crop_rejects_empty_rect() {
        let frame = solid_frame(64, 64, 0, 0, 0, 255);
        assert!(crop_frame(&frame, 0, 0, 0, 10).is_err());
        assert!(crop_frame(&frame, 80, 80, 10, 10).is_err());
    }
}
