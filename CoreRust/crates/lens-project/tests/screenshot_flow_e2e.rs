use std::fs;
use std::path::{Path, PathBuf};

use lens_core::edit::LensPoint;
use lens_core::manifest::LensRect;
use lens_core::screenshot_edit::{
    LensColor, ScreenshotAnnotation, ScreenshotAnnotationKind, ScreenshotAnnotationStyle,
    ScreenshotCanvasAspectRatio, ScreenshotCanvasBackgroundKind, ScreenshotCanvasStyle,
    ScreenshotEditPlan, CURRENT_SCHEMA_VERSION,
};
use lens_platform_windows::capture::CapturedFrame;
use lens_platform_windows::overlay::{nudge_region, snap_region, PhysicalRegion};
use lens_platform_windows::scrolling::{self, stitch_vertical};
use lens_project::{
    export_screenshot, save_annotated_png, save_json, save_screenshot_package, scan_library,
    ProjectError,
};

fn temp_workspace(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("lens-test-screenshot-{}", name));
    if dir.exists() {
        let _ = fs::remove_dir_all(&dir);
    }
    fs::create_dir_all(&dir).unwrap();
    dir
}

// 1x1 valid PNG bytes
const MINIMAL_PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG signature
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, // IDAT chunk
    0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, // IEND chunk
    0x42, 0x60, 0x82,
];

// 1x1 valid JPEG bytes
const MINIMAL_JPEG: &[u8] = &[
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, // SOI and APP0
    0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
    0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0a, 0x0c,
    0x14, 0x0d, 0x0c, 0x0b, 0x0b, 0x0c, 0x19, 0x12, 0x13, 0x0f, 0x14, 0x1d, 0x1a, 0x1f, 0x1e, 0x1d,
    0x1a, 0x1c, 0x1c, 0x20, 0x24, 0x2e, 0x27, 0x20, 0x22, 0x2c, 0x23, 0x1c, 0x1c, 0x28, 0x37, 0x29,
    0x2c, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1f, 0x27, 0x39, 0x3d, 0x38, 0x32, 0x3c, 0x2e, 0x33, 0x34,
    0x32, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xff, 0xc4,
    0x00, 0x1f, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0xff,
    0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xbe, 0x00, 0xff,
    0xd9, // SOS and EOI
];

#[test]
fn test_screenshot_package_creation_and_reopen() {
    let ws = temp_workspace("pkg-creation");
    let item = save_screenshot_package(
        &ws,
        MINIMAL_PNG,
        1920,
        1080,
        LensRect {
            x: 100.0,
            y: 200.0,
            width: 1920.0,
            height: 1080.0,
        },
        "region",
    )
    .expect("save_screenshot_package succeeds");

    let pkg_path = Path::new(&item.package_path);
    assert!(pkg_path.is_dir());
    assert!(pkg_path.join("manifest.json").is_file());
    assert!(pkg_path.join("raw/screenshot.png").is_file());

    // Verify reopen / index scan discovers the package
    let scanned = scan_library(&ws).expect("scan_library succeeds");
    assert_eq!(scanned.len(), 1);
    assert_eq!(scanned[0].id, item.id);
    assert_eq!(scanned[0].width, Some(1920));
    assert_eq!(scanned[0].height, Some(1080));
    assert_eq!(scanned[0].kind, "screenshot");

    let _ = fs::remove_dir_all(&ws);
}

#[test]
fn test_screenshot_plan_save_load_roundtrip_and_annotations() {
    let ws = temp_workspace("plan-roundtrip");
    let item = save_screenshot_package(
        &ws,
        MINIMAL_PNG,
        800,
        600,
        LensRect {
            x: 0.0,
            y: 0.0,
            width: 800.0,
            height: 600.0,
        },
        "window",
    )
    .unwrap();
    let pkg = Path::new(&item.package_path);

    let plan = ScreenshotEditPlan {
        schema_version: CURRENT_SCHEMA_VERSION.into(),
        annotations: vec![
            ScreenshotAnnotation {
                id: "ann-rect-1".into(),
                kind: ScreenshotAnnotationKind::Rectangle,
                bounds: LensRect {
                    x: 50.0,
                    y: 50.0,
                    width: 200.0,
                    height: 100.0,
                },
                start: None,
                end: None,
                points: None,
                text: None,
                style: ScreenshotAnnotationStyle::default(),
            },
            ScreenshotAnnotation {
                id: "ann-arrow-2".into(),
                kind: ScreenshotAnnotationKind::Arrow,
                bounds: LensRect {
                    x: 10.0,
                    y: 10.0,
                    width: 100.0,
                    height: 100.0,
                },
                start: Some(LensPoint { x: 10.0, y: 10.0 }),
                end: Some(LensPoint { x: 110.0, y: 110.0 }),
                points: None,
                text: None,
                style: ScreenshotAnnotationStyle {
                    line_width: 0.012,
                    font_size: 0.045,
                    color: LensColor {
                        red: 0.1,
                        green: 0.58,
                        blue: 1.0,
                        alpha: 1.0,
                    },
                    gradient_end_color: None,
                    fill_color: None,
                    intensity: 0.05,
                },
            },
            ScreenshotAnnotation {
                id: "ann-text-3".into(),
                kind: ScreenshotAnnotationKind::Text,
                bounds: LensRect {
                    x: 300.0,
                    y: 100.0,
                    width: 150.0,
                    height: 40.0,
                },
                start: None,
                end: None,
                points: None,
                text: Some("Windows 1:1 对齐测试".into()),
                style: ScreenshotAnnotationStyle::default(),
            },
        ],
        canvas: Some(ScreenshotCanvasStyle {
            background_kind: ScreenshotCanvasBackgroundKind::Gradient,
            primary_color: LensColor {
                red: 0.2,
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
            shadow_opacity: 0.3,
            aspect_ratio: ScreenshotCanvasAspectRatio::Widescreen16x9,
        }),
    };

    // Save plan
    save_json(pkg, "edits/screenshot-edit.json", &plan).expect("save_json succeeds");
    assert!(pkg.join("edits/screenshot-edit.json").is_file());

    // Load and roundtrip assert
    let raw_text = fs::read_to_string(pkg.join("edits/screenshot-edit.json")).unwrap();
    let loaded: ScreenshotEditPlan = serde_json::from_str(&raw_text).unwrap();
    assert_eq!(loaded.schema_version, CURRENT_SCHEMA_VERSION);
    assert_eq!(loaded.annotations.len(), 3);
    assert_eq!(
        loaded.annotations[0].kind,
        ScreenshotAnnotationKind::Rectangle
    );
    assert_eq!(loaded.annotations[1].kind, ScreenshotAnnotationKind::Arrow);
    assert_eq!(
        loaded.annotations[2].text.as_deref(),
        Some("Windows 1:1 对齐测试")
    );
    assert_eq!(
        loaded.canvas.as_ref().map(|c| c.aspect_ratio),
        Some(ScreenshotCanvasAspectRatio::Widescreen16x9)
    );

    // Also test save_annotated_png
    let annotated_path = save_annotated_png(pkg, MINIMAL_PNG).expect("save_annotated_png succeeds");
    assert!(annotated_path.is_file());
    assert_eq!(annotated_path, pkg.join("previews/annotated.png"));

    let _ = fs::remove_dir_all(&ws);
}

#[test]
fn test_screenshot_export_png_jpeg_strict_encoding_and_extension() {
    let ws = temp_workspace("export-formats");
    let item = save_screenshot_package(
        &ws,
        MINIMAL_PNG,
        640,
        480,
        LensRect {
            x: 0.0,
            y: 0.0,
            width: 640.0,
            height: 480.0,
        },
        "region",
    )
    .unwrap();
    let pkg = Path::new(&item.package_path);

    // 1. Export valid PNG without target path -> goes to package/exports with .png
    let out_png = export_screenshot(pkg, MINIMAL_PNG, "png", None).expect("png export succeeds");
    assert!(out_png.is_file());
    assert_eq!(out_png.extension().and_then(|s| s.to_str()), Some("png"));
    let bytes_png = fs::read(&out_png).unwrap();
    assert!(bytes_png.starts_with(b"\x89PNG\r\n\x1a\n"));

    // 2. Export valid JPEG with explicit target path with wrong extension -> automatically corrected to .jpg
    let target_jpeg = ws.join("my_export.bmp");
    let out_jpeg = export_screenshot(pkg, MINIMAL_JPEG, "jpeg", Some(&target_jpeg))
        .expect("jpeg export succeeds");
    assert!(out_jpeg.is_file());
    assert_eq!(out_jpeg.extension().and_then(|s| s.to_str()), Some("jpg"));
    let bytes_jpeg = fs::read(&out_jpeg).unwrap();
    assert!(bytes_jpeg.starts_with(&[0xff, 0xd8, 0xff]));

    // 3. Reject invalid data when format says jpeg but data is PNG
    let err = export_screenshot(pkg, MINIMAL_PNG, "jpeg", None);
    match err {
        Err(ProjectError::BadImageFormat(msg)) => {
            assert!(msg.contains("JPEG"));
        }
        other => panic!("expected BadImageFormat for invalid jpeg, got: {other:?}"),
    }

    // 4. Reject invalid data when format says png but data is JPEG
    let err_png = export_screenshot(pkg, MINIMAL_JPEG, "png", None);
    match err_png {
        Err(ProjectError::BadImageFormat(msg)) => {
            assert!(msg.contains("PNG"));
        }
        other => panic!("expected BadImageFormat for invalid png, got: {other:?}"),
    }

    // 5. Reject unsupported format (e.g. webp or gif)
    let err_unsupported = export_screenshot(pkg, MINIMAL_PNG, "gif", None);
    match err_unsupported {
        Err(ProjectError::BadImageFormat(msg)) => {
            assert!(msg.contains("不支持"));
        }
        other => panic!("expected BadImageFormat for unsupported format, got: {other:?}"),
    }

    let _ = fs::remove_dir_all(&ws);
}

#[test]
fn test_scrolling_capture_stitch_and_safety_bounds() {
    let width = 100u32;
    let height = 100u32;

    // Frame 1: solid red
    let frame1 = CapturedFrame {
        width,
        height,
        bgra: vec![0, 0, 255, 255].repeat((width * height) as usize),
    };

    // Identical frame: should NOT append (duplicate scroll check)
    assert!(
        !scrolling::should_append_frame(&frame1, &frame1),
        "identical frame must be rejected as duplicate"
    );

    // Frame with unstable content (completely different random/blue colors): should NOT append
    let frame_unstable = CapturedFrame {
        width,
        height,
        bgra: vec![255, 0, 0, 255].repeat((width * height) as usize),
    };
    assert!(
        !scrolling::should_append_frame(&frame1, &frame_unstable),
        "unstable scene swap must be rejected"
    );

    // Construct valid downward scroll: frame2 overlaps bottom half of frame1
    let mut f1_data = Vec::with_capacity((width * height * 4) as usize);
    for row in 0..height {
        let val = (row % 256) as u8;
        for _ in 0..width {
            f1_data.extend_from_slice(&[val, val, val, 255]);
        }
    }
    let f1 = CapturedFrame {
        width,
        height,
        bgra: f1_data,
    };

    let mut f2_data = Vec::with_capacity((width * height * 4) as usize);
    // Overlap by 50 rows, then 50 new rows
    for row in 50..150 {
        let val = (row % 256) as u8;
        for _ in 0..width {
            f2_data.extend_from_slice(&[val, val, val, 255]);
        }
    }
    let f2 = CapturedFrame {
        width,
        height,
        bgra: f2_data,
    };

    assert!(
        scrolling::should_append_frame(&f1, &f2),
        "valid downward scrolled strip must be accepted"
    );

    // Test stitching
    let stitched = stitch_vertical(&[f1, f2]).expect("stitch succeeds");
    assert_eq!(stitched.frame.width, width);
    assert!(
        stitched.frame.height > height,
        "stitched canvas height must expand beyond single frame height"
    );
    assert_eq!(stitched.steps.len(), 2);
}

#[test]
fn test_overlay_snap_and_nudge_coordinate_math() {
    let region = PhysicalRegion {
        x: 102,
        y: 204,
        width: 400,
        height: 300,
    };

    // Snap to left edge 100 within threshold 10
    let snap_edges = [(100, 200, 1000, 800)];
    let (snapped, _guide) = snap_region(region, &snap_edges, 10, false);
    assert_eq!(snapped.x, 100);
    assert_eq!(snapped.width, 402); // Left stretched to 100, right remains 502

    // Bypass snap when Alt held
    let (bypassed, _guide) = snap_region(region, &snap_edges, 10, true);
    assert_eq!(bypassed.x, 102);

    // Nudge moves position without resizing dimensions
    let nudged = nudge_region(region, 5, -10);
    assert_eq!(nudged.x, 107);
    assert_eq!(nudged.y, 194);
    assert_eq!(nudged.width, 400);
    assert_eq!(nudged.height, 300);
}
