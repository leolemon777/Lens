//! FFmpeg is ONLY the post-recording mux/concatenate/mix stage, not screen capture.
use std::{fs,path::{Path,PathBuf},process::{Command,Stdio},thread,time::{Duration,Instant}};
use std::os::windows::process::CommandExt;
use lens_core::Project;

pub fn ffmpeg()->Option<PathBuf>{
    let base=std::env::current_exe().ok()?.parent()?.to_path_buf();
    let mut candidates=vec![base.join("tools/ffmpeg/bin/ffmpeg.exe"),base.join("tools/ffmpeg.exe")];
    if cfg!(debug_assertions){candidates.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("../tools/ffmpeg/bin/ffmpeg.exe"));}
    candidates.into_iter().find(|p|p.is_file())
}
fn run(project:&Path,args:&[String])->Result<(),String>{
    let exe=ffmpeg().ok_or("缺少 FFmpeg 后处理组件。运行 scripts/prepare-media.ps1 后重新构建；原始视频和音轨不会删除")?;
    let log=fs::OpenOptions::new().create(true).append(true).open(project.join("diagnostics/export.log")).map_err(|e|e.to_string())?;
    let mut child=Command::new(exe).args(["-hide_banner","-nostdin","-loglevel","error","-y"]).args(args).current_dir(project).stdin(Stdio::null()).stdout(Stdio::null()).stderr(log).creation_flags(0x08000000).spawn().map_err(|e|e.to_string())?;
    let deadline=Instant::now()+Duration::from_secs(900);
    loop{
        let status=match child.try_wait(){Ok(s)=>s,Err(e)=>{let _=child.kill();let _=child.wait();return Err(e.to_string());}};
        match status{
            Some(s) if s.success()=>return Ok(()),
            Some(_)=>return Err("媒体合成失败，原始分段已保留。详细信息见项目 diagnostics/export.log".into()),
            None if Instant::now()>=deadline=>{let _=child.kill();let _=child.wait();return Err("媒体合成超时，原始分段已保留".into());},
            None=>thread::sleep(Duration::from_millis(100)),
        }
    }
}
fn args(a:&[&str])->Vec<String>{a.iter().map(|s|s.to_string()).collect()}
pub fn finish_segment(project:&Path,index:u32,duration:f64,system:bool)->Result<(),String>{
    let prefix=format!("raw/segments/{index:04}");let src=format!("{prefix}/video.mp4");let dst=format!("{prefix}/screen.mp4");
    if system{
        run(project,&args(&["-i",&src,"-i",&format!("{prefix}/system.wav"),"-map","0:v:0","-map","1:a:0","-c:v","copy","-c:a","aac","-b:a","192k","-t",&format!("{duration:.9}"),"-movflags","+faststart",&dst]))?;
    }else{fs::copy(project.join(src),project.join(&dst)).map_err(|e|e.to_string())?;}
    if fs::metadata(project.join(dst)).map_err(|e|e.to_string())?.len()<128{return Err("生成的视频文件为空".into());}Ok(())
}

pub fn finalize(project:&mut Project,microphone:bool,system:bool)->Result<(),String>{
    let completed:Vec<_>=project.segments.segments.iter().filter(|s|s.duration_seconds.is_some()).cloned().collect();
    if completed.is_empty(){return Err("没有已完成的录制分段；请保留项目原始文件".into());}
    let duration: f64=completed.iter().filter_map(|s|s.duration_seconds).sum();
    if completed.len()==1{
        let src=project.resolve_existing(&completed[0].screen_relative_path)?;
        fs::copy(src,project.path.join("raw/screen.mp4")).map_err(|e|e.to_string())?;
    }else{
        let mut list=String::new();
        for s in &completed{
            // Only generated numeric index paths may enter an ffconcat file, never user text.
            let expected=format!("raw/segments/{:04}/screen.mp4",s.index);
            if s.screen_relative_path!=expected{return Err("分段路径不符合本版本导出约束".into());}
            project.resolve_existing(&expected)?;
            list.push_str(&format!("file 'segments/{:04}/screen.mp4'\n",s.index));
        }
        fs::write(project.path.join("raw/video-concat.txt"),list).map_err(|e|e.to_string())?;
        run(&project.path,&args(&["-f","concat","-safe","1","-i","raw/video-concat.txt","-c","copy","-movflags","+faststart","raw/screen.mp4"]))?;
    }
    project.add_asset("screenVideo","raw/screen.mp4")?;
    if system {
        let mut list=String::new();
        for s in &completed {
            project.resolve_existing(&format!("raw/segments/{:04}/system.wav",s.index))?;
            list.push_str(&format!("file 'segments/{:04}/system.wav'\n",s.index));
        }
        fs::write(project.path.join("raw/system-concat.txt"),list).map_err(|e|e.to_string())?;
        run(&project.path,&args(&["-f","concat","-safe","1","-i","raw/system-concat.txt","-c:a","pcm_s16le","raw/system.wav"]))?;
        project.add_asset("systemAudio","raw/system.wav")?;
    }
    if microphone{
        let mut list=String::new();for s in &completed{
            let expected=format!("raw/segments/{:04}/microphone.wav",s.index);project.resolve_existing(&expected)?;
            list.push_str(&format!("file 'segments/{:04}/microphone.wav'\n",s.index));
        }
        fs::write(project.path.join("raw/mic-concat.txt"),list).map_err(|e|e.to_string())?;
        run(&project.path,&args(&["-f","concat","-safe","1","-i","raw/mic-concat.txt","-c:a","pcm_s16le","raw/microphone.wav"]))?;
        project.add_asset("microphone","raw/microphone.wav")?;
        let mut a=args(&["-i","raw/screen.mp4","-i","raw/microphone.wav"]);
        if system{a.extend(args(&["-filter_complex","[0:a:0][1:a:0]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[a]","-map","0:v:0","-map","[a]"]));}
        else{a.extend(args(&["-map","0:v:0","-map","1:a:0"]));}
        a.extend(args(&["-c:v","copy","-c:a","aac","-b:a","192k","-t",&format!("{duration:.9}"),"-movflags","+faststart","previews/preview.mp4"]));run(&project.path,&a)?;
    }else{fs::copy(project.path.join("raw/screen.mp4"),project.path.join("previews/preview.mp4")).map_err(|e|e.to_string())?;}
    let thumb=project.path.join(format!("raw/segments/{:04}/thumbnail.png",completed[0].index));
    if thumb.exists(){fs::copy(thumb,project.path.join("previews/thumbnail.png")).map_err(|e|e.to_string())?;project.add_asset("thumbnail","previews/thumbnail.png")?;}
    project.add_asset("renderedVideo","previews/preview.mp4")?;
    project.manifest.duration_seconds=Some(duration);Ok(())
}
