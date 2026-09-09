//! WGC acquisition and Windows-native H.264 encoding.
//! MVP intentionally uses a CPU BGRA hand-off, NOT a claimed zero-copy pipeline.
use std::{error::Error, path::{Path,PathBuf}, sync::{Arc,atomic::{AtomicBool,AtomicI64,AtomicU64,Ordering},mpsc}, thread::{self,JoinHandle}, time::{Duration,Instant}};
use parking_lot::{Mutex,Condvar};
use serde::Serialize;
use lens_core::{Crop,Dimensions,RecordOptions,timing::{flip_bgra_rows,video_timestamp}};
use windows_capture::{capture::{CaptureControl,Context,GraphicsCaptureApiHandler}, frame::{Frame,ImageFormat},graphics_capture_api::InternalCaptureControl,
    monitor::Monitor,window::Window,settings::{Settings,ColorFormat,CursorCaptureSettings,DrawBorderSettings,SecondaryWindowSettings,MinimumUpdateIntervalSettings,DirtyRegionSettings},
    encoder::{VideoEncoder,VideoSettingsBuilder,VideoSettingsSubType,AudioSettingsBuilder,ContainerSettingsBuilder}};
use windows::Win32::{System::{Performance::{QueryPerformanceCounter,QueryPerformanceFrequency},WinRT::{RoInitialize,RoUninitialize,RO_INIT_MULTITHREADED}},Graphics::Gdi::{GetMonitorInfoW,HMONITOR,MONITORINFO}};
use crate::audio::AudioTrack;

type BoxError=Box<dyn Error+Send+Sync>;
#[derive(Debug,Clone,Serialize)]
#[serde(rename_all="camelCase")]
pub struct Source {pub id:String,pub label:String,pub kind:String,pub width:u32,pub height:u32,pub x:i32,pub y:i32}
#[derive(Clone,Copy)] enum Target{Display(Monitor),Window(Window)}
fn enumerate_targets()->Result<Vec<(Source,Target)>,String>{
    let mut result=Vec::new();
    for m in Monitor::enumerate().map_err(|e|e.to_string())? {
        let w=m.width().map_err(|e|e.to_string())?;let h=m.height().map_err(|e|e.to_string())?;
        let mut info=MONITORINFO{cbSize:std::mem::size_of::<MONITORINFO>() as u32,..Default::default()};
        unsafe{GetMonitorInfoW(HMONITOR(m.as_raw_hmonitor()),&mut info).ok().map_err(|e|e.to_string())?;}
        result.push((Source{id:format!("display:{:x}",m.as_raw_hmonitor() as usize),label:m.name().unwrap_or_else(|_|"显示器".into()),kind:"display".into(),width:w,height:h,x:info.rcMonitor.left,y:info.rcMonitor.top},Target::Display(m)));
    }
    for w in Window::enumerate().map_err(|e|e.to_string())? {
        if !w.is_valid() || w.process_id().ok()==Some(std::process::id()){continue;}
        let label=w.title().unwrap_or_default();if label.is_empty(){continue;}
        let Ok(r)=w.rect() else{continue};
        if r.right-r.left<2||r.bottom-r.top<2{continue;}
        result.push((Source{id:format!("window:{:x}",w.as_raw_hwnd() as usize),label,kind:"window".into(),width:(r.right-r.left)as u32,height:(r.bottom-r.top)as u32,x:r.left,y:r.top},Target::Window(w)));
    }
    Ok(result)
}
pub fn sources()->Result<Vec<Source>,String>{Ok(enumerate_targets()?.into_iter().map(|p|p.0).collect())}
fn resolve(id:&str)->Result<(Source,Target),String>{enumerate_targets()?.into_iter().find(|p|p.0.id==id).ok_or("捕获来源已关闭或显示器已改变，请刷新来源".into())}

pub fn qpc_hns()->Result<i64,String>{unsafe{
    let(mut c,mut f)=(0,0);QueryPerformanceCounter(&mut c).map_err(|e|e.to_string())?;
    QueryPerformanceFrequency(&mut f).map_err(|e|e.to_string())?;
    if f<=0{return Err("系统时钟无效".into());}Ok(((c as i128*10_000_000)/f as i128)as i64)
}}
struct Apartment;impl Apartment{fn new()->Result<Self,String>{unsafe{RoInitialize(RO_INIT_MULTITHREADED).map_err(|e|e.to_string())?;}Ok(Self)}}
impl Drop for Apartment{fn drop(&mut self){unsafe{RoUninitialize();}}}

struct Pixels{bytes:Vec<u8>,width:u32,height:u32}
#[derive(Default)]pub struct Probe{
    pub error:Mutex<Option<String>>,pub origin:AtomicI64,pub encoded:AtomicU64,
    pub system_level:AtomicU64,pub microphone_level:AtomicU64,
}
impl Probe{pub fn fail(&self,e:String){let mut g=self.error.lock();if g.is_none(){*g=Some(e);}}}
struct Mailbox{frame:Mutex<Option<Arc<Pixels>>>,changed:Condvar}
#[derive(Clone)]pub struct CaptureFlags{mailbox:Arc<Mailbox>,probe:Arc<Probe>,crop:Option<Crop>,fps:u32,cursor:bool,png:PathBuf}
pub struct Handler{flags:CaptureFlags,last:Option<Instant>,size:Option<(u32,u32)>}
impl GraphicsCaptureApiHandler for Handler{
    type Flags=CaptureFlags;type Error=BoxError;
    fn new(ctx:Context<Self::Flags>)->Result<Self,Self::Error>{Ok(Self{flags:ctx.flags,last:None,size:None})}
    fn on_frame_arrived(&mut self,frame:&mut Frame,control:InternalCaptureControl)->Result<(),Self::Error>{
        let work=(||->Result<(),BoxError>{
            if self.last.is_some_and(|t|t.elapsed()<Duration::from_secs_f64(1.0/self.flags.fps as f64)){return Ok(());}
            let source_size=(frame.width(),frame.height());
            if self.size.is_some_and(|s|s!=source_size){return Err("录制窗口尺寸改变；已停止当前分段，避免损坏输出".into());}
            let crop=self.flags.crop.unwrap_or(Crop{x:0,y:0,width:frame.width(),height:frame.height()}).validate(frame.width(),frame.height())?;
            if crop.width>7680||crop.height>4320{return Err("首版限制为 7680 × 4320 以内的 SDR 捕获".into());}
            let mut buffer=frame.buffer_crop(crop.x,crop.y,crop.x+crop.width,crop.y+crop.height)?;
            if self.size.is_none(){buffer.save_as_image(&self.flags.png,ImageFormat::Png)?;}
            let mut scratch=Vec::new();let raw=buffer.as_nopadding_buffer(&mut scratch);
            let bytes=flip_bgra_rows(raw,crop.width,crop.height)?;
            *self.flags.mailbox.frame.lock()=Some(Arc::new(Pixels{bytes,width:crop.width,height:crop.height}));
            self.flags.mailbox.changed.notify_all();self.size=Some(source_size);self.last=Some(Instant::now());Ok(())
        })();
        if let Err(ref e)=work{self.flags.probe.fail(e.to_string());control.stop();}work
    }
    fn on_closed(&mut self)->Result<(),Self::Error>{self.flags.probe.fail("捕获来源关闭或被系统中断".into());Ok(())}
}
struct Feed{control:Option<CaptureControl<Handler,BoxError>>,mailbox:Arc<Mailbox>,probe:Arc<Probe>,source:Source}
impl Feed{
    fn start(opts:&RecordOptions,png:&Path,probe:Arc<Probe>)->Result<Self,String>{
        let(source,target)=resolve(&opts.source_id)?;
        let mailbox=Arc::new(Mailbox{frame:Mutex::new(None),changed:Condvar::new()});
        let flags=CaptureFlags{mailbox:mailbox.clone(),probe:probe.clone(),crop:opts.crop,fps:opts.fps,cursor:opts.cursor,png:png.into()};
        macro_rules! settings{($item:expr)=>{Settings::new($item,if flags.cursor{CursorCaptureSettings::WithCursor}else{CursorCaptureSettings::WithoutCursor},DrawBorderSettings::Default,SecondaryWindowSettings::Default,MinimumUpdateIntervalSettings::Default,DirtyRegionSettings::Default,ColorFormat::Bgra8,flags.clone())}}
        let control=match target{Target::Display(m)=>Handler::start_free_threaded(settings!(m)),Target::Window(w)=>Handler::start_free_threaded(settings!(w))}.map_err(|e|e.to_string())?;
        let feed=Self{control:Some(control),mailbox,probe,source};
        let deadline=Instant::now()+Duration::from_secs(12);let mut frame=feed.mailbox.frame.lock();
        while frame.is_none(){
            if let Some(e)=feed.probe.error.lock().clone(){return Err(e);}
            if Instant::now()>=deadline{return Err("12 秒内没有收到画面。请检查屏幕录制权限、窗口是否最小化或内容是否受保护".into());}
            feed.mailbox.changed.wait_for(&mut frame,Duration::from_millis(100));
        }
        drop(frame);Ok(feed)
    }
    fn stop(&mut self)->Result<(),String>{if let Some(c)=self.control.take(){c.stop().map_err(|e|e.to_string())?;}Ok(())}
}
impl Drop for Feed{fn drop(&mut self){let _=self.stop();}}

pub struct NativeSegment{
    feed:Option<Feed>,halt:Arc<AtomicBool>,video:Option<JoinHandle<Result<u64,String>>>,
    audio:Vec<AudioTrack>,pub probe:Arc<Probe>,pub dimensions:Dimensions,pub source:Source,
    fps:u32,
}
impl NativeSegment{
    pub fn start(opts:&RecordOptions,dir:&Path)->Result<Self,String>{
        std::fs::create_dir(dir).map_err(|e|format!("不能创建新的录制分段（不会覆盖已有素材）：{e}"))?;
        let probe=Arc::new(Probe::default());let feed=Feed::start(opts,&dir.join("thumbnail.png"),probe.clone())?;
        let first=feed.mailbox.frame.lock().clone().ok_or("没有可用画面")?;
        let dims=Dimensions{width:first.width,height:first.height};let source=feed.source.clone();
        let halt=Arc::new(AtomicBool::new(false));
        let mut result=Self{feed:Some(feed),halt:halt.clone(),video:None,audio:vec![],probe:probe.clone(),dimensions:dims.clone(),source,fps:opts.fps};
        // Prepare audio devices first. They wait for the video encoder to publish the shared
        // QPC origin, so encoder startup latency cannot silently shift the audio timeline.
        if opts.system_audio{result.audio.push(AudioTrack::start(dir.join("system.wav"),true,probe.clone())?);}
        if opts.microphone{result.audio.push(AudioTrack::start(dir.join("microphone.wav"),false,probe.clone())?);}
        let mailbox=result.feed.as_ref().ok_or("捕获未初始化")?.mailbox.clone();
        let path=dir.join("video.mp4");let fps=opts.fps;let p=probe.clone();let (ready_tx,ready_rx)=mpsc::sync_channel(1);
        result.video=Some(thread::Builder::new().name("lens-video-writer".into()).spawn(move||{
            let run=(||->Result<u64,String>{
                let _apartment=Apartment::new()?;
                let mut encoder=VideoEncoder::new(VideoSettingsBuilder::new(dims.width,dims.height).sub_type(VideoSettingsSubType::H264).frame_rate(fps).bitrate(if fps==60{24_000_000}else{14_000_000}),AudioSettingsBuilder::default().disabled(true),ContainerSettingsBuilder::default(),path).map_err(|e|e.to_string())?;
                let origin=qpc_hns()?;
                let start=Instant::now();p.origin.store(origin,Ordering::Release);
                let _=ready_tx.send(Ok(()));
                let mut n=0u64;let mut writer_error=None;
                while !halt.load(Ordering::Acquire){
                    if p.error.lock().is_some(){break;}
                    let image=mailbox.frame.lock().clone().ok_or("捕获帧不可用")?;
                    if let Err(e)=encoder.send_frame_buffer(&image.bytes,video_timestamp(n,fps)){writer_error=Some(e.to_string());break;}
                    n+=1;p.encoded.store(n,Ordering::Release);
                    // CFR duplicates the last frame on static desktops; never accumulates a UI frame queue.
                    let due=start+Duration::from_secs_f64(n as f64/fps as f64);
                    if let Some(wait)=due.checked_duration_since(Instant::now()){thread::sleep(wait);}
                    else if start.elapsed().as_secs_f64()-n as f64/fps as f64>2.0{writer_error=Some("视频编码持续落后，已停止以保护内存与音画同步".into());break;}
                }
                encoder.finish().map_err(|e|e.to_string())?;
                if let Some(e)=writer_error{return Err(e);}if n==0{return Err("没有编码任何视频帧".into());}Ok(n)
            })();
            if let Err(ref e)=run{p.fail(e.clone());let _=ready_tx.try_send(Err(e.clone()));}run
        }).map_err(|e|e.to_string())?);
        ready_rx.recv_timeout(Duration::from_secs(15)).map_err(|_|"H.264 编码器初始化超时")??;
        Ok(result)
    }
    pub fn finish(mut self)->Result<f64,String>{
        self.halt.store(true,Ordering::Release);
        let mut failures=vec![];
        if let Some(mut feed)=self.feed.take(){if let Err(e)=feed.stop(){failures.push(e);}}
        let n=match self.video.take().ok_or("编码器未启动")?.join(){Ok(Ok(n))=>n,Ok(Err(e))=>{failures.push(e);self.probe.encoded.load(Ordering::Acquire)},Err(_)=>{failures.push("编码线程异常退出".into());0}};
        let duration=n as f64/self.fps as f64;
        for a in self.audio.drain(..){if let Err(e)=a.finish(duration){failures.push(e);}}
        if let Some(e)=self.probe.error.lock().clone(){failures.push(e);}
        if !failures.is_empty(){return Err(failures.join("；"));}Ok(duration)
    }
}
impl Drop for NativeSegment{fn drop(&mut self){
    self.halt.store(true,Ordering::Release);self.feed.take();
    if let Some(h)=self.video.take(){let _=h.join();}
    let d=self.probe.encoded.load(Ordering::Acquire)as f64/self.fps as f64;
    for a in self.audio.drain(..){let _=a.finish(d);}
}}
pub fn screenshot(opts:&RecordOptions,path:&Path)->Result<(Dimensions,Source),String>{
    let mut feed=Feed::start(opts,path,Arc::new(Probe::default()))?;
    let f=feed.mailbox.frame.lock().clone().ok_or("没有截图数据")?;
    let result=(Dimensions{width:f.width,height:f.height},feed.source.clone());feed.stop()?;Ok(result)
}
