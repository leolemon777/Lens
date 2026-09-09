use std::{fs,path::{Path,PathBuf},sync::{Arc,atomic::Ordering},time::Instant};
use parking_lot::Mutex;
use serde::Serialize;
use lens_core::{Project,Phase,RecordOptions,Segment,Manifest,atomic_json,read_json};
use crate::{native::{NativeSegment,Probe},media};

#[derive(Debug,Clone,Serialize)]
#[serde(rename_all="camelCase")]
pub struct Status{
    pub phase:Phase,pub elapsed_seconds:f64,pub project_path:Option<String>,pub message:String,
    pub system_level:u64,pub microphone_level:u64,pub free_gib:f64,
}
impl Default for Status{fn default()->Self{Self{phase:Phase::Idle,elapsed_seconds:0.0,project_path:None,message:"选择来源，开始记录".into(),system_level:0,microphone_level:0,free_gib:0.0}}}
struct Active{project:Project,opts:RecordOptions,native:Option<NativeSegment>,segment_started:Instant}
#[derive(Default)]struct Inner{active:Option<Active>}
pub struct Service{pub root:PathBuf,inner:Mutex<Inner>,status:Mutex<Status>,probe:Mutex<Option<Arc<Probe>>>}
impl Service{
    pub fn new(root:PathBuf)->Result<Arc<Self>,String>{
        fs::create_dir_all(&root).map_err(|e|e.to_string())?;
        // Only this Windows producer's stale sessions are marked interrupted. Never touch
        // a Mac project, an unknown schema, or a project outside the canonical library root.
        let canonical_root=root.canonicalize().map_err(|e|e.to_string())?;
        for entry in fs::read_dir(&root).map_err(|e|e.to_string())?.flatten() {
            let path=entry.path();
            if path.extension().and_then(|e|e.to_str())!=Some("lens"){continue;}
            let Ok(canonical)=path.canonicalize()else{continue;};
            if canonical.parent()!=Some(canonical_root.as_path()){continue;}
            let Ok(mut p)=Project::load(&path)else{continue;};
            if !["capturing","processing"].contains(&p.manifest.state.as_str()){continue;}
            let Ok(session)=read_json::<serde_json::Value>(&path.join("analysis/windows-session.json"))else{continue;};
            if session["producer"]=="lens-windows-rust"{p.manifest.state="interrupted".into();let _=p.save();}
        }
        Ok(Arc::new(Self{root,inner:Mutex::new(Inner::default()),status:Mutex::new(Status::default()),probe:Mutex::new(None)}))
    }
    pub fn notify(&self,message:impl Into<String>){self.status.lock().message=message.into();}
    pub fn status(&self)->Status{
        let mut s=self.status.lock().clone();
        if let Some(inner)=self.inner.try_lock(){if let Some(a)=&inner.active{if s.phase==Phase::Recording{s.elapsed_seconds=a.project.segments.duration()+a.segment_started.elapsed().as_secs_f64();}}}
        if let Some(p)=self.probe.lock().as_ref(){s.system_level=p.system_level.load(Ordering::Relaxed);s.microphone_level=p.microphone_level.load(Ordering::Relaxed);}
        s.free_gib=fs2::available_space(&self.root).unwrap_or(0)as f64/1_073_741_824.0;s
    }
    fn update(&self,phase:Phase,message:impl Into<String>){let mut s=self.status.lock();s.phase=phase;s.message=message.into();}
    pub fn start(&self,opts:RecordOptions)->Result<(),String>{
        opts.validate()?;
        let mut inner=self.inner.try_lock().ok_or("正在处理上一操作")?;
        if inner.active.is_some()||!self.status.lock().phase.may_start(){return Err("已有录制会话，请先停止保存".into());}
        if (opts.system_audio||opts.microphone)&&media::ffmpeg().is_none(){return Err("启用声音需要 FFmpeg 后处理组件。请运行 Prepare-Media.cmd 后重新构建，或关闭两个声音开关进行无声录制".into());}
        if fs2::available_space(&self.root).map_err(|e|e.to_string())?<2*1_073_741_824{return Err("可用空间不足 2 GiB，拒绝开始录制".into());}
        self.update(Phase::Starting,"正在初始化 Windows 捕获与音频设备…");
        let created=Project::create(&self.root,"recording",&opts.title);
        let mut project=match created{Ok(p)=>p,Err(e)=>{self.update(Phase::Idle,e.clone());return Err(e);}};
        let created_path=project.path.to_string_lossy().into_owned();self.status.lock().project_path=Some(created_path);
        let init=(||->Result<NativeSegment,String>{
            atomic_json(&project.path.join("analysis/windows-session.json"),&serde_json::json!({"producer":"lens-windows-rust","version":"0.1.0","options":&opts,"coordinateSystem":"source-local physical pixels, top-left"}))?;
            let native=NativeSegment::start(&opts,&project.path.join("raw/segments/0000"))?;
            project.manifest.dimensions=Some(native.dimensions.clone());
            project.add_asset("recordingSegments","events/segments.json")?;
            project.segments.segments.push(Segment{index:0,timeline_start_seconds:0.0,duration_seconds:None,screen_relative_path:"raw/segments/0000/screen.mp4".into(),microphone_relative_path:opts.microphone.then(||"raw/segments/0000/microphone.wav".into())});
            project.save()?;Ok(native)
        })();
        match init{
            Ok(native)=>{*self.probe.lock()=Some(native.probe.clone());inner.active=Some(Active{project,opts,native:Some(native),segment_started:Instant::now()});self.status.lock().elapsed_seconds=0.0;self.update(Phase::Recording,"正在录制 · Ctrl + Shift + F10 停止保存");Ok(())},
            Err(e)=>{project.manifest.state="failed".into();let _=project.save();self.update(Phase::Idle,e.clone());Err(e)}
        }
    }
    fn close_segment(&self,a:&mut Active)->Result<(),String>{
        let Some(native)=a.native.take()else{return Ok(())};
        let n=a.project.segments.segments.last().ok_or("分段索引缺失")?.index;
        let duration=native.finish()?;
        media::finish_segment(&a.project.path,n,duration,a.opts.system_audio)?;
        if let Some(s)=a.project.segments.segments.last_mut(){s.duration_seconds=Some(duration);}
        a.project.add_asset("screenVideoSegment",&format!("raw/segments/{n:04}/screen.mp4"))?;
        if a.opts.microphone{a.project.add_asset("microphoneSegment",&format!("raw/segments/{n:04}/microphone.wav"))?;}
        self.status.lock().elapsed_seconds=a.project.segments.duration();a.project.save()
    }
    pub fn pause(&self)->Result<(),String>{
        if media::ffmpeg().is_none(){return Err("分段暂停需要 FFmpeg 合并组件".into());}
        let mut inner=self.inner.try_lock().ok_or("正在处理上一操作")?;
        if !self.status.lock().phase.may_pause(){return Err("当前不是录制状态".into());}
        self.update(Phase::Pausing,"正在安全结束当前分段…");
        let a=inner.active.as_mut().ok_or("没有录制会话")?;
        let result=self.close_segment(a);*self.probe.lock()=None;
        match result{Ok(())=>{self.update(Phase::Paused,"已暂停 · 暂停时间不计入视频");Ok(())},Err(e)=>{a.project.manifest.state="interrupted".into();let _=a.project.save();self.update(Phase::Paused,format!("分段异常：{e}。可停止保存已完成部分"));Err(e)}}
    }
    pub fn resume(&self)->Result<(),String>{
        let mut inner=self.inner.try_lock().ok_or("正在处理上一操作")?;
        if !self.status.lock().phase.may_resume(){return Err("当前不是暂停状态".into());}
        let a=inner.active.as_mut().ok_or("没有录制会话")?;
        if a.project.segments.segments.iter().any(|s|s.duration_seconds.is_none()){return Err("当前项目有未完成分段，请停止保存后开始新录制".into());}
        self.update(Phase::Starting,"正在恢复录制…");
        let mut n=a.project.segments.segments.last().map(|s|s.index+1).unwrap_or(0);
        // Preserve orphan directories from failed starts; never reuse a raw segment path.
        while n<9999 && a.project.path.join(format!("raw/segments/{n:04}")).exists(){n+=1;}
        if n>=9999{self.update(Phase::Paused,"达到分段上限，请停止保存");return Err("达到分段上限".into());}
        let native=match NativeSegment::start(&a.opts,&a.project.path.join(format!("raw/segments/{n:04}"))){Ok(n)=>n,Err(e)=>{self.update(Phase::Paused,e.clone());return Err(e);}};
        let expected=a.project.manifest.dimensions.as_ref().ok_or("项目尺寸缺失")?;
        if native.dimensions.width!=expected.width||native.dimensions.height!=expected.height{drop(native);self.update(Phase::Paused,"来源尺寸改变，请停止并开始新录制");return Err("不能把不同尺寸的分段直接拼接".into());}
        a.project.segments.segments.push(Segment{index:n,timeline_start_seconds:a.project.segments.duration(),duration_seconds:None,screen_relative_path:format!("raw/segments/{n:04}/screen.mp4"),microphone_relative_path:a.opts.microphone.then(||format!("raw/segments/{n:04}/microphone.wav"))});
        *self.probe.lock()=Some(native.probe.clone());a.native=Some(native);a.segment_started=Instant::now();
        if let Err(e)=a.project.save(){if let Some(n)=a.native.take(){drop(n);}*self.probe.lock()=None;self.update(Phase::Paused,e.clone());return Err(e);}
        self.update(Phase::Recording,"正在录制 · 已恢复");Ok(())
    }
    pub fn stop(&self)->Result<String,String>{
        let mut inner=self.inner.try_lock().ok_or("正在处理上一操作")?;
        if !self.status.lock().phase.may_stop(){return Err("当前没有可停止的录制".into());}
        self.update(Phase::Stopping,"正在结束录制并保存分段…");
        let mut a=inner.active.take().ok_or("没有录制会话")?;
        let segment_error=self.close_segment(&mut a).err();*self.probe.lock()=None;
        self.update(Phase::Processing,"正在合并视频与独立音轨，原始素材保持不变…");
        a.project.manifest.state="processing".into();let save_result=a.project.save();
        let result=save_result.and_then(|_|media::finalize(&mut a.project,a.opts.microphone,a.opts.system_audio));
        let path=a.project.path.to_string_lossy().into_owned();
        match result{
            Ok(())=>{
                a.project.manifest.state=if segment_error.is_some(){"interrupted"}else{"ready"}.into();
                if let Err(e)=a.project.save(){self.update(Phase::Idle,format!("媒体已保存，但项目清单写入失败：{e}"));return Err(e);}
                self.status.lock().elapsed_seconds=a.project.segments.duration();
                self.update(Phase::Idle,match segment_error{Some(e)=>format!("已保存完成部分；最后分段异常：{e}"),None=>"已保存，可在素材库播放或打开文件夹".into()});Ok(path)
            },
            Err(e)=>{a.project.manifest.state="interrupted".into();let _=a.project.save();self.update(Phase::Idle,format!("原始分段已保留：{e}"));Err(e)}
        }
    }
    pub fn screenshot(&self,opts:RecordOptions)->Result<String,String>{
        opts.validate()?;let inner=self.inner.try_lock().ok_or("正在处理上一操作")?;
        if inner.active.is_some(){return Err("请先停止录制再截图".into());}
        self.update(Phase::Starting,"正在捕获 PNG…");
        let result=(||{let mut p=Project::create(&self.root,"screenshot",&opts.title)?;
            match crate::native::screenshot(&opts,&p.path.join("raw/screenshot.png")){
                Ok((d,_))=>{p.manifest.dimensions=Some(d);p.manifest.state="ready".into();p.add_asset("screenshot","raw/screenshot.png")?;p.add_asset("thumbnail","raw/screenshot.png")?;p.save()?;Ok(p.path.to_string_lossy().into_owned())},
                Err(e)=>{p.manifest.state="failed".into();let _=p.save();Err(e)}
            }
        })();self.update(Phase::Idle,match &result{Ok(_)=>"截图已保存".into(),Err(e)=>e.clone()});result
    }
    pub fn library(&self)->Result<Vec<LibraryItem>,String>{
        let mut list=Vec::new();
        for entry in fs::read_dir(&self.root).map_err(|e|e.to_string())?.flatten(){
            let path=entry.path();if path.extension().and_then(|v|v.to_str())!=Some("lens"){continue;}
            let canonical=match path.canonicalize(){Ok(p)=>p,Err(_)=>continue};
            let root=self.root.canonicalize().map_err(|e|e.to_string())?;if !canonical.starts_with(&root){continue;}
            if let Ok(p)=Project::load(&path){
                let preview=p.manifest.assets.iter().find(|a|a.role=="renderedVideo").or_else(||p.manifest.assets.iter().find(|a|a.role=="screenVideo"||a.role=="screenshot")).and_then(|a|p.resolve_existing(&a.relative_path).ok()).map(|p|p.to_string_lossy().into_owned());
                let thumb=p.manifest.assets.iter().find(|a|a.role=="thumbnail").and_then(|a|p.resolve_existing(&a.relative_path).ok()).map(|p|p.to_string_lossy().into_owned());
                let recoverable=path.join("analysis/windows-session.json").exists()&&p.segments.segments.iter().any(|s|s.duration_seconds.is_some())&&p.manifest.state!="ready";
                list.push(LibraryItem{path:path.to_string_lossy().into_owned(),manifest:p.manifest,preview,thumbnail:thumb,recoverable});
            }
        }
        list.sort_by(|a,b|b.manifest.created_at.cmp(&a.manifest.created_at));list.truncate(300);Ok(list)
    }
    pub fn owned_project(&self,path:&str)->Result<Project,String>{
        let requested=Path::new(path).canonicalize().map_err(|e|e.to_string())?;let root=self.root.canonicalize().map_err(|e|e.to_string())?;
        if requested.parent()!=Some(root.as_path())||requested.extension().and_then(|v|v.to_str())!=Some("lens"){return Err("只能操作 Lens 素材库中的项目".into());}Project::load(&requested)
    }
    pub fn retry_export(&self,path:&str)->Result<(),String>{
        let inner=self.inner.try_lock().ok_or("正在处理上一操作")?;if inner.active.is_some(){return Err("请先停止录制".into());}
        let mut p=self.owned_project(path)?;
        let session:serde_json::Value=read_json(&p.path.join("analysis/windows-session.json"))?;
        if session["producer"]!="lens-windows-rust"{return Err("不修改其他版本创建的项目".into());}
        let opts:RecordOptions=serde_json::from_value(session["options"].clone()).map_err(|e|e.to_string())?;
        self.update(Phase::Processing,"正在从已完成分段重新合成…");
        let result=media::finalize(&mut p,opts.microphone,opts.system_audio).and_then(|_|{p.manifest.state=if p.segments.segments.iter().any(|s|s.duration_seconds.is_none()){"interrupted"}else{"ready"}.into();p.save()});
        self.update(Phase::Idle,match &result{Ok(())=>"已恢复完成分段；未完成分段仍原样保留".into(),Err(e)=>e.clone()});result
    }
    pub fn monitor(self:&Arc<Self>){let weak=Arc::downgrade(self);std::thread::spawn(move||loop{
        std::thread::sleep(std::time::Duration::from_secs(1));let Some(s)=weak.upgrade()else{break};
        if s.status.lock().phase!=Phase::Recording{continue;}
        let error=s.probe.lock().as_ref().and_then(|p|p.error.lock().clone());
        let low=fs2::available_space(&s.root).map(|b|b<1_073_741_824).unwrap_or(true);
        if low||error.is_some(){let reason=error.unwrap_or_else(||"可用空间低于 1 GiB，自动安全停止".into());let _=s.stop();s.status.lock().message=format!("{reason}。已尝试保存；请查看素材库中的项目状态");}
    });}
}
#[derive(Serialize)]#[serde(rename_all="camelCase")]
pub struct LibraryItem{pub path:String,pub manifest:Manifest,pub preview:Option<String>,pub thumbnail:Option<String>,pub recoverable:bool}
