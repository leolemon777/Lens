//! Child-process segmented recorder used by crash-recovery tests.

use std::path::PathBuf;
use std::time::Duration;

fn main() {
    let mut args = std::env::args_os();
    let program = args.next().expect("program name");
    let output_dir: PathBuf = args.next().map(PathBuf::from).unwrap_or_else(|| {
        panic!("usage: {program:?} <output-dir> <total-seconds> <segment-seconds>")
    });
    let total_seconds: f64 = args
        .next()
        .and_then(|value| value.to_string_lossy().parse().ok())
        .unwrap_or_else(|| {
            panic!("usage: {program:?} <output-dir> <total-seconds> <segment-seconds>")
        });
    let segment_seconds: f64 = args
        .next()
        .and_then(|value| value.to_string_lossy().parse().ok())
        .unwrap_or_else(|| {
            panic!("usage: {program:?} <output-dir> <total-seconds> <segment-seconds>")
        });

    let stats = lens_platform_windows::encode::record_primary_monitor_h264_segmented(
        &output_dir,
        Duration::from_secs_f64(total_seconds),
        Duration::from_secs_f64(segment_seconds),
    )
    .expect("segmented recording failed");
    println!("{stats:?}");
}
