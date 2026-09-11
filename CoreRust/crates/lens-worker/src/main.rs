use std::io::{Read, Write};

use lens_core::edit::{plan_auto_camera, plan_captions, CaptionCue, LensPoint, TranscriptSegment};
use lens_core::manifest::LensManifest;
use lens_core::protocol::{
    CoreWorkerProtocol, HandshakeResponse, TaskRequest, TaskResponse, CURRENT_VERSION,
};

fn main() {
    let mut stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 8192];

    loop {
        match stdin.read(&mut chunk) {
            Ok(0) => break, // EOF, worker exits gracefully
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);

                loop {
                    match lens_core::protocol::read_frame(&buffer) {
                        Ok(Some((consumed, payload))) => {
                            let frame_payload = payload.clone();
                            buffer.drain(..consumed);

                            // Try handshake request first
                            if let Ok(request) =
                                CoreWorkerProtocol::decode_handshake(&frame_payload)
                            {
                                let response = HandshakeResponse {
                                    protocol_version: CURRENT_VERSION,
                                    request_id: Some(request.request_id),
                                    supported_capabilities: vec![
                                        "captionPlanning".into(),
                                        "projectSchema".into(),
                                        "renderExport".into(),
                                        "autoCamera".into(),
                                    ],
                                    worker_version: "0.1.0".into(),
                                };
                                if let Ok(frame) =
                                    CoreWorkerProtocol::encode_handshake_response(&response)
                                {
                                    let _ = stdout.write_all(&frame);
                                    let _ = stdout.flush();
                                }
                                continue;
                            }

                            // Try task request
                            if let Ok(task) =
                                CoreWorkerProtocol::decode_task_request(&frame_payload)
                            {
                                if task.action == "shutdown" {
                                    return;
                                }
                                let response = handle_task(task);
                                if let Ok(frame) =
                                    CoreWorkerProtocol::encode_task_response(&response)
                                {
                                    let _ = stdout.write_all(&frame);
                                    let _ = stdout.flush();
                                }
                                continue;
                            }

                            // If not recognized as handshake or task, reply with worker error frame
                            let err_frame = lens_core::protocol::write_frame(
                                br#"{"code":"unknownPayload","protocolVersion":1}"#,
                            )
                            .unwrap_or_default();
                            let _ = stdout.write_all(&err_frame);
                            let _ = stdout.flush();
                        }
                        Ok(None) => break, // Need more bytes for a complete frame
                        Err(e) => {
                            eprintln!("frame error: {e}");
                            std::process::exit(1);
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("stdin read failed: {e}");
                std::process::exit(1);
            }
        }
    }
}

fn handle_task(task: TaskRequest) -> TaskResponse {
    let task_id = task.task_id;
    match task.action.as_str() {
        "ping" => TaskResponse {
            task_id,
            status: "success".into(),
            progress: Some(1.0),
            result: Some(serde_json::json!({ "pong": true })),
            error_message: None,
        },
        // Bounded diagnostic action used to verify timeout/cancellation without
        // depending on GPU, codecs, or a particular media fixture.
        "diagnostic_wait" => {
            let millis = task
                .payload
                .get("milliseconds")
                .and_then(|value| value.as_u64())
                .unwrap_or(100)
                .min(30_000);
            std::thread::sleep(std::time::Duration::from_millis(millis));
            TaskResponse {
                task_id,
                status: "success".into(),
                progress: Some(1.0),
                result: Some(serde_json::json!({ "waitedMilliseconds": millis })),
                error_message: None,
            }
        }
        "validate_manifest" => {
            let manifest_res: Result<LensManifest, _> = serde_json::from_value(task.payload);
            match manifest_res {
                Ok(manifest) => match manifest.validate() {
                    Ok(_) => TaskResponse {
                        task_id,
                        status: "success".into(),
                        progress: Some(1.0),
                        result: Some(serde_json::json!({ "valid": true })),
                        error_message: None,
                    },
                    Err(err) => TaskResponse {
                        task_id,
                        status: "error".into(),
                        progress: None,
                        result: None,
                        error_message: Some(format!("manifest validation failed: {err}")),
                    },
                },
                Err(err) => TaskResponse {
                    task_id,
                    status: "error".into(),
                    progress: None,
                    result: None,
                    error_message: Some(format!("failed to deserialize manifest: {err}")),
                },
            }
        }
        "caption_plan" => {
            let segments_res: Result<Vec<TranscriptSegment>, _> =
                serde_json::from_value(task.payload.get("segments").cloned().unwrap_or_default());
            let max_chars = task
                .payload
                .get("maxChars")
                .and_then(|v| v.as_u64())
                .unwrap_or(42) as usize;
            match segments_res {
                Ok(segments) => {
                    let cues: Vec<CaptionCue> = plan_captions(&segments, max_chars);
                    TaskResponse {
                        task_id,
                        status: "success".into(),
                        progress: Some(1.0),
                        result: Some(serde_json::to_value(&cues).unwrap_or_default()),
                        error_message: None,
                    }
                }
                Err(err) => TaskResponse {
                    task_id,
                    status: "error".into(),
                    progress: None,
                    result: None,
                    error_message: Some(format!("invalid segments payload: {err}")),
                },
            }
        }
        "camera_plan" => {
            let duration = task
                .payload
                .get("duration")
                .and_then(|v| v.as_f64())
                .unwrap_or(1.0);
            let clicks_res: Result<Vec<(f64, LensPoint)>, _> =
                serde_json::from_value(task.payload.get("clicks").cloned().unwrap_or_default());
            let clicks = clicks_res.unwrap_or_default();
            let keyframes = plan_auto_camera(duration, &clicks);
            TaskResponse {
                task_id,
                status: "success".into(),
                progress: Some(1.0),
                result: Some(serde_json::to_value(&keyframes).unwrap_or_default()),
                error_message: None,
            }
        }
        "render_package" => {
            let root_str = task
                .payload
                .get("root")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let timeline_res: Result<lens_core::edit::VideoEditTimeline, _> =
                serde_json::from_value(task.payload.get("timeline").cloned().unwrap_or_default());
            match timeline_res {
                Ok(timeline) => {
                    match lens_project::render::render_package_for_task(
                        std::path::Path::new(root_str),
                        &timeline,
                        &task_id,
                    ) {
                        Ok(p) => TaskResponse {
                            task_id,
                            status: "success".into(),
                            progress: Some(1.0),
                            result: Some(
                                serde_json::json!({ "path": p.to_string_lossy().into_owned() }),
                            ),
                            error_message: None,
                        },
                        Err(e) => TaskResponse {
                            task_id,
                            status: "error".into(),
                            progress: None,
                            result: None,
                            error_message: Some(e.to_string()),
                        },
                    }
                }
                Err(e) => TaskResponse {
                    task_id,
                    status: "error".into(),
                    progress: None,
                    result: None,
                    error_message: Some(format!("invalid timeline payload: {e}")),
                },
            }
        }
        "export_package" => {
            let root_str = task
                .payload
                .get("root")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let preset = task
                .payload
                .get("preset")
                .and_then(|v| v.as_str())
                .unwrap_or("original");
            match lens_project::render::export_package_for_task(
                std::path::Path::new(root_str),
                preset,
                &task_id,
            ) {
                Ok(p) => TaskResponse {
                    task_id,
                    status: "success".into(),
                    progress: Some(1.0),
                    result: Some(serde_json::json!({ "path": p.to_string_lossy().into_owned() })),
                    error_message: None,
                },
                Err(e) => TaskResponse {
                    task_id,
                    status: "error".into(),
                    progress: None,
                    result: None,
                    error_message: Some(e.to_string()),
                },
            }
        }
        other => TaskResponse {
            task_id,
            status: "error".into(),
            progress: None,
            result: None,
            error_message: Some(format!("unsupported worker action: {other}")),
        },
    }
}
