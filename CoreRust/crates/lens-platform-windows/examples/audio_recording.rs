//! Records WASAPI dual-track evidence for M0.

use lens_platform_windows::audio;
use std::time::Duration;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output_dir =
        std::path::Path::new("../Build/Windows/evidence/m0-rust-002-20260909/wasapi-dual-audio");
    let _ = std::fs::remove_dir_all(output_dir);

    let stats = audio::capture_dual_audio(output_dir, Duration::from_secs(3), true)?;
    println!(
        "Dual audio: elapsed={:?} tone={}",
        stats.elapsed, stats.tone_played
    );
    let system = stats.system.as_ref().expect("system audio track");
    print_track("system", system);
    if let Some(microphone) = &stats.microphone {
        print_track("microphone", microphone);
    } else {
        println!("microphone: absent (acceptable on this probe)");
    }

    assert!(system.frames >= 48_000);
    assert!(
        system.saw_nonzero_samples,
        "loopback tone was not captured"
    );
    if let Some(microphone) = &stats.microphone {
        assert!(microphone.frames >= 48_000);
    }
    Ok(())
}

fn print_track(label: &str, track: &audio::AudioTrackStats) {
    println!(
        "{label}: frames={} bytes={} rate={} channels={} bits={} qpc=({}..{}) frequency={} first_device={:?} first_packet_qpc={:?} nonzero={} endpoint={}",
        track.frames,
        track.bytes,
        track.sample_rate,
        track.channels,
        track.bits_per_sample,
        track.start_qpc,
        track.end_qpc,
        track.qpc_frequency,
        track.first_device_position,
        track.first_packet_qpc,
        track.saw_nonzero_samples,
        track.endpoint_id
    );
}
