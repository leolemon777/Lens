//! Region and display still capture into packed PNG bytes.

use std::io::Cursor;
use std::time::Duration;

use crate::capture::{self, CapturedFrame};
use crate::display::{self, DisplayInfo};
use crate::overlay::PhysicalRegion;

#[derive(Debug, Clone)]
pub struct ScreenshotPng {
    pub width: u32,
    pub height: u32,
    pub png: Vec<u8>,
    pub bgra: Vec<u8>,
    pub display_left: i32,
    pub display_top: i32,
}

#[derive(Debug, thiserror::Error)]
pub enum ScreenshotError {
    #[error(transparent)]
    Capture(#[from] capture::CaptureError),
    #[error("no display intersects the selection")]
    NoDisplay,
    #[error("png encode failed: {0}")]
    Png(String),
}

/// Captures the monitor covering `region` and crops to that physical rectangle.
pub fn capture_region(region: PhysicalRegion) -> Result<ScreenshotPng, ScreenshotError> {
    let displays = display::enumerate_displays().map_err(capture::CaptureError::from)?;
    let display = display_covering(&displays, region).ok_or(ScreenshotError::NoDisplay)?;
    let frame = capture::capture_monitor_frame(display.handle, Duration::from_secs(3))?;
    let local_x = region.x - display.left;
    let local_y = region.y - display.top;
    let cropped = capture::crop_frame(&frame, local_x, local_y, region.width, region.height)?;
    encode_png(cropped, display.left, display.top)
}

pub fn capture_window(hwnd: isize) -> Result<ScreenshotPng, ScreenshotError> {
    let frame = capture::capture_window_frame(hwnd, Duration::from_secs(3))?;
    encode_png(frame, 0, 0)
}

/// Placement of one window in desktop physical pixels.
#[derive(Debug, Clone, Copy)]
pub struct WindowPlacement {
    pub hwnd: isize,
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

/// Captures each selected window and composites them by z-order onto their union bounds.
pub fn capture_windows_composite(targets: &[WindowPlacement]) -> Result<ScreenshotPng, ScreenshotError> {
    if targets.is_empty() {
        return Err(ScreenshotError::NoDisplay);
    }
    let min_left = targets.iter().map(|item| item.left).min().unwrap_or(0);
    let min_top = targets.iter().map(|item| item.top).min().unwrap_or(0);
    let max_right = targets.iter().map(|item| item.right).max().unwrap_or(0);
    let max_bottom = targets.iter().map(|item| item.bottom).max().unwrap_or(0);
    let width = (max_right - min_left).max(1) as u32;
    let height = (max_bottom - min_top).max(1) as u32;
    let mut dest = capture::CapturedFrame {
        width,
        height,
        bgra: vec![0_u8; (width * height * 4) as usize],
    };
    for target in targets {
        let frame = capture::capture_window_frame(target.hwnd, Duration::from_secs(3))?;
        blit_frame(
            &mut dest,
            &frame,
            target.left - min_left,
            target.top - min_top,
        );
    }
    encode_png(dest, min_left, min_top)
}

pub fn blit_frame(dest: &mut capture::CapturedFrame, src: &capture::CapturedFrame, dest_x: i32, dest_y: i32) {
    for row in 0..src.height as i32 {
        let dy = dest_y + row;
        if dy < 0 || dy >= dest.height as i32 {
            continue;
        }
        for col in 0..src.width as i32 {
            let dx = dest_x + col;
            if dx < 0 || dx >= dest.width as i32 {
                continue;
            }
            let si = ((row as u32 * src.width + col as u32) * 4) as usize;
            let di = ((dy as u32 * dest.width + dx as u32) * 4) as usize;
            dest.bgra[di..di + 4].copy_from_slice(&src.bgra[si..si + 4]);
        }
    }
}

/// Captures an entire display in physical pixels.
pub fn capture_display(display: &DisplayInfo) -> Result<ScreenshotPng, ScreenshotError> {
    let frame = capture::capture_monitor_frame(display.handle, Duration::from_secs(3))?;
    encode_png(frame, display.left, display.top)
}

pub fn encode_frame_png(frame: &CapturedFrame) -> Result<Vec<u8>, ScreenshotError> {
    let mut rgba = Vec::with_capacity(frame.bgra.len());
    for pixel in frame.bgra.as_chunks::<4>().0 {
        rgba.extend_from_slice(&[pixel[2], pixel[1], pixel[0], pixel[3]]);
    }
    let mut png = Cursor::new(Vec::new());
    let mut encoder = png::Encoder::new(&mut png, frame.width, frame.height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder
        .write_header()
        .map_err(|err| ScreenshotError::Png(err.to_string()))?;
    writer
        .write_image_data(&rgba)
        .map_err(|err| ScreenshotError::Png(err.to_string()))?;
    drop(writer);
    Ok(png.into_inner())
}

fn encode_png(
    frame: CapturedFrame,
    display_left: i32,
    display_top: i32,
) -> Result<ScreenshotPng, ScreenshotError> {
    let png = encode_frame_png(&frame)?;
    Ok(ScreenshotPng {
        width: frame.width,
        height: frame.height,
        png,
        bgra: frame.bgra,
        display_left,
        display_top,
    })
}

pub fn display_covering<'a>(
    displays: &'a [DisplayInfo],
    region: PhysicalRegion,
) -> Option<&'a DisplayInfo> {
    let cx = region.x + region.width / 2;
    let cy = region.y + region.height / 2;
    displays
        .iter()
        .find(|display| {
            cx >= display.left && cx < display.right && cy >= display.top && cy < display.bottom
        })
        .or_else(|| displays.iter().find(|display| display.is_primary))
        .or_else(|| displays.first())
}

#[cfg(test)]
mod tests {
    use super::encode_frame_png;
    use crate::capture::CapturedFrame;

    #[test]
    fn blit_places_source_at_offset() {
        let mut dest = CapturedFrame {
            width: 4,
            height: 2,
            bgra: vec![0; 32],
        };
        let src = CapturedFrame {
            width: 1,
            height: 1,
            bgra: vec![1, 2, 3, 255],
        };
        super::blit_frame(&mut dest, &src, 2, 1);
        assert_eq!(&dest.bgra[24..28], &[1, 2, 3, 255]);
    }

    #[test]
    fn png_header_is_valid_for_tiny_frame() {
        let frame = CapturedFrame {
            width: 2,
            height: 2,
            bgra: vec![
                0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255,
            ],
        };
        let png = encode_frame_png(&frame).expect("png");
        assert_eq!(&png[0..8], &[137, 80, 78, 71, 13, 10, 26, 10]);
        assert!(png.len() > 32);
    }
}
