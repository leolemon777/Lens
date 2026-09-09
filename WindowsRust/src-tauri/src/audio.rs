//! WASAPI default render-loopback and microphone. A separate thread owns each COM client.
use std::{path::PathBuf,sync::{Arc,atomic::{AtomicBool,AtomicU64,Ordering},mpsc},thread::{self,JoinHandle},time::{Duration,Instant}};
use lens_core::{timing::audio_frame_at,wave::{WaveWriter,RATE,BLOCK}};
use wasapi::{DeviceEnumerator,Direction,WaveFormat,SampleType,StreamMode,initialize_mta};
use crate::native::Probe;

pub struct AudioTrack{halt:Arc<AtomicBool>,duration_us:Arc<AtomicU64>,thread:Option<JoinHandle<Result<(),String>>>}
impl AudioTrack{
    pub fn start(path:PathBuf,system:bool,probe:Arc<Probe>)->Result<Self,String>{
        let halt=Arc::new(AtomicBool::new(false));let end=Arc::new(AtomicU64::new(0));
        let stop=halt.clone();let length=end.clone();let(rx_tx,rx)=mpsc::sync_channel(1);
        let handle=thread::Builder::new().name(if system{"lens-system-audio"}else{"lens-microphone"}.into()).spawn(move||{
            let run=(||->Result<(),String>{
                initialize_mta().ok().map_err(|e|e.to_string())?;
                struct ComGuard;impl Drop for ComGuard{fn drop(&mut self){unsafe{windows::Win32::System::Com::CoUninitialize();}}}
                let _com=ComGuard;
                let enumerator=DeviceEnumerator::new().map_err(|e|e.to_string())?;
                let device=enumerator.get_default_device(&if system{Direction::Render}else{Direction::Capture}).map_err(|e|e.to_string())?;
                let mut client=device.get_iaudioclient().map_err(|e|e.to_string())?;
                let format=WaveFormat::new(16,16,&SampleType::Int,RATE as usize,2,None);
                let mode=StreamMode::EventsShared{autoconvert:true,buffer_duration_hns:200_000};
                // Capture direction on a Render endpoint activates WASAPI loopback.
                client.initialize_client(&format,&Direction::Capture,&mode).map_err(|e|e.to_string())?;
                let event=client.set_get_eventhandle().map_err(|e|e.to_string())?;
                let capture=client.get_audiocaptureclient().map_err(|e|e.to_string())?;
                let mut writer=WaveWriter::create(&path)?;
                let _=rx_tx.send(Ok(()));
                // Device readiness is independent of capture start. The encoder publishes t=0.
                while probe.origin.load(Ordering::Acquire)==0 {
                    if stop.load(Ordering::Acquire){return writer.finish(0.0);}
                    thread::sleep(Duration::from_millis(1));
                }
                client.start_stream().map_err(|e|e.to_string())?;
                let mut checkpoint=Instant::now();
                let body=(||->Result<(),String>{
                    while !stop.load(Ordering::Acquire){
                        // A silent loopback device need not signal. Timeout is not an error.
                        let _=event.wait_for_event(100);
                        loop{
                            let frames=capture.get_next_packet_size().map_err(|e|e.to_string())?.unwrap_or(0);
                            if frames==0{break;}if frames>RATE{return Err("异常音频缓冲超过一秒上限".into());}
                            let mut data=vec![0u8;frames as usize*BLOCK];
                            let(count,info)=capture.read_from_device(&mut data).map_err(|e|e.to_string())?;
                            data.truncate(count as usize*BLOCK);if count==0{break;}
                            if info.timestamp==0 || info.timestamp>i64::MAX as u64 || info.flags.timestamp_error{return Err("音频设备没有提供有效时间戳，已保留原始分段".into());}
                            if info.flags.silent { data.fill(0); }
                            let at=audio_frame_at(info.timestamp as i64,probe.origin.load(Ordering::Acquire),RATE);
                            if at>RATE as i64*3600*8{return Err("音频时间戳异常".into());}
                            writer.write_at(at,&data)?;
                            let peak=data.chunks_exact(2).map(|p|i16::from_le_bytes([p[0],p[1]]).unsigned_abs() as u64).max().unwrap_or(0);
                            if system{probe.system_level.store(peak*100/32768,Ordering::Relaxed);}else{probe.microphone_level.store(peak*100/32768,Ordering::Relaxed);}
                        }
                        if checkpoint.elapsed()>Duration::from_secs(1){writer.checkpoint()?;checkpoint=Instant::now();}
                    }
                    Ok(())
                })();
                let stop_result=client.stop_stream().map_err(|e|e.to_string());
                // Even failures checkpoint a valid header; no source file is deleted.
                if body.is_err(){let _=writer.checkpoint();body?;}
                writer.finish(length.load(Ordering::Acquire)as f64/1_000_000.0)?;
                stop_result
            })();
            if let Err(ref e)=run{let e=format!("{}：{e}",if system{"系统声音"}else{"麦克风"});probe.fail(e.clone());let _=rx_tx.try_send(Err(e));}run
        }).map_err(|e|e.to_string())?;
        let result=Self{halt,duration_us:end,thread:Some(handle)};
        rx.recv_timeout(Duration::from_secs(10)).map_err(|_|"音频设备初始化超时")??;Ok(result)
    }
    pub fn finish(mut self,duration:f64)->Result<(),String>{
        self.duration_us.store((duration.max(0.0)*1_000_000.0)as u64,Ordering::Release);self.halt.store(true,Ordering::Release);
        self.thread.take().ok_or("音频线程不存在")?.join().map_err(|_|"音频线程异常退出")?
    }
}
impl Drop for AudioTrack{fn drop(&mut self){self.halt.store(true,Ordering::Release);if let Some(h)=self.thread.take(){let _=h.join();}}}
