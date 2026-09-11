//! Prints the M0 Windows platform inventory for evidence capture.

use lens_platform_windows::{camera, capture, display, dpi, encode, graphics};
use std::time::Duration;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    dpi::enable_per_monitor_v2()?;
    println!("Lens Windows platform inventory");

    let displays = display::enumerate_displays()?;
    println!("\nDisplays (physical desktop coordinates):");
    for item in &displays {
        println!(
            "  {}{}x{} origin=({}, {}) work=({},{})-({},{}) dpi={}x{} handle={}",
            if item.is_primary { "primary " } else { "" },
            item.width(),
            item.height(),
            item.left,
            item.top,
            item.work_left,
            item.work_top,
            item.work_right,
            item.work_bottom,
            item.effective_dpi_x,
            item.effective_dpi_y,
            item.handle
        );
        assert!(
            item.geometry_is_valid(),
            "invalid display geometry: {item:?}"
        );
    }
    assert!(!displays.is_empty(), "no attached displays found");

    let adapters = graphics::enumerate_adapters()?;
    println!("\nDXGI adapters:");
    for adapter in &adapters {
        println!(
            "  {} dedicated_video_memory={} bytes",
            adapter.description, adapter.dedicated_video_memory_bytes
        );
        for output in &adapter.outputs {
            println!(
                "    {} desktop=({},{})-({},{}) attached={} rotation={}",
                output.device_name,
                output.desktop_left,
                output.desktop_top,
                output.desktop_right,
                output.desktop_bottom,
                output.attached_to_desktop,
                output.rotation
            );
        }
    }
    assert!(!adapters.is_empty(), "no DXGI adapters found");

    let device = graphics::create_video_device()?;
    println!(
        "\nD3D11 device: hardware={} video_support={} feature_level=0x{:04X}",
        device.capabilities.hardware,
        device.capabilities.video_support,
        device.capabilities.feature_level
    );

    let wgc_supported = capture::is_wgc_supported()?;
    println!("Windows Graphics Capture supported: {wgc_supported}");
    assert!(wgc_supported, "evidence machine must support WGC");

    let frame = capture::capture_primary_monitor_frame(Duration::from_secs(3))?;
    println!(
        "Captured WGC frame: {}x{} BGRA bytes={}",
        frame.width,
        frame.height,
        frame.bgra.len()
    );
    assert_eq!(frame.width, 3840, "DPI V2 must expose physical width");
    assert_eq!(frame.height, 2160, "DPI V2 must expose physical height");
    assert_eq!(frame.bgra.len(), 3840 * 2160 * 4);
    let distinct_nonzero = frame
        .bgra
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|pixel| pixel.iter().any(|byte| *byte != 0))
        .count();
    println!("Non-black sampled pixels: {distinct_nonzero}");
    assert!(
        distinct_nonzero > frame.bgra.len() / 4 / 100,
        "captured texture must contain real desktop content"
    );

    let output_dir = std::path::Path::new("../Build/Windows/evidence/m0-rust-002-20260909");
    std::fs::create_dir_all(output_dir)?;
    write_png(output_dir.join("wgc-primary-frame.png"), &frame)?;

    let stream = capture::capture_primary_monitor_frame_stream(Duration::from_secs(2))?;
    println!(
        "Event-driven capture: frames_arrived={} frames_drained={} worker_thread={} callback_threads={:?} elapsed={:?}",
        stream.frames_arrived,
        stream.frames_drained,
        stream.worker_thread_id,
        stream.callback_thread_ids,
        stream.elapsed
    );
    assert!(stream.frames_arrived >= 1, "at least one frame must arrive");
    assert_eq!(stream.frames_arrived, stream.frames_drained);
    assert!(
        stream
            .callback_thread_ids
            .iter()
            .all(|id| *id != stream.worker_thread_id),
        "free-threaded callbacks must not run on the worker thread"
    );

    let encoders = encode::enumerate_h264_encoders()?;
    println!("\nH.264 encoders:");
    for encoder in &encoders {
        println!("  {} hardware={}", encoder.name, encoder.hardware);
    }
    assert!(
        encoders.iter().any(|encoder| encoder.hardware),
        "baseline machine must expose a hardware H.264 encoder"
    );

    let cameras = camera::enumerate_video_capture_devices()?;
    println!("\nVideo capture devices:");
    if cameras.is_empty() {
        println!("  (none; camera track must degrade explicitly on this machine)");
    } else {
        for camera in &cameras {
            println!(
                "  {} hardware_source={} symbolic_link={}",
                camera.friendly_name, camera.hardware_source, camera.symbolic_link
            );
        }
    }

    let recording_path = output_dir.join("wgc-h264-recording.mp4");
    let recording = encode::record_primary_monitor_h264(&recording_path, Duration::from_secs(5))?;
    println!(
        "Recorded H.264 MP4: {}x{} frames={} elapsed={:?} path={}",
        recording.width,
        recording.height,
        recording.frames_written,
        recording.elapsed,
        recording.output_path
    );
    assert!(
        recording.frames_written >= 20,
        "recording must capture real animation"
    );

    let decode = encode::verify_h264_decoding(&recording_path)?;
    println!(
        "Decode verification: frames={} bytes={} first_ts={:?} last_ts={:?} nonzero_pixels={}",
        decode.frames_decoded,
        decode.total_bytes,
        decode.first_timestamp_100ns,
        decode.last_timestamp_100ns,
        decode.saw_nonzero_pixels
    );
    assert!(
        decode.frames_decoded >= 20,
        "MP4 must decode to real frames"
    );
    assert!(
        decode.saw_nonzero_pixels,
        "decoded pixels must not all be zero"
    );
    assert!(decode.total_bytes > recording.width as u64 * recording.height as u64 * 4);

    Ok(())
}

fn write_png(path: std::path::PathBuf, frame: &capture::CapturedFrame) -> std::io::Result<()> {
    let file = std::fs::File::create(path)?;
    let writer = std::io::BufWriter::new(file);
    let mut encoder = png::Encoder::new(writer, frame.width, frame.height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header()?;

    let mut rgba = Vec::with_capacity(frame.bgra.len());
    for pixel in frame.bgra.as_chunks::<4>().0 {
        rgba.extend_from_slice(&[pixel[2], pixel[1], pixel[0], pixel[3]]);
    }
    writer.write_image_data(&rgba)?;
    Ok(())
}
