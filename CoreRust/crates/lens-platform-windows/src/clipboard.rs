//! System clipboard helpers for captured PNG images.

use windows::core::{Error, Result, HRESULT};
use windows::Win32::Foundation::{HANDLE, HWND};
use windows::Win32::Graphics::Gdi::{BITMAPINFOHEADER, BI_RGB};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};

/// Copies a PNG (and a CF_DIB fallback) onto the Windows clipboard.
pub fn copy_png(png: &[u8], width: u32, height: u32, bgra: &[u8]) -> Result<()> {
    unsafe {
        OpenClipboard(Some(HWND::default()))?;
        let _guard = ClipboardGuard;
        EmptyClipboard()?;
        set_hglobal(png_format()?, png)?;
        let dib = bgra_to_dib(width, height, bgra)?;
        set_hglobal(8, &dib)?;
    }
    Ok(())
}

fn png_format() -> Result<u32> {
    let format = unsafe { RegisterClipboardFormatW(windows::core::w!("PNG")) };
    if format == 0 {
        Err(Error::from_thread())
    } else {
        Ok(format)
    }
}

unsafe fn set_hglobal(format: u32, bytes: &[u8]) -> Result<()> {
    let alloc = GlobalAlloc(GMEM_MOVEABLE, bytes.len())?;
    let ptr = GlobalLock(alloc);
    if ptr.is_null() {
        return Err(Error::from(HRESULT(0x8007_000E_u32 as i32)));
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, bytes.len());
    let _ = GlobalUnlock(alloc);
    SetClipboardData(format, Some(HANDLE(alloc.0)))?;
    Ok(())
}

fn bgra_to_dib(width: u32, height: u32, bgra: &[u8]) -> Result<Vec<u8>> {
    let stride = width as usize * 4;
    let expected = stride * height as usize;
    if bgra.len() < expected {
        return Err(Error::new(
            HRESULT(0x8007_0057_u32 as i32),
            "clipboard DIB is smaller than the captured frame",
        ));
    }
    let header_size = std::mem::size_of::<BITMAPINFOHEADER>();
    let mut dib = vec![0_u8; header_size + expected];
    let header = BITMAPINFOHEADER {
        biSize: header_size as u32,
        biWidth: width as i32,
        biHeight: -(height as i32),
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB.0 as u32,
        biSizeImage: expected as u32,
        ..Default::default()
    };
    unsafe {
        std::ptr::copy_nonoverlapping(
            (&header as *const BITMAPINFOHEADER).cast::<u8>(),
            dib.as_mut_ptr(),
            header_size,
        );
    }
    dib[header_size..].copy_from_slice(&bgra[..expected]);
    Ok(dib)
}

struct ClipboardGuard;

impl Drop for ClipboardGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}
