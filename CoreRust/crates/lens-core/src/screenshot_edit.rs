//! Portable screenshot annotation and canvas plan (Mac `ScreenshotEditPlan` schema 0.3).

use serde::{Deserialize, Serialize};

use crate::edit::LensPoint;
use crate::manifest::LensRect;

pub const CURRENT_SCHEMA_VERSION: &str = "0.3";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenshotAnnotationKind {
    Rectangle,
    Ellipse,
    Arrow,
    Freehand,
    Highlight,
    Step,
    Text,
    Blur,
    Pixelate,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LensColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenshotAnnotationStyle {
    pub line_width: f64,
    pub font_size: f64,
    pub color: LensColor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gradient_end_color: Option<LensColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_color: Option<LensColor>,
    pub intensity: f64,
}

impl Default for ScreenshotAnnotationStyle {
    fn default() -> Self {
        Self {
            line_width: 0.006,
            font_size: 0.045,
            color: LensColor {
                red: 1.0,
                green: 0.23,
                blue: 0.19,
                alpha: 1.0,
            },
            gradient_end_color: None,
            fill_color: None,
            intensity: 0.035,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenshotAnnotation {
    pub id: String,
    pub kind: ScreenshotAnnotationKind,
    pub bounds: LensRect,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<LensPoint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<LensPoint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub points: Option<Vec<LensPoint>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    pub style: ScreenshotAnnotationStyle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenshotCanvasBackgroundKind {
    Solid,
    Gradient,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenshotCanvasAspectRatio {
    Automatic,
    Square,
    Landscape4x3,
    Widescreen16x9,
    Portrait9x16,
}

impl ScreenshotCanvasAspectRatio {
    fn value(self) -> Option<f64> {
        match self {
            Self::Automatic => None,
            Self::Square => Some(1.0),
            Self::Landscape4x3 => Some(4.0 / 3.0),
            Self::Widescreen16x9 => Some(16.0 / 9.0),
            Self::Portrait9x16 => Some(9.0 / 16.0),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenshotCanvasStyle {
    pub background_kind: ScreenshotCanvasBackgroundKind,
    pub primary_color: LensColor,
    pub secondary_color: LensColor,
    pub padding: f64,
    pub corner_radius: f64,
    pub shadow_radius: f64,
    pub shadow_opacity: f64,
    pub aspect_ratio: ScreenshotCanvasAspectRatio,
}

impl Default for ScreenshotCanvasStyle {
    fn default() -> Self {
        Self {
            background_kind: ScreenshotCanvasBackgroundKind::Gradient,
            primary_color: LensColor {
                red: 0.20,
                green: 0.35,
                blue: 0.92,
                alpha: 1.0,
            },
            secondary_color: LensColor {
                red: 0.55,
                green: 0.22,
                blue: 0.88,
                alpha: 1.0,
            },
            padding: 0.08,
            corner_radius: 0.025,
            shadow_radius: 0.035,
            shadow_opacity: 0.32,
            aspect_ratio: ScreenshotCanvasAspectRatio::Automatic,
        }
    }
}

impl ScreenshotCanvasStyle {
    fn normalized(&self) -> Self {
        Self {
            background_kind: self.background_kind,
            primary_color: self.primary_color,
            secondary_color: self.secondary_color,
            padding: self.padding.clamp(0.02, 0.30),
            corner_radius: self.corner_radius.clamp(0.0, 0.12),
            shadow_radius: self.shadow_radius.clamp(0.0, 0.12),
            shadow_opacity: self.shadow_opacity.clamp(0.0, 0.80),
            aspect_ratio: self.aspect_ratio,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenshotEditPlan {
    pub schema_version: String,
    #[serde(default)]
    pub annotations: Vec<ScreenshotAnnotation>,
    #[serde(
        default,
        rename = "canvasStyle",
        alias = "canvas",
        skip_serializing_if = "Option::is_none"
    )]
    pub canvas: Option<ScreenshotCanvasStyle>,
}

impl Default for ScreenshotEditPlan {
    fn default() -> Self {
        Self {
            schema_version: CURRENT_SCHEMA_VERSION.to_string(),
            annotations: Vec::new(),
            canvas: None,
        }
    }
}

/// Matches Mac `ScreenshotCanvasPlanner.layout`.
///
/// If `style` is `None`, the output is an identity frame. Padding is a fraction of the
/// source's shortest side. A fixed aspect ratio expands the canvas without cropping source.
pub fn layout_canvas(
    source_w: u32,
    source_h: u32,
    style: Option<&ScreenshotCanvasStyle>,
) -> (u32, u32, LensRect) {
    let source_width = f64::from(source_w.max(1));
    let source_height = f64::from(source_h.max(1));
    let Some(style) = style else {
        return (
            source_width as u32,
            source_height as u32,
            LensRect {
                x: 0.0,
                y: 0.0,
                width: source_width,
                height: source_height,
            },
        );
    };

    let normalized = style.normalized();
    let padding = source_width.min(source_height) * normalized.padding;
    let mut output_width = source_width + padding * 2.0;
    let mut output_height = source_height + padding * 2.0;
    if let Some(ratio) = normalized.aspect_ratio.value() {
        if output_width / output_height < ratio {
            output_width = output_height * ratio;
        } else {
            output_height = output_width / ratio;
        }
    }
    let pixel_width = (output_width.ceil() as u32).max(1);
    let pixel_height = (output_height.ceil() as u32).max(1);
    (
        pixel_width,
        pixel_height,
        LensRect {
            x: (f64::from(pixel_width) - source_width) / 2.0,
            y: (f64::from(pixel_height) - source_height) / 2.0,
            width: source_width,
            height: source_height,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_without_style_is_identity() {
        let (out_w, out_h, frame) = layout_canvas(1920, 1080, None);
        assert_eq!(out_w, 1920);
        assert_eq!(out_h, 1080);
        assert_eq!(
            frame,
            LensRect {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            }
        );
    }

    #[test]
    fn layout_widescreen_expands_without_shrinking_source() {
        let style = ScreenshotCanvasStyle {
            aspect_ratio: ScreenshotCanvasAspectRatio::Widescreen16x9,
            ..ScreenshotCanvasStyle::default()
        };
        let source_w = 1000;
        let source_h = 1000;
        let (out_w, out_h, frame) = layout_canvas(source_w, source_h, Some(&style));
        assert!(out_w >= source_w);
        assert!(out_h >= source_h);
        assert_eq!(frame.width, f64::from(source_w));
        assert_eq!(frame.height, f64::from(source_h));
        let ratio = f64::from(out_w) / f64::from(out_h);
        assert!((ratio - 16.0 / 9.0).abs() < 0.01);
    }

    #[test]
    fn layout_padding_increases_output() {
        let tight = ScreenshotCanvasStyle {
            padding: 0.08,
            aspect_ratio: ScreenshotCanvasAspectRatio::Automatic,
            ..ScreenshotCanvasStyle::default()
        };
        let roomy = ScreenshotCanvasStyle {
            padding: 0.20,
            aspect_ratio: ScreenshotCanvasAspectRatio::Automatic,
            ..ScreenshotCanvasStyle::default()
        };
        let (w1, h1, _) = layout_canvas(1000, 500, Some(&tight));
        let (w2, h2, _) = layout_canvas(1000, 500, Some(&roomy));
        assert!(w2 > w1);
        assert!(h2 > h1);
    }
}
