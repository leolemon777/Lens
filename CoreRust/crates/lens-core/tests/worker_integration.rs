use lens_core::WorkerClient;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn worker_client_ping_and_task_execution_roundtrip() {
    let mut client = WorkerClient::new();
    let resp = client.execute_task("ping", serde_json::json!({}), Duration::from_secs(10));
    assert!(resp.is_ok(), "ping task should succeed: {resp:?}");
    let task_resp = resp.unwrap();
    assert_eq!(task_resp.status, "success");
    assert_eq!(
        task_resp.result.unwrap().get("pong"),
        Some(&serde_json::json!(true))
    );

    // Test camera_plan execution
    let payload = serde_json::json!({
        "duration": 3.0,
        "clicks": [[1.0, {"x": 0.3, "y": 0.4}]],
    });
    let cam_resp = client.execute_task("camera_plan", payload, Duration::from_secs(10));
    assert!(
        cam_resp.is_ok(),
        "camera_plan should succeed in worker: {cam_resp:?}"
    );
    let cam_result = cam_resp.unwrap().result.unwrap();
    assert!(cam_result.is_array());
    assert!(!cam_result.as_array().unwrap().is_empty());
}

#[test]
fn worker_client_survives_worker_process_kill_and_recovers() {
    let mut client = WorkerClient::new();
    // 1. Initial task to start worker
    let resp1 = client.execute_task("ping", serde_json::json!({}), Duration::from_secs(10));
    assert!(resp1.is_ok());

    // 2. Kill the worker sub-process directly
    client.kill();
    assert!(!client.is_alive());

    // 3. Client must survive, automatically restart the worker, and succeed
    let resp2 = client.execute_task("ping", serde_json::json!({}), Duration::from_secs(10));
    assert!(
        resp2.is_ok(),
        "client should restart worker and succeed: {resp2:?}"
    );
    assert!(client.is_alive());
    client.shutdown();
    assert!(!client.is_alive());
}

#[test]
fn worker_client_cancels_running_task_without_retrying_it() {
    let cancel = Arc::new(AtomicBool::new(false));
    let worker_cancel = Arc::clone(&cancel);
    let started = Instant::now();
    let task = thread::spawn(move || {
        let mut client = WorkerClient::new();
        client.execute_task_cancellable(
            Some("cancel-integration-test"),
            "diagnostic_wait",
            serde_json::json!({ "milliseconds": 10_000 }),
            Duration::from_secs(20),
            &worker_cancel,
        )
    });

    thread::sleep(Duration::from_millis(300));
    cancel.store(true, Ordering::SeqCst);
    let result = task.join().expect("cancellation task joins");
    let err = result.expect_err("task should be cancelled");
    assert!(
        err.contains("cancelled"),
        "expected cancelled error, got: {err}"
    );
    assert!(
        started.elapsed() < Duration::from_secs(4),
        "cancellation must not wait for the diagnostic task or retry it"
    );

    let mut next = WorkerClient::new();
    assert!(next
        .execute_task("ping", serde_json::json!({}), Duration::from_secs(10))
        .is_ok());
}

#[test]
fn worker_client_timeout_is_total_across_retries() {
    let started = Instant::now();
    let mut client = WorkerClient::new();
    let result = client.execute_task(
        "diagnostic_wait",
        serde_json::json!({ "milliseconds": 10_000 }),
        Duration::from_millis(350),
    );
    assert!(result
        .expect_err("task should time out")
        .contains("timed out"));
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "timeout is a total deadline and must not restart a second full wait"
    );
}
