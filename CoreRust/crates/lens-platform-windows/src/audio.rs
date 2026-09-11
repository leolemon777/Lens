//! WASAPI dual-track audio capture and loopback tone playback.

use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use serde::{Deserialize, Serialize};

use windows::core::{Result, GUID, PWSTR};
use windows::Win32::Foundation::E_FAIL;
use windows::Win32::Media::Audio::{
    eCapture, eConsole, eRender, IAudioCaptureClient, IAudioClient, IAudioRenderClient,
    IMMDevice, IMMDeviceEnumerator, AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_LOOPBACK, DEVICE_STATE_ACTIVE, WAVEFORMATEX, WAVE_FORMAT_PCM,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};

const SAMPLE_RATE: u32 = 48_000;
const CHANNELS: u16 = 2;
const BITS_PER_SAMPLE: u16 = 16;
const BLOCK_ALIGN: u16 = (CHANNELS * BITS_PER_SAMPLE) / 8;
const BYTES_PER_SECOND: u32 = SAMPLE_RATE * BLOCK_ALIGN as u32;

static MIC_PEAK: AtomicU32 = AtomicU32::new(0);
static SYS_PEAK: AtomicU32 = AtomicU32::new(0);

/// Latest WASAPI peaks as 0..1 for the recording control bar.
pub fn current_levels() -> (f32, f32) {
    (
        SYS_PEAK.load(Ordering::Relaxed) as f32 / 10_000.0,
        MIC_PEAK.load(Ordering::Relaxed) as f32 / 10_000.0,
    )
}

fn store_peak(loopback: bool, packet: &[u8]) {
    let mut max_abs = 0_i32;
    for sample in packet.chunks_exact(2) {
        let value = i16::from_le_bytes([sample[0], sample[1]]) as i32;
        max_abs = max_abs.max(value.abs());
    }
    let peak = ((max_abs as u32) * 10_000 / i16::MAX as u32).min(10_000);
    if loopback {
        SYS_PEAK.store(peak, Ordering::Relaxed);
    } else {
        MIC_PEAK.store(peak, Ordering::Relaxed);
    }
}

/// Discovered WASAPI audio endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioDeviceInfo {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub flow: String,
}

/// Multi-track audio configuration for a recording session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioCaptureConfig {
    pub enable_system: bool,
    pub enable_mic: bool,
    pub system_device_id: Option<String>,
    pub mic_device_id: Option<String>,
}

impl Default for AudioCaptureConfig {
    fn default() -> Self {
        Self {
            enable_system: true,
            enable_mic: true,
            system_device_id: None,
            mic_device_id: None,
        }
    }
}

/// Enumerates active audio endpoints (system output renderers and mic capture devices).
pub fn enumerate_audio_devices() -> Result<Vec<AudioDeviceInfo>> {
    let worker = thread::spawn(enumerate_audio_devices_on_worker_thread);
    worker
        .join()
        .unwrap_or_else(|_| Err(windows::core::Error::from(E_FAIL)))
}

fn enumerate_audio_devices_on_worker_thread() -> Result<Vec<AudioDeviceInfo>> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(windows::core::Error::from(apartment));
    }
    let result = enumerate_audio_devices_inner();
    unsafe { CoUninitialize() };
    result
}

fn read_device_friendly_name(device: &IMMDevice) -> Result<String> {
    unsafe {
        let store = device.OpenPropertyStore(windows::Win32::System::Com::STGM_READ)?;
        let key = windows::Win32::Foundation::PROPERTYKEY {
            fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
            pid: 14,
        };
        let prop = store.GetValue(&key)?;
        let pwstr = prop.Anonymous.Anonymous.Anonymous.pwszVal;
        if !pwstr.0.is_null() {
            Ok(pwstr_to_string(pwstr))
        } else {
            Err(windows::core::Error::from(E_FAIL))
        }
    }
}

fn enumerate_audio_devices_inner() -> Result<Vec<AudioDeviceInfo>> {
    let mmdevice_clsid = GUID::from_u128(0xbcde_0395_e52f_467c_8e3d_c457_9291_692e);
    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&mmdevice_clsid, None, CLSCTX_ALL)? };
    let mut list = Vec::new();

    for (flow, flow_name) in [(eRender, "render"), (eCapture, "capture")] {
        let default_id = unsafe {
            enumerator
                .GetDefaultAudioEndpoint(flow, eConsole)
                .and_then(|dev| dev.GetId())
                .map(pwstr_to_string)
                .ok()
        };
        let collection = unsafe { enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE)? };
        let count = unsafe { collection.GetCount()? };
        for i in 0..count {
            let dev = unsafe { collection.Item(i)? };
            let id = pwstr_to_string(unsafe { dev.GetId()? });
            let is_default = default_id.as_deref() == Some(&id);
            let name = read_device_friendly_name(&dev).unwrap_or_else(|_| {
                if flow_name == "render" {
                    format!("扬声器 / 系统声音 ({})", i + 1)
                } else {
                    format!("麦克风 ({})", i + 1)
                }
            });
            list.push(AudioDeviceInfo {
                id,
                name,
                is_default,
                flow: flow_name.to_string(),
            });
        }
    }
    Ok(list)
}

/// Statistics for one captured audio track.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioTrackStats {
    pub path: String,
    pub endpoint_id: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    pub frames: u64,
    pub bytes: u64,
    pub start_qpc: i64,
    pub end_qpc: i64,
    pub qpc_frequency: i64,
    pub first_device_position: Option<u64>,
    pub first_packet_qpc: Option<u64>,
    pub saw_nonzero_samples: bool,
}

/// Statistics for an audio capture pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DualAudioStats {
    pub system: Option<AudioTrackStats>,
    pub microphone: Option<AudioTrackStats>,
    pub tone_played: bool,
    pub elapsed: Duration,
}

fn pcm_format() -> WAVEFORMATEX {
    WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_PCM as u16,
        nChannels: CHANNELS,
        nSamplesPerSec: SAMPLE_RATE,
        nAvgBytesPerSec: BYTES_PER_SECOND,
        nBlockAlign: BLOCK_ALIGN,
        wBitsPerSample: BITS_PER_SAMPLE,
        cbSize: 0,
    }
}

fn now_qpc() -> Result<i64> {
    let mut value = 0_i64;
    unsafe { QueryPerformanceCounter(&mut value)? };
    Ok(value)
}

fn qpc_frequency() -> Result<i64> {
    let mut value = 0_i64;
    unsafe { QueryPerformanceFrequency(&mut value)? };
    Ok(value)
}

fn pwstr_to_string(value: PWSTR) -> String {
    unsafe {
        let mut length = 0_usize;
        while *value.0.add(length) != 0 {
            length += 1;
        }
        String::from_utf16_lossy(std::slice::from_raw_parts(value.0, length))
    }
}

pub fn capture_dual_audio(
    output_dir: &Path,
    duration: Duration,
    play_tone: bool,
) -> Result<DualAudioStats> {
    capture_dual_audio_until(
        output_dir,
        duration,
        play_tone,
        Arc::new(AtomicBool::new(false)),
        Arc::new(AtomicBool::new(false)),
    )
}

pub fn capture_dual_audio_until(
    output_dir: &Path,
    max_duration: Duration,
    play_tone: bool,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
) -> Result<DualAudioStats> {
    capture_audio_with_config_until(
        output_dir,
        max_duration,
        play_tone,
        stop,
        paused,
        &AudioCaptureConfig::default(),
    )
}

/// Multi-track capture honoring enable flags and device selections.
pub fn capture_audio_with_config_until(
    output_dir: &Path,
    max_duration: Duration,
    play_tone: bool,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    config: &AudioCaptureConfig,
) -> Result<DualAudioStats> {
    std::fs::create_dir_all(output_dir)?;
    let system_path = output_dir.join("system-loopback.wav");
    let microphone_path = output_dir.join("microphone.wav");
    let started = Instant::now();
    let duration = max_duration;

    let tone = if play_tone && config.enable_system {
        Some(thread::spawn(move || {
            let _ = play_reference_tone(duration);
        }))
    } else {
        None
    };

    let system_thread = if config.enable_system {
        let path = system_path.clone();
        let stop = Arc::clone(&stop);
        let paused = Arc::clone(&paused);
        let endpoint_id = config.system_device_id.clone();
        Some(thread::spawn(move || {
            capture_endpoint(true, &path, duration, stop, paused, endpoint_id)
        }))
    } else {
        None
    };

    let microphone_thread = if config.enable_mic {
        let path = microphone_path.clone();
        let stop = Arc::clone(&stop);
        let paused = Arc::clone(&paused);
        let endpoint_id = config.mic_device_id.clone();
        Some(thread::spawn(move || {
            capture_endpoint(false, &path, duration, stop, paused, endpoint_id)
        }))
    } else {
        None
    };

    if let Some(tone) = tone {
        tone.join()
            .map_err(|_| windows::core::Error::from(E_FAIL))?;
    }

    let system = if let Some(th) = system_thread {
        Some(th.join().map_err(|_| windows::core::Error::from(E_FAIL))??)
    } else {
        None
    };

    let microphone = if let Some(th) = microphone_thread {
        match th.join() {
            Ok(Ok(stats)) => Some(stats),
            Ok(Err(err))
                if err.code() == AUDCLNT_E_DEVICE_INVALIDATED || err.code() == E_NOTFOUND =>
            {
                None
            }
            Ok(Err(err)) => return Err(err),
            Err(_) => return Err(windows::core::Error::from(E_FAIL)),
        }
    } else {
        None
    };

    Ok(DualAudioStats {
        system,
        microphone,
        tone_played: play_tone,
        elapsed: started.elapsed(),
    })
}

// Endpoint activation returns this when no default capture device exists.
const AUDCLNT_E_DEVICE_INVALIDATED: windows::core::HRESULT =
    windows::core::HRESULT(0x8880_0004_u32 as i32);
const E_NOTFOUND: windows::core::HRESULT = windows::core::HRESULT(0x8007_0490_u32 as i32);

fn capture_endpoint(
    loopback: bool,
    path: &Path,
    duration: Duration,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    endpoint_id: Option<String>,
) -> Result<AudioTrackStats> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(windows::core::Error::from(apartment));
    }
    let result = capture_endpoint_inner(loopback, path, duration, stop, paused, endpoint_id);
    unsafe { CoUninitialize() };
    result
}

fn capture_endpoint_inner(
    loopback: bool,
    path: &Path,
    duration: Duration,
    stop: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    endpoint_id: Option<String>,
) -> Result<AudioTrackStats> {
    let mmdevice_clsid = GUID::from_u128(0xbcde_0395_e52f_467c_8e3d_c457_9291_692e);
    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&mmdevice_clsid, None, CLSCTX_ALL)? };
    let endpoint = if let Some(id) = endpoint_id.as_deref() {
        let wide: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe { enumerator.GetDevice(windows::core::PCWSTR(wide.as_ptr())) }.unwrap_or_else(|_| {
            unsafe {
                enumerator
                    .GetDefaultAudioEndpoint(if loopback { eRender } else { eCapture }, eConsole)
                    .expect("fallback default endpoint")
            }
        })
    } else {
        unsafe {
            enumerator.GetDefaultAudioEndpoint(if loopback { eRender } else { eCapture }, eConsole)?
        }
    };
    let endpoint_id = pwstr_to_string(unsafe { endpoint.GetId()? });

    let client: IAudioClient = unsafe { endpoint.Activate(CLSCTX_ALL, None)? };
    let format = pcm_format();
    let stream_flags = if loopback {
        AUDCLNT_STREAMFLAGS_LOOPBACK
    } else {
        0
    };
    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            stream_flags,
            10_000_000 / 100, // 100 ms reference-time buffer
            0,
            &format,
            None,
        )?;
    }
    let capture: IAudioCaptureClient = unsafe { client.GetService()? };

    let start_qpc = now_qpc()?;
    let frequency = qpc_frequency()?;
    let deadline = Instant::now() + duration;
    let mut pcm = Vec::new();
    let mut first_device_position = None;
    let mut first_packet_qpc = None;
    let mut saw_nonzero = false;

    unsafe { client.Start()? };
    while Instant::now() < deadline && !stop.load(Ordering::SeqCst) {
        let mut data = std::ptr::null_mut::<u8>();
        let mut frames = 0_u32;
        let mut flags = 0_u32;
        let mut device_position = 0_u64;
        let mut packet_qpc = 0_u64;
        let has_packet = unsafe {
            capture.GetBuffer(
                &mut data,
                &mut frames,
                &mut flags,
                Some(&mut device_position),
                Some(&mut packet_qpc),
            )
        };
        match has_packet {
            Ok(()) => {
                let byte_len = frames as usize * BLOCK_ALIGN as usize;
                if paused.load(Ordering::SeqCst) {
                    // Drain the packet so the capture buffer does not overflow.
                } else if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 == 0 && byte_len > 0 {
                    let nonzero = unsafe {
                        std::slice::from_raw_parts(data, byte_len)
                            .iter()
                            .any(|byte| *byte != 0)
                    };
                    if nonzero {
                        saw_nonzero = true;
                    }
                    let packet = unsafe { std::slice::from_raw_parts(data, byte_len) };
                    store_peak(loopback, packet);
                    pcm.extend_from_slice(packet);
                } else {
                    pcm.extend(std::iter::repeat_n(0_u8, byte_len));
                }
                first_device_position.get_or_insert(device_position);
                first_packet_qpc.get_or_insert(packet_qpc);
                unsafe { capture.ReleaseBuffer(frames)? };
            }
            Err(_) => thread::sleep(Duration::from_millis(10)),
        }
    }
    let end_qpc = now_qpc()?;
    unsafe {
        let _ = client.Stop();
    }

    let frames = (pcm.len() / BLOCK_ALIGN as usize) as u64;
    write_wav(path, &pcm)?;
    Ok(AudioTrackStats {
        path: path.to_string_lossy().into_owned(),
        endpoint_id,
        sample_rate: SAMPLE_RATE,
        channels: CHANNELS,
        bits_per_sample: BITS_PER_SAMPLE,
        frames,
        bytes: pcm.len() as u64,
        start_qpc,
        end_qpc,
        qpc_frequency: frequency,
        first_device_position,
        first_packet_qpc,
        saw_nonzero_samples: saw_nonzero,
    })
}

fn play_reference_tone(duration: Duration) -> Result<()> {
    let apartment = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if apartment.is_err() {
        return Err(windows::core::Error::from(apartment));
    }
    let result = play_tone_inner(duration);
    unsafe { CoUninitialize() };
    result
}

fn play_tone_inner(duration: Duration) -> Result<()> {
    let mmdevice_clsid = GUID::from_u128(0xbcde_0395_e52f_467c_8e3d_c457_9291_692e);
    let enumerator: IMMDeviceEnumerator =
        unsafe { CoCreateInstance(&mmdevice_clsid, None, CLSCTX_ALL)? };
    let endpoint = unsafe { enumerator.GetDefaultAudioEndpoint(eRender, eConsole)? };
    let client: IAudioClient = unsafe { endpoint.Activate(CLSCTX_ALL, None)? };
    let format = pcm_format();
    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            0,
            10_000_000 / 10,
            0,
            &format,
            None,
        )?;
    }
    let render: IAudioRenderClient = unsafe { client.GetService()? };
    let buffer_frames = unsafe { client.GetBufferSize()? } as usize;
    let mut phase = 0.0_f64;
    let deadline = Instant::now() + duration;

    unsafe {
        fill_tone(&render, buffer_frames, &mut phase);
        client.Start()?;
        while Instant::now() < deadline {
            let padding = client.GetCurrentPadding()? as usize;
            let available = buffer_frames - padding;
            if available > 0 {
                write_tone_frames(&render, available, &mut phase)?;
            }
            thread::sleep(Duration::from_millis(10));
        }
        client.Stop()?;
    }
    Ok(())
}

unsafe fn fill_tone(render: &IAudioRenderClient, frames: usize, phase: &mut f64) {
    unsafe { write_tone_frames(render, frames, phase) }.expect("prefill tone buffer");
}

unsafe fn write_tone_frames(
    render: &IAudioRenderClient,
    frames: usize,
    phase: &mut f64,
) -> Result<()> {
    let data = unsafe { render.GetBuffer(frames as u32)? };
    let slice = unsafe { std::slice::from_raw_parts_mut(data, frames * BLOCK_ALIGN as usize) };
    for offset in (0..slice.len()).step_by(BLOCK_ALIGN as usize) {
        let frame = &mut slice[offset..offset + BLOCK_ALIGN as usize];
        let value = (phase.sin() * 6000.0) as i16;
        let bytes = value.to_le_bytes();
        frame[0] = bytes[0];
        frame[1] = bytes[1];
        frame[2] = bytes[0];
        frame[3] = bytes[1];
        *phase += 2.0 * std::f64::consts::PI * 440.0 / SAMPLE_RATE as f64;
        if *phase > 2.0 * std::f64::consts::PI {
            *phase -= 2.0 * std::f64::consts::PI;
        }
    }
    unsafe { render.ReleaseBuffer(frames as u32, 0) }
}

fn write_wav(path: &Path, pcm: &[u8]) -> Result<()> {
    let mut file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let data_len = pcm.len() as u32;
    let write_header = |file: &mut std::io::BufWriter<std::fs::File>| -> std::io::Result<()> {
        let riff_size = 36 + data_len;
        file.write_all(b"RIFF")?;
        file.write_all(&riff_size.to_le_bytes())?;
        file.write_all(b"WAVE")?;
        file.write_all(b"fmt ")?;
        file.write_all(&16_u32.to_le_bytes())?;
        file.write_all(&(WAVE_FORMAT_PCM as u16).to_le_bytes())?;
        file.write_all(&CHANNELS.to_le_bytes())?;
        file.write_all(&SAMPLE_RATE.to_le_bytes())?;
        file.write_all(&BYTES_PER_SECOND.to_le_bytes())?;
        file.write_all(&BLOCK_ALIGN.to_le_bytes())?;
        file.write_all(&BITS_PER_SAMPLE.to_le_bytes())?;
        file.write_all(b"data")?;
        file.write_all(&data_len.to_le_bytes())
    };
    write_header(&mut file).map_err(|err| windows::core::Error::new(E_FAIL, err.to_string()))?;
    std::io::Write::write_all(&mut file, pcm)
        .map_err(|err| windows::core::Error::new(E_FAIL, err.to_string()))?;
    Ok(())
}
