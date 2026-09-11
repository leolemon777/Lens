//! Vertical long-screenshot stitching from successive region frames.

use crate::capture::CapturedFrame;

#[derive(Debug, Clone)]
pub struct StitchStep {
    pub index: usize,
    pub vertical_offset: u32,
    pub appended_height: u32,
    pub overlap_difference: f64,
}

#[derive(Debug, Clone)]
pub struct StitchResult {
    pub frame: CapturedFrame,
    pub steps: Vec<StitchStep>,
}

/// Stitches frames top-to-bottom by finding the lowest-error overlap.
pub fn stitch_vertical(frames: &[CapturedFrame]) -> Option<StitchResult> {
    let first = frames.first()?;
    if frames.len() == 1 {
        return Some(StitchResult {
            frame: first.clone(),
            steps: vec![StitchStep {
                index: 0,
                vertical_offset: 0,
                appended_height: first.height,
                overlap_difference: 0.0,
            }],
        });
    }
    let width = first.width;
    let mut canvas = first.bgra.clone();
    let mut height = first.height;
    let mut steps = vec![StitchStep {
        index: 0,
        vertical_offset: 0,
        appended_height: first.height,
        overlap_difference: 0.0,
    }];
    for (index, frame) in frames.iter().enumerate().skip(1) {
        if frame.width != width {
            continue;
        }
        let (overlap, error) = best_overlap(&canvas, height, &frame.bgra, frame.height, width);
        let append = frame.height.saturating_sub(overlap);
        if append == 0 {
            steps.push(StitchStep {
                index,
                vertical_offset: height.saturating_sub(overlap),
                appended_height: 0,
                overlap_difference: error,
            });
            continue;
        }
        let start = (overlap * width * 4) as usize;
        canvas.extend_from_slice(&frame.bgra[start..]);
        steps.push(StitchStep {
            index,
            vertical_offset: height.saturating_sub(overlap),
            appended_height: append,
            overlap_difference: error,
        });
        height += append;
    }
    Some(StitchResult {
        frame: CapturedFrame {
            width,
            height,
            bgra: canvas,
        },
        steps,
    })
}

fn best_overlap(canvas: &[u8], canvas_h: u32, next: &[u8], next_h: u32, width: u32) -> (u32, f64) {
    let max_overlap = canvas_h.min(next_h).saturating_sub(8).max(1);
    let min_overlap = (next_h / 8).max(4).min(max_overlap);
    let mut best = max_overlap;
    let mut best_err = f64::MAX;
    for overlap in (min_overlap..=max_overlap).rev() {
        let err = overlap_error(canvas, canvas_h, next, width, overlap);
        if err + 0.002 < best_err {
            best_err = err;
            best = overlap;
        }
    }
    (best, best_err)
}

fn overlap_error(canvas: &[u8], canvas_h: u32, next: &[u8], width: u32, overlap: u32) -> f64 {
    let mut acc = 0_u64;
    let mut count = 0_u64;
    let stride = width * 4;
    let canvas_start = canvas_h.saturating_sub(overlap);
    for row in 0..overlap {
        let a = ((canvas_start + row) * stride) as usize;
        let b = (row * stride) as usize;
        let end = stride as usize;
        if a + end > canvas.len() || b + end > next.len() {
            break;
        }
        for i in (0..end).step_by(4) {
            let dr = canvas[a + i + 2].abs_diff(next[b + i + 2]) as u64;
            let dg = canvas[a + i + 1].abs_diff(next[b + i + 1]) as u64;
            let db = canvas[a + i].abs_diff(next[b + i]) as u64;
            acc += dr + dg + db;
            count += 3;
        }
    }
    if count == 0 {
        1.0
    } else {
        acc as f64 / (count as f64 * 255.0)
    }
}

/// Pixel stride (x and y) when sampling BGRA frames for the stability gate.
const FRAME_SAMPLE_STRIDE: u32 = 8;

/// Aligned mean abs BGR channel difference (0–255) at or below this is a
/// duplicate scroll: the viewport did not reveal new content.
///
/// 4.0 ≈ Mac `FrameSignature.stableDifferenceThreshold` (0.018 × 255).
const DUPLICATE_MAX_MEAN_ABS_DIFF: f64 = 4.0;

/// Overlap-band mean abs BGR channel difference (0–255) above this means
/// the scene is still animating, or the frames do not share a downward-scroll
/// seam.
///
/// 32.0 is ~12.5% of the 8-bit channel range — well below a solid-color swap
/// (~200) and in the same order as Mac's 0.145 stitch-accept ceiling.
const UNSTABLE_MAX_MEAN_ABS_DIFF: f64 = 32.0;

/// Overlap band is this fraction of the shorter frame (`min_h / 4`).
const STABILITY_BAND_DENOMINATOR: u32 = 4;

/// Returns whether successive captures are still in the overlap region.
///
/// Samples every [`FRAME_SAMPLE_STRIDE`]th pixel of the overlapping bottom
/// band of `previous` and the top band of `next` (one quarter of the shorter
/// frame). Equal-size frames that are too short to form a smaller band are
/// sampled in full. Alpha is ignored; the mean is raw 8-bit BGR units (0–255).
///
/// `true` when that mean absolute channel difference is ≤ `max_mean_abs_diff`.
pub fn frame_is_stable(
    previous: &CapturedFrame,
    next: &CapturedFrame,
    max_mean_abs_diff: f64,
) -> bool {
    sampled_mean_abs_channel_diff(previous, next, DiffRegion::OverlapBand) <= max_mean_abs_diff
}

/// Whether `next` should be appended onto a long-screenshot stitch.
///
/// Returns `false` when:
/// - the frames are nearly identical (aligned / full-frame mean abs BGR
///   diff ≤ 4.0): a duplicate scroll with no new content; or
/// - the overlapping seam is unstable (overlap-band mean abs BGR diff > 32.0):
///   the scene is still animating, or the frames do not share a seam.
///
/// A shifted unique strip lands between those bounds: the aligned frames
/// differ, but the bottom/top overlap band matches, so it is appended.
pub fn should_append_frame(previous: &CapturedFrame, next: &CapturedFrame) -> bool {
    let aligned = sampled_mean_abs_channel_diff(previous, next, DiffRegion::Aligned);
    if aligned <= DUPLICATE_MAX_MEAN_ABS_DIFF {
        return false;
    }
    frame_is_stable(previous, next, UNSTABLE_MAX_MEAN_ABS_DIFF)
}

#[derive(Clone, Copy)]
enum DiffRegion {
    /// Top-left aligned, `min(width) × min(height)`. Full frame when sizes match.
    Aligned,
    /// Bottom band of `previous` vs top band of `next`.
    OverlapBand,
}

fn overlap_band_height(min_height: u32) -> u32 {
    if min_height == 0 {
        return 0;
    }
    (min_height / STABILITY_BAND_DENOMINATOR)
        .max(1)
        .min(min_height)
}

fn sampled_mean_abs_channel_diff(
    previous: &CapturedFrame,
    next: &CapturedFrame,
    region: DiffRegion,
) -> f64 {
    let width = previous.width.min(next.width);
    let min_height = previous.height.min(next.height);
    if width == 0 || min_height == 0 {
        return f64::INFINITY;
    }
    let (prev_origin_y, next_origin_y, height) = match region {
        DiffRegion::Aligned => (0, 0, min_height),
        DiffRegion::OverlapBand => {
            let band = overlap_band_height(min_height);
            (previous.height.saturating_sub(band), 0, band)
        }
    };
    let mut acc = 0_u64;
    let mut count = 0_u64;
    for y in (0..height).step_by(FRAME_SAMPLE_STRIDE as usize) {
        for x in (0..width).step_by(FRAME_SAMPLE_STRIDE as usize) {
            let Some(a) = pixel_bgr(previous, x, prev_origin_y + y) else {
                continue;
            };
            let Some(b) = pixel_bgr(next, x, next_origin_y + y) else {
                continue;
            };
            acc += a.0.abs_diff(b.0) as u64 + a.1.abs_diff(b.1) as u64 + a.2.abs_diff(b.2) as u64;
            count += 3;
        }
    }
    if count == 0 {
        f64::INFINITY
    } else {
        acc as f64 / count as f64
    }
}

fn pixel_bgr(frame: &CapturedFrame, x: u32, y: u32) -> Option<(u8, u8, u8)> {
    if x >= frame.width || y >= frame.height {
        return None;
    }
    let i = ((y * frame.width + x) * 4) as usize;
    let px = frame.bgra.get(i..i + 4)?;
    Some((px[0], px[1], px[2]))
}

#[cfg(test)]
mod tests {
    use super::{
        frame_is_stable, should_append_frame, stitch_vertical, UNSTABLE_MAX_MEAN_ABS_DIFF,
    };
    use crate::capture::CapturedFrame;

    fn band(width: u32, height: u32, value: u8) -> CapturedFrame {
        CapturedFrame {
            width,
            height,
            bgra: vec![value; (width * height * 4) as usize],
        }
    }

    #[test]
    fn stitches_identical_bands_without_growing_unbounded() {
        let frames = vec![band(8, 16, 40), band(8, 16, 40), band(8, 16, 40)];
        let stitched = stitch_vertical(&frames).unwrap();
        assert_eq!(stitched.frame.width, 8);
        assert!(stitched.frame.height <= 32);
        assert_eq!(stitched.steps.len(), 3);
    }

    #[test]
    fn appends_when_second_frame_is_new_content() {
        let mut first = band(4, 8, 10);
        let mut second = band(4, 8, 200);
        // Copy the last 2 rows of first onto the first 2 rows of second.
        let stride = 16;
        let src = first.bgra.len() - stride * 2;
        second.bgra[..stride * 2].copy_from_slice(&first.bgra[src..]);
        first.bgra.truncate(first.bgra.len());
        let stitched = stitch_vertical(&[first, second]).unwrap();
        assert!(stitched.frame.height >= 8);
        assert!(stitched.frame.height <= 16);
    }

    fn row_colored(width: u32, height: u32, row_value: impl Fn(u32) -> u8) -> CapturedFrame {
        let mut bgra = Vec::with_capacity((width * height * 4) as usize);
        for y in 0..height {
            let value = row_value(y);
            for _ in 0..width {
                bgra.extend_from_slice(&[value, value, value, 255]);
            }
        }
        CapturedFrame {
            width,
            height,
            bgra,
        }
    }

    fn shifted_unique_strip() -> (CapturedFrame, CapturedFrame) {
        let width = 24;
        let height = 24;
        let band = (height / 4).max(1);
        let previous = row_colored(width, height, |y| {
            if y >= height - band {
                90
            } else {
                20 + y as u8
            }
        });
        let next = row_colored(width, height, |y| {
            if y < band {
                90
            } else {
                180 + (y as u8 % 40)
            }
        });
        (previous, next)
    }

    #[test]
    fn identical_frames_should_not_append() {
        let previous = band(24, 24, 40);
        let next = band(24, 24, 40);
        assert!(frame_is_stable(
            &previous,
            &next,
            UNSTABLE_MAX_MEAN_ABS_DIFF
        ));
        assert!(!should_append_frame(&previous, &next));
    }

    #[test]
    fn shifted_unique_strip_should_append() {
        let (previous, next) = shifted_unique_strip();
        assert!(frame_is_stable(
            &previous,
            &next,
            UNSTABLE_MAX_MEAN_ABS_DIFF
        ));
        assert!(should_append_frame(&previous, &next));
    }

    #[test]
    fn wildly_different_frame_is_unstable_and_not_appended() {
        let previous = band(24, 24, 10);
        let next = band(24, 24, 220);
        assert!(!frame_is_stable(
            &previous,
            &next,
            UNSTABLE_MAX_MEAN_ABS_DIFF
        ));
        assert!(!should_append_frame(&previous, &next));
    }
}
