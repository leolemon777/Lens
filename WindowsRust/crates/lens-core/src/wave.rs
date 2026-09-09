//! Seekable PCM16 stereo WAV. Timestamps keep loopback silence as silence rather
//! than collapsing it. Header is checkpointed; existing source files stay intact.
use std::{fs::{File, OpenOptions}, io::{Seek, SeekFrom, Write}, path::Path};
pub const RATE: u32 = 48_000;
pub const BLOCK: usize = 4; // 16-bit stereo
pub struct WaveWriter { file: File, frames: u64 }
impl WaveWriter {
    pub fn create(path: &Path) -> Result<Self, String> {
        let file=OpenOptions::new().read(true).write(true).create_new(true).open(path).map_err(|e|e.to_string())?;
        let mut result=Self{file,frames:0};result.checkpoint()?;Ok(result)
    }
    pub fn write_at(&mut self, at: i64, pcm: &[u8]) -> Result<(), String> {
        if pcm.len()%BLOCK != 0 {return Err("PCM 帧未对齐".into());}
        let skip=if at<0 {(at.unsigned_abs().min((pcm.len()/BLOCK) as u64) as usize)*BLOCK} else {0};
        let data=&pcm[skip..];if data.is_empty(){return Ok(());}
        let start=at.max(0) as u64;
        let end=start.checked_add((data.len()/BLOCK) as u64).ok_or("音轨长度溢出")?;
        if end>(u32::MAX as u64-36)/BLOCK as u64 {return Err("单段 WAV 达到 4 GiB 上限，请停止并保存".into());}
        self.file.seek(SeekFrom::Start(44+start*BLOCK as u64)).map_err(|e|e.to_string())?;
        self.file.write_all(data).map_err(|e|e.to_string())?;
        self.frames=self.frames.max(end);Ok(())
    }
    pub fn checkpoint(&mut self) -> Result<(), String> {
        let bytes=(self.frames*BLOCK as u64) as u32;
        let mut h=Vec::with_capacity(44);
        h.extend(b"RIFF");h.extend((36+bytes).to_le_bytes());h.extend(b"WAVEfmt ");
        h.extend(16u32.to_le_bytes());h.extend(1u16.to_le_bytes());h.extend(2u16.to_le_bytes());
        h.extend(RATE.to_le_bytes());h.extend((RATE*BLOCK as u32).to_le_bytes());
        h.extend((BLOCK as u16).to_le_bytes());h.extend(16u16.to_le_bytes());h.extend(b"data");h.extend(bytes.to_le_bytes());
        self.file.seek(SeekFrom::Start(0)).map_err(|e|e.to_string())?;
        self.file.write_all(&h).map_err(|e|e.to_string())?;
        self.file.sync_data().map_err(|e|e.to_string())
    }
    pub fn finish(mut self, duration: f64) -> Result<(), String> {
        if !duration.is_finite() || duration<0.0{return Err("音轨时长无效".into());}
        let frames=(duration*RATE as f64).round() as u64;
        if frames>(u32::MAX as u64-36)/BLOCK as u64 {return Err("音轨超过 WAV 上限".into());}
        self.frames=frames;
        self.file.set_len(44+frames*BLOCK as u64).map_err(|e|e.to_string())?;
        self.checkpoint()
    }
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn preserves_silent_gap(){let d=tempfile::tempdir().unwrap();let p=d.path().join("a.wav");let mut w=WaveWriter::create(&p).unwrap();w.write_at(480,&[1,0,2,0]).unwrap();w.finish(0.02).unwrap();let b=std::fs::read(p).unwrap();assert_eq!(&b[44..48],&[0,0,0,0]);assert_eq!(&b[44+480*4..48+480*4],&[1,0,2,0]);assert_eq!(b.len(),44+960*4);}
    #[test]fn rejects_huge_timestamp_without_overflow(){let d=tempfile::tempdir().unwrap();let mut w=WaveWriter::create(&d.path().join("a.wav")).unwrap();assert!(w.write_at(i64::MAX,&[0;4]).is_err());}
    #[test]fn trims_minimum_negative_timestamp(){let d=tempfile::tempdir().unwrap();let mut w=WaveWriter::create(&d.path().join("a.wav")).unwrap();assert!(w.write_at(i64::MIN,&[0;4]).is_ok());}
    #[test]fn refuses_overwrite(){let d=tempfile::tempdir().unwrap();let p=d.path().join("a.wav");let _=WaveWriter::create(&p).unwrap();assert!(WaveWriter::create(&p).is_err());}
}
