//! DXGI adapter inventory and D3D11 device lifecycle.

use windows::core::{Error, Result};
use windows::Win32::Foundation::{E_FAIL, HMODULE};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE, D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP, D3D_FEATURE_LEVEL,
    D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
    D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_SDK_VERSION,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIFactory1, DXGI_ADAPTER_DESC1, DXGI_OUTPUT_DESC,
};

/// Runtime snapshot of one DXGI adapter and its outputs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterInfo {
    pub description: String,
    pub dedicated_video_memory_bytes: usize,
    pub outputs: Vec<OutputInfo>,
}

/// Runtime snapshot of one DXGI output attached to an adapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputInfo {
    pub device_name: String,
    pub attached_to_desktop: bool,
    pub desktop_left: i32,
    pub desktop_top: i32,
    pub desktop_right: i32,
    pub desktop_bottom: i32,
    pub rotation: u32,
}

/// Capabilities of a created D3D11 device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceCapabilities {
    pub hardware: bool,
    pub video_support: bool,
    pub feature_level: u32,
}

/// An initialized D3D11 device and its immediate context.
pub struct CreatedDevice {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    pub capabilities: DeviceCapabilities,
}

/// Enumerates DXGI adapters and outputs in desktop coordinates.
pub fn enumerate_adapters() -> Result<Vec<AdapterInfo>> {
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1() }?;
    let mut adapters = Vec::new();
    for adapter_index in 0_u32.. {
        let adapter = match unsafe { factory.EnumAdapters1(adapter_index) } {
            Ok(adapter) => adapter,
            Err(_) => break,
        };
        let desc: DXGI_ADAPTER_DESC1 = unsafe { adapter.GetDesc1() }?;

        let mut outputs = Vec::new();
        for output_index in 0_u32.. {
            let output = match unsafe { adapter.EnumOutputs(output_index) } {
                Ok(output) => output,
                Err(_) => break,
            };
            let output_desc: DXGI_OUTPUT_DESC = unsafe { output.GetDesc() }?;
            outputs.push(OutputInfo {
                device_name: utf16_to_string(&output_desc.DeviceName),
                attached_to_desktop: output_desc.AttachedToDesktop.as_bool(),
                desktop_left: output_desc.DesktopCoordinates.left,
                desktop_top: output_desc.DesktopCoordinates.top,
                desktop_right: output_desc.DesktopCoordinates.right,
                desktop_bottom: output_desc.DesktopCoordinates.bottom,
                rotation: output_desc.Rotation.0 as u32,
            });
        }
        adapters.push(AdapterInfo {
            description: utf16_to_string(&desc.Description),
            dedicated_video_memory_bytes: desc.DedicatedVideoMemory,
            outputs,
        });
    }
    Ok(adapters)
}

/// Creates the best available device for capture and encode work.
///
/// Hardware rendering with video support is preferred. If the driver rejects
/// the video capability flag, creation retries with BGRA support only so the
/// failure is observable instead of silently degrading.
pub fn create_video_device() -> Result<CreatedDevice> {
    try_create_device(D3D_DRIVER_TYPE_HARDWARE, true)
        .or_else(|_| try_create_device(D3D_DRIVER_TYPE_HARDWARE, false))
}

/// Creates a WARP device for tests and machines without a usable GPU.
pub fn create_warp_device() -> Result<CreatedDevice> {
    try_create_device(D3D_DRIVER_TYPE_WARP, false)
}

fn try_create_device(driver_type: D3D_DRIVER_TYPE, video_support: bool) -> Result<CreatedDevice> {
    let mut flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    if video_support {
        flags |= D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    }
    let feature_levels = [D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0];
    let mut device: Option<ID3D11Device> = None;
    let mut context: Option<ID3D11DeviceContext> = None;
    let mut feature_level = D3D_FEATURE_LEVEL(0);

    unsafe {
        D3D11CreateDevice(
            None,
            driver_type,
            HMODULE::default(),
            flags,
            Some(&feature_levels),
            D3D11_SDK_VERSION,
            Some(&mut device),
            Some(&mut feature_level),
            Some(&mut context),
        )?;
    }

    let device = device.ok_or_else(|| Error::from(E_FAIL))?;
    let context = context.ok_or_else(|| Error::from(E_FAIL))?;
    Ok(CreatedDevice {
        device,
        context,
        capabilities: DeviceCapabilities {
            hardware: driver_type == D3D_DRIVER_TYPE_HARDWARE,
            video_support,
            feature_level: feature_level.0 as u32,
        },
    })
}

fn utf16_to_string(value: &[u16]) -> String {
    let end = value
        .iter()
        .position(|char| *char == 0)
        .unwrap_or(value.len());
    String::from_utf16_lossy(&value[..end])
}

#[cfg(test)]
mod tests {
    use super::utf16_to_string;

    #[test]
    fn converts_terminated_utf16_device_names() {
        let mut name = [0_u16; 32];
        name[..5].copy_from_slice(&[0x5C, 0x5C, 0x2E, 0x5C, 0x30]);
        assert_eq!(utf16_to_string(&name), "\\\\.\\0");
    }

    #[test]
    fn converts_unterminated_utf16_without_panicking() {
        assert_eq!(utf16_to_string(&[0x4C, 0x45, 0x4E, 0x53]), "LENS");
    }
}
