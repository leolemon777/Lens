/// Convert WASAPI QPC timestamps (100 ns) into positions on the video timeline.
/// Use i128 so an invalid input cannot overflow during multiplication.
pub fn audio_frame_at(timestamp_hns: i64, video_origin_hns: i64, rate: u32) -> i64 {
    (((timestamp_hns as i128 - video_origin_hns as i128) * rate as i128) / 10_000_000)
        .clamp(i64::MIN as i128, i64::MAX as i128) as i64
}
pub fn video_timestamp(frame_index: u64, fps: u32) -> i64 {
    ((frame_index as u128 * 10_000_000) / fps.max(1) as u128).min(i64::MAX as u128) as i64
}
/// Copy tightly packed top-down BGRA into the bottom-up BGRA expected by the
/// Windows Capture raw-buffer encoder. One bounded frame allocation per update.
pub fn flip_bgra_rows(bytes: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    let row = (width as usize).checked_mul(4).ok_or("帧尺寸溢出")?;
    let len = row.checked_mul(height as usize).ok_or("帧尺寸溢出")?;
    if row == 0 || height == 0 || bytes.len() != len { return Err("帧缓冲尺寸不符".into()); }
    let mut out=vec![0;len];
    for y in 0..height as usize { out[y*row..(y+1)*row].copy_from_slice(&bytes[(height as usize-1-y)*row..(height as usize-y)*row]); }
    Ok(out)
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn qpc_alignment(){assert_eq!(audio_frame_at(20_000_000,10_000_000,48000),48000);}
    #[test] fn negative_audio_offset(){assert_eq!(audio_frame_at(9_000_000,10_000_000,48000),-4800);}
    #[test] fn video_time_no_float_drift(){assert_eq!(video_timestamp(60*3600,60),36_000_000_000);}
    #[test] fn flips_exactly(){assert_eq!(flip_bgra_rows(&[1,2,3,4,5,6,7,8],1,2).unwrap(),vec![5,6,7,8,1,2,3,4]);}
    #[test] fn rejects_bad_buffer(){assert!(flip_bgra_rows(&[0;3],1,1).is_err());}
}
