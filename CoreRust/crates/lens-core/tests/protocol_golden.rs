//! Golden tests against the checked-in protocol fixture. These run in CI and
//! on developer machines; the fixture path is resolved relative to the crate.

use lens_core::protocol::*;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct GoldenCase {
    name: String,
    #[serde(rename = "payloadJSON")]
    payload_json: String,
    #[serde(rename = "frameHex")]
    frame_hex: String,
}

#[derive(Debug, Deserialize)]
struct GoldenFile {
    #[serde(rename = "schemaVersion")]
    schema_version: i32,
    transport: String,
    cases: Vec<GoldenCase>,
}

fn load_golden() -> GoldenFile {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../Tests/LensCoreTests/Fixtures/core-worker-protocol-v1-golden.json"
    );
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read golden fixture at {path}: {e}"));
    serde_json::from_str(&text).expect("golden fixture is valid JSON")
}

fn decode_hex(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("valid hex byte"))
        .collect()
}

#[test]
fn golden_transport_is_uint32_be_length() {
    let golden = load_golden();
    assert_eq!(golden.schema_version, 1);
    assert_eq!(golden.transport, "uint32-be-length + utf8-json");
}

#[test]
fn golden_handshake_request_frame_roundtrip() {
    let golden = load_golden();
    let case = golden
        .cases
        .iter()
        .find(|c| c.name == "handshake-request")
        .expect("handshake-request case");

    let frame = decode_hex(&case.frame_hex);
    let (consumed, payload) = read_frame(&frame)
        .expect("valid frame")
        .expect("complete frame");
    assert_eq!(consumed, frame.len());
    assert_eq!(payload, case.payload_json.as_bytes());

    // Decode the request and verify field semantics.
    let request = CoreWorkerProtocol::decode_handshake(&payload).expect("valid handshake");
    assert_eq!(request.client_name, "LensMac");
    assert_eq!(request.protocol_version, 1);
    assert_eq!(request.request_id, "4AA56F49-AF0A-4A5B-89F6-45D7FA0455E1");
    assert!(request
        .requested_capabilities
        .contains(&"captionPlanning".to_string()));
    assert!(request
        .requested_capabilities
        .contains(&"projectSchema".to_string()));
}

#[test]
fn golden_handshake_response_frame_roundtrip() {
    let golden = load_golden();
    let case = golden
        .cases
        .iter()
        .find(|c| c.name == "handshake-response")
        .expect("handshake-response case");

    let frame = decode_hex(&case.frame_hex);
    let (_, payload) = read_frame(&frame)
        .expect("valid frame")
        .expect("complete frame");
    assert_eq!(payload, case.payload_json.as_bytes());

    let response = CoreWorkerProtocol::decode_handshake_response(&payload).expect("valid response");
    assert_eq!(response.protocol_version, 1);
    assert_eq!(
        response.request_id.as_deref(),
        Some("4AA56F49-AF0A-4A5B-89F6-45D7FA0455E1")
    );
    assert!(response
        .supported_capabilities
        .contains(&"captionPlanning".to_string()));
    assert_eq!(response.worker_version, "0.1.0");
}

#[test]
fn golden_worker_error_frame_roundtrip() {
    let golden = load_golden();
    let case = golden
        .cases
        .iter()
        .find(|c| c.name == "worker-error")
        .expect("worker-error case");

    let frame = decode_hex(&case.frame_hex);
    let (_, payload) = read_frame(&frame)
        .expect("valid frame")
        .expect("complete frame");
    assert_eq!(payload, case.payload_json.as_bytes());

    let error = CoreWorkerProtocol::decode_worker_error(&payload).expect("valid error");
    assert_eq!(error.code, "workerUnavailable");
    assert_eq!(error.protocol_version, 1);
}

#[test]
fn golden_frame_prefix_length_matches() {
    let golden = load_golden();
    for case in &golden.cases {
        let frame = decode_hex(&case.frame_hex);
        let length = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        assert_eq!(
            length,
            case.payload_json.len(),
            "prefix length matches payload for {}",
            case.name
        );
    assert_eq!(
            frame.len(),
            4 + length,
            "total frame size for {}",
            case.name
        );
    }
}

#[test]
fn task_request_and_response_roundtrip() {
    let req = TaskRequest {
        task_id: "T-001".into(),
        action: "caption_plan".into(),
        payload: serde_json::json!({ "maxChars": 30 }),
    };
    let frame = CoreWorkerProtocol::encode_task_request(&req).expect("encode task request");
    let (consumed, payload) = read_frame(&frame).unwrap().unwrap();
    assert_eq!(consumed, frame.len());
    let decoded_req = CoreWorkerProtocol::decode_task_request(&payload).expect("decode task request");
    assert_eq!(decoded_req.task_id, "T-001");
    assert_eq!(decoded_req.action, "caption_plan");

    let resp = TaskResponse {
        task_id: "T-001".into(),
        status: "success".into(),
        progress: Some(1.0),
        result: Some(serde_json::json!({ "ok": true })),
        error_message: None,
    };
    let frame_resp = CoreWorkerProtocol::encode_task_response(&resp).expect("encode task response");
    let (consumed_resp, payload_resp) = read_frame(&frame_resp).unwrap().unwrap();
    assert_eq!(consumed_resp, frame_resp.len());
    let decoded_resp = CoreWorkerProtocol::decode_task_response(&payload_resp).expect("decode task response");
    assert_eq!(decoded_resp.task_id, "T-001");
    assert_eq!(decoded_resp.status, "success");
    assert_eq!(decoded_resp.progress, Some(1.0));
}
