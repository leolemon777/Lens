//! Client for spawning and communicating with the out-of-process `lens-worker`.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use super::protocol::{
    read_frame, CoreWorkerProtocol, HandshakeRequest, TaskRequest, TaskResponse, CURRENT_VERSION,
};

pub struct WorkerClient {
    child: Option<Child>,
    worker_path: Option<PathBuf>,
}

impl Default for WorkerClient {
    fn default() -> Self {
        Self::new()
    }
}

impl WorkerClient {
    pub fn new() -> Self {
        Self {
            child: None,
            worker_path: find_worker_binary(),
        }
    }

    pub fn with_worker_path(path: PathBuf) -> Self {
        Self {
            child: None,
            worker_path: Some(path),
        }
    }

    pub fn is_alive(&mut self) -> bool {
        if let Some(ref mut child) = self.child {
            match child.try_wait() {
                Ok(None) => true,
                _ => false,
            }
        } else {
            false
        }
    }

    pub fn kill(&mut self) {
        if let Some(ref mut child) = self.child {
            kill_process_tree(child.id());
            let _ = child.kill();
            let _ = child.wait();
        }
        self.child = None;
    }

    pub fn shutdown(&mut self) {
        let Some(child) = self.child.as_mut() else {
            return;
        };
        let request = TaskRequest {
            task_id: "shutdown".into(),
            action: "shutdown".into(),
            payload: serde_json::json!({}),
        };
        let sent = CoreWorkerProtocol::encode_task_request(&request)
            .ok()
            .and_then(|frame| {
                let stdin = child.stdin.as_mut()?;
                stdin.write_all(&frame).ok()?;
                stdin.flush().ok()?;
                Some(())
            })
            .is_some();
        if sent {
            for _ in 0..50 {
                match child.try_wait() {
                    Ok(Some(_)) => {
                        self.child = None;
                        return;
                    }
                    Ok(None) => thread::sleep(Duration::from_millis(20)),
                    Err(_) => break,
                }
            }
        }
        self.kill();
    }

    fn ensure_started(&mut self) -> Result<(), String> {
        if self.is_alive() {
            return Ok(());
        }

        let worker_path = self.worker_path.as_ref().ok_or_else(|| {
            "lens-worker binary not found in environment or application bundle".to_string()
        })?;

        if !worker_path.is_file() {
            return Err(format!(
                "worker binary not found at: {}",
                worker_path.display()
            ));
        }

        let mut cmd = Command::new(worker_path);
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("failed to spawn lens-worker: {e}"))?;

        // Perform protocol handshake
        let handshake_req = HandshakeRequest {
            client_name: "lens-host".into(),
            protocol_version: CURRENT_VERSION,
            request_id: format!(
                "hs-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis())
                    .unwrap_or(0)
            ),
            requested_capabilities: vec![
                "captionPlanning".into(),
                "projectSchema".into(),
                "renderExport".into(),
                "autoCamera".into(),
            ],
        };

        let frame = CoreWorkerProtocol::encode_handshake_request(&handshake_req)
            .map_err(|e| format!("handshake encode error: {e}"))?;

        let stdin = child.stdin.as_mut().ok_or("failed to open worker stdin")?;
        stdin
            .write_all(&frame)
            .map_err(|e| format!("failed to write handshake: {e}"))?;
        stdin
            .flush()
            .map_err(|e| format!("failed to flush handshake: {e}"))?;

        let mut stdout = child.stdout.take().ok_or("failed to open worker stdout")?;
        let (tx, rx) = channel();
        thread::spawn(move || {
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                match stdout.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => {
                        buf.extend_from_slice(&chunk[..n]);
                        if let Ok(Some((_consumed, payload))) = read_frame(&buf) {
                            let _ = tx.send((Ok(payload), stdout));
                            return;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send((Err(e.to_string()), stdout));
                        return;
                    }
                }
            }
        });

        let (payload_res, returned_stdout) = rx
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| "handshake with worker timed out".to_string())?;
        child.stdout = Some(returned_stdout);

        let payload = payload_res?;
        let _handshake_resp = CoreWorkerProtocol::decode_handshake_response(&payload)
            .map_err(|e| format!("handshake response decode error: {e}"))?;

        self.child = Some(child);
        Ok(())
    }

    pub fn execute_task(
        &mut self,
        action: &str,
        payload: serde_json::Value,
        timeout: Duration,
    ) -> Result<TaskResponse, String> {
        let cancel = AtomicBool::new(false);
        self.execute_task_cancellable(None, action, payload, timeout, &cancel)
    }

    pub fn execute_task_cancellable(
        &mut self,
        task_id: Option<&str>,
        action: &str,
        payload: serde_json::Value,
        timeout: Duration,
        cancel: &AtomicBool,
    ) -> Result<TaskResponse, String> {
        let started = Instant::now();
        match self.execute_task_once(task_id, action, &payload, timeout, cancel) {
            Ok(resp) => Ok(resp),
            Err(first_err) => {
                self.kill();
                if cancel.load(Ordering::SeqCst) {
                    return Err(format!("worker task '{action}' cancelled"));
                }
                let Some(remaining) = timeout.checked_sub(started.elapsed()) else {
                    return Err(first_err);
                };
                if remaining.is_zero() {
                    return Err(first_err);
                }
                match self.execute_task_once(task_id, action, &payload, remaining, cancel) {
                    Ok(resp) => Ok(resp),
                    Err(second_err) => Err(format!(
                        "worker task '{action}' failed (attempt 1: {first_err}; attempt 2: {second_err})"
                    )),
                }
            }
        }
    }

    fn execute_task_once(
        &mut self,
        requested_task_id: Option<&str>,
        action: &str,
        payload: &serde_json::Value,
        timeout: Duration,
        cancel: &AtomicBool,
    ) -> Result<TaskResponse, String> {
        if cancel.load(Ordering::SeqCst) {
            return Err(format!("worker task '{action}' cancelled"));
        }
        self.ensure_started()?;

        let task_id = requested_task_id.map(str::to_owned).unwrap_or_else(|| {
            format!(
                "task-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            )
        });
        let request = TaskRequest {
            task_id: task_id.clone(),
            action: action.to_string(),
            payload: payload.clone(),
        };

        let frame = CoreWorkerProtocol::encode_task_request(&request)
            .map_err(|e| format!("encode task request error: {e}"))?;

        let child = self.child.as_mut().ok_or("worker not running")?;
        let stdin = child.stdin.as_mut().ok_or("worker stdin unavailable")?;
        stdin
            .write_all(&frame)
            .map_err(|e| format!("failed to write task to worker: {e}"))?;
        stdin
            .flush()
            .map_err(|e| format!("failed to flush task to worker: {e}"))?;

        let mut stdout = child.stdout.take().ok_or("worker stdout unavailable")?;
        let (tx, rx) = channel();

        thread::spawn(move || {
            let mut buf = Vec::new();
            let mut chunk = [0u8; 8192];
            loop {
                match stdout.read(&mut chunk) {
                    Ok(0) => {
                        let _ =
                            tx.send((Err("worker stdout closed prematurely".to_string()), stdout));
                        return;
                    }
                    Ok(n) => {
                        buf.extend_from_slice(&chunk[..n]);
                        match read_frame(&buf) {
                            Ok(Some((_consumed, payload))) => {
                                let _ = tx.send((Ok(payload), stdout));
                                return;
                            }
                            Ok(None) => continue,
                            Err(e) => {
                                let _ =
                                    tx.send((Err(format!("protocol frame error: {e}")), stdout));
                                return;
                            }
                        }
                    }
                    Err(e) => {
                        let _ = tx.send((Err(e.to_string()), stdout));
                        return;
                    }
                }
            }
        });

        let started = Instant::now();
        let (payload_res, returned_stdout) = loop {
            if cancel.load(Ordering::SeqCst) {
                self.kill();
                return Err(format!("worker task '{action}' cancelled"));
            }
            let elapsed = started.elapsed();
            if elapsed >= timeout {
                self.kill();
                return Err(format!(
                    "worker task '{action}' timed out after {timeout:?}"
                ));
            }
            let wait = (timeout - elapsed).min(Duration::from_millis(50));
            match rx.recv_timeout(wait) {
                Ok(pair) => break pair,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => {
                    return Err("worker communication thread disconnected".into());
                }
            }
        };

        if let Some(ref mut c) = self.child {
            c.stdout = Some(returned_stdout);
        }

        let resp_bytes = payload_res?;
        let resp = CoreWorkerProtocol::decode_task_response(&resp_bytes)
            .map_err(|e| format!("failed to decode task response: {e}"))?;

        if resp.status == "error" {
            Err(resp
                .error_message
                .unwrap_or_else(|| "unspecified worker error".into()))
        } else {
            Ok(resp)
        }
    }
}

#[cfg(windows)]
fn kill_process_tree(pid: u32) {
    use std::os::windows::process::CommandExt;
    let _ = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .creation_flags(0x08000000)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

#[cfg(not(windows))]
fn kill_process_tree(_pid: u32) {}

impl Drop for WorkerClient {
    fn drop(&mut self) {
        self.shutdown();
    }
}

pub fn find_worker_binary() -> Option<PathBuf> {
    if let Ok(val) = std::env::var("LENS_WORKER_PATH") {
        let p = PathBuf::from(val);
        if p.is_file() {
            return Some(p);
        }
    }

    let binary_name = if cfg!(windows) {
        "lens-worker.exe"
    } else {
        "lens-worker"
    };

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidates = [
                dir.join(binary_name),
                dir.join("..").join(binary_name),
                dir.join("bin").join(binary_name),
                dir.join("tools").join(binary_name),
                dir.join("resources").join(binary_name),
                dir.join("resources").join("bin").join(binary_name),
                dir.join("../../../CoreRust/target/release")
                    .join(binary_name),
                dir.join("../../../CoreRust/target/debug").join(binary_name),
                dir.join("../../target/release").join(binary_name),
                dir.join("../../target/debug").join(binary_name),
            ];
            for c in candidates {
                if c.is_file() {
                    return Some(c);
                }
            }
        }
    }

    let cwd_candidates = [
        PathBuf::from("CoreRust/target/release").join(binary_name),
        PathBuf::from("CoreRust/target/debug").join(binary_name),
        PathBuf::from("target/release").join(binary_name),
        PathBuf::from("target/debug").join(binary_name),
    ];
    for c in cwd_candidates {
        if c.is_file() {
            return Some(c);
        }
    }

    None
}
