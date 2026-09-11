//! Energy-based speech segmentation of Lens WAV tracks (48 kHz s16 stereo).

use lens_core::edit::TranscriptSegment;

/// Detects speech islands from a 48 kHz 16-bit stereo WAV written by WASAPI capture.
pub fn vad_segments(wav: &[u8]) -> Vec<TranscriptSegment> {
    if wav.len() < 44 {
        return Vec::new();
    }
    let pcm = &wav[44..];
    let sample_rate = 48_000_u32;
    let channels = 2_usize;
    let bytes_per_frame = 2 * channels;
    if pcm.len() < bytes_per_frame {
        return Vec::new();
    }
    let window = (sample_rate as usize / 50) * bytes_per_frame; // 20 ms
    let mut voiced = Vec::new();
    let mut t = 0.0_f64;
    let dt = 0.02;
    for chunk in pcm.chunks(window) {
        let mut acc = 0_u64;
        let mut n = 0_u64;
        for sample in chunk.chunks_exact(2) {
            let value = i16::from_le_bytes([sample[0], sample[1]]) as i32;
            acc += value.unsigned_abs() as u64;
            n += 1;
        }
        let mean = if n == 0 { 0.0 } else { acc as f64 / n as f64 };
        voiced.push((t, t + dt, mean > 420.0));
        t += dt;
    }
    let mut segments = Vec::new();
    let mut current: Option<(f64, f64)> = None;
    for (start, end, is_voice) in voiced {
        if is_voice {
            current = Some(match current {
                None => (start, end),
                Some((s, _)) => (s, end),
            });
        } else if let Some((s, e)) = current.take() {
            if e - s >= 0.24 {
                segments.push(TranscriptSegment {
                    start_seconds: s,
                    end_seconds: e,
                    text: String::new(),
                    confidence: 0.4,
                });
            }
        }
    }
    if let Some((s, e)) = current {
        if e - s >= 0.24 {
            segments.push(TranscriptSegment {
                start_seconds: s,
                end_seconds: e,
                text: String::new(),
                confidence: 0.4,
            });
        }
    }
    segments
}

/// Tries local recognition; absence/failure must never manufacture transcript text.
pub fn transcribe_best(
    wav: &[u8],
    wav_path: Option<&std::path::Path>,
) -> (String, Vec<TranscriptSegment>) {
    let converted = wav_path.and_then(ensure_pcm_wav);
    let (_bytes, path) = if let Some(path) = converted.as_ref() {
        (
            std::fs::read(path).unwrap_or_else(|_| wav.to_vec()),
            Some(path.as_path()),
        )
    } else {
        (wav.to_vec(), wav_path)
    };
    if let Some(path) = path {
        if let Some((engine, segments)) = transcribe_with_whisper(path) {
            return (engine, segments);
        }
    }
    (
        "unavailable".into(),
        Vec::new(),
    )
}

/// Converts Mac CAF/MOV sidecars to a temporary WAV without rewriting `raw/`.
fn ensure_pcm_wav(path: &std::path::Path) -> Option<std::path::PathBuf> {
    let ext = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if ext == "wav" {
        return Some(path.to_path_buf());
    }
    if ext != "caf" && ext != "mov" && ext != "mp4" && ext != "m4a" {
        return None;
    }
    let out = std::env::temp_dir().join(format!(
        "lens-asr-{}.wav",
        path.file_stem()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| "audio".into())
    ));
    let status = std::process::Command::new("ffmpeg")
        .args(["-y", "-i"])
        .arg(path)
        .args(["-ac", "2", "-ar", "48000", "-c:a", "pcm_s16le"])
        .arg(&out)
        .status()
        .ok()?;
    if status.success() && out.exists() {
        Some(out)
    } else {
        None
    }
}

fn transcribe_with_whisper(path: &std::path::Path) -> Option<(String, Vec<TranscriptSegment>)> {
    for binary in ["whisper-cli", "whisper", "faster-whisper"] {
        if let Some(segments) = transcribe_with_command(binary, path) {
            return Some((binary.to_string(), segments));
        }
    }
    None
}

fn transcribe_with_command(binary: &str, path: &std::path::Path) -> Option<Vec<TranscriptSegment>> {
    let parent = path.parent()?;
    let output = std::process::Command::new(binary)
        .arg(path)
        .args(["--model", "base", "--language", "zh", "--output_format", "json"])
        .arg("--output_dir")
        .arg(parent)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stem = path.file_stem()?.to_string_lossy();
    let json_path = parent.join(format!("{stem}.json"));
    let text = std::fs::read_to_string(json_path).ok()?;
    parse_whisper_json(&text)
}

fn parse_whisper_json(text: &str) -> Option<Vec<TranscriptSegment>> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    let mut segments = Vec::new();
    for item in value.get("segments")?.as_array()? {
        let start = item.get("start")?.as_f64()?;
        let end = item.get("end")?.as_f64()?;
        let text = item.get("text")?.as_str()?.trim().to_string();
        if text.is_empty() {
            continue;
        }
        segments.push(TranscriptSegment {
            start_seconds: start,
            end_seconds: end,
            text,
            confidence: 0.8,
        });
    }
    if segments.is_empty() {
        None
    } else {
        Some(segments)
    }
}

#[cfg(test)]
mod tests {
    use super::vad_segments;

    #[test]
    fn unavailable_recognition_does_not_invent_speech() {
        let (engine, segments) = super::transcribe_best(&wav_with_tone(), None);
        assert_eq!(engine, "unavailable");
        assert!(segments.is_empty());
    }

    fn wav_with_tone() -> Vec<u8> {
        let mut data = Vec::from(*b"RIFF");
        data.extend_from_slice(&0u32.to_le_bytes());
        data.extend_from_slice(b"WAVEfmt ");
        data.extend_from_slice(&16u32.to_le_bytes());
        data.extend_from_slice(&1u16.to_le_bytes());
        data.extend_from_slice(&2u16.to_le_bytes());
        data.extend_from_slice(&48000u32.to_le_bytes());
        data.extend_from_slice(&(48000u32 * 4).to_le_bytes());
        data.extend_from_slice(&4u16.to_le_bytes());
        data.extend_from_slice(&16u16.to_le_bytes());
        data.extend_from_slice(b"data");
        let mut pcm = Vec::new();
        for n in 0..(48000 * 2) {
            let sample = if n > 24000 && n < 72000 {
                ((n as f32 * 0.2).sin() * 20000.0) as i16
            } else {
                0
            };
            pcm.extend_from_slice(&sample.to_le_bytes());
            pcm.extend_from_slice(&sample.to_le_bytes());
        }
        data.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        data.extend_from_slice(&pcm);
        let size = (data.len() - 8) as u32;
        data[4..8].copy_from_slice(&size.to_le_bytes());
        data
    }

    #[test]
    fn detects_loud_middle_of_wav() {
        let segments = vad_segments(&wav_with_tone());
        assert!(!segments.is_empty());
        assert!(segments[0].end_seconds - segments[0].start_seconds >= 0.2);
    }

    #[test]
    fn parse_whisper_json_reads_segments() {
        let json = r#"{"segments":[{"start":0.0,"end":1.2,"text":" 你好 "}]}"#;
        let segments = super::parse_whisper_json(json).unwrap();
        assert_eq!(segments[0].text, "你好");
        assert!((segments[0].end_seconds - 1.2).abs() < 1e-9);
    }
}
