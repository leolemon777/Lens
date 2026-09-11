use serde::{Deserialize, Serialize};

pub const MAXIMUM_FRAME_BYTES: usize = 1_048_576;
pub const CURRENT_VERSION: i32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandshakeRequest {
    #[serde(rename = "clientName")]
    pub client_name: String,
    #[serde(rename = "protocolVersion")]
    pub protocol_version: i32,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "requestedCapabilities", default)]
    pub requested_capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandshakeResponse {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: i32,
    #[serde(rename = "requestID", default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(rename = "supportedCapabilities")]
    pub supported_capabilities: Vec<String>,
    #[serde(rename = "workerVersion")]
    pub worker_version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerError {
    pub code: String,
    #[serde(rename = "protocolVersion")]
    pub protocol_version: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskRequest {
    #[serde(rename = "taskId")]
    pub task_id: String,
    pub action: String,
    #[serde(default)]
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskResponse {
    #[serde(rename = "taskId")]
    pub task_id: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "errorMessage")]
    pub error_message: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("frame too large: {0} bytes (limit {1})")]
    FrameTooLarge(usize, usize),
    #[error("invalid UTF-8 payload")]
    InvalidUtf8,
    #[error("JSON decode failed: {0}")]
    JsonDecode(String),
}

/// Reads a length-prefixed frame from a buffer.
/// Returns (bytes_consumed, payload) or None if incomplete.
pub fn read_frame(buffer: &[u8]) -> Result<Option<(usize, Vec<u8>)>, ProtocolError> {
    if buffer.len() < 4 {
        return Ok(None);
    }
    let length = u32::from_be_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
    if length > MAXIMUM_FRAME_BYTES {
        return Err(ProtocolError::FrameTooLarge(length, MAXIMUM_FRAME_BYTES));
    }
    if buffer.len() < 4 + length {
        return Ok(None);
    }
    Ok(Some((4 + length, buffer[4..4 + length].to_vec())))
}

/// Writes a length-prefixed frame.
pub fn write_frame(payload: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    if payload.len() > MAXIMUM_FRAME_BYTES {
        return Err(ProtocolError::FrameTooLarge(
            payload.len(),
            MAXIMUM_FRAME_BYTES,
        ));
    }
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

pub struct CoreWorkerProtocol;

impl CoreWorkerProtocol {
    pub fn decode_handshake(payload: &[u8]) -> Result<HandshakeRequest, ProtocolError> {
        let text = std::str::from_utf8(payload).map_err(|_| ProtocolError::InvalidUtf8)?;
        serde_json::from_str(text).map_err(|e| ProtocolError::JsonDecode(e.to_string()))
    }

    pub fn decode_handshake_response(payload: &[u8]) -> Result<HandshakeResponse, ProtocolError> {
        let text = std::str::from_utf8(payload).map_err(|_| ProtocolError::InvalidUtf8)?;
        serde_json::from_str(text).map_err(|e| ProtocolError::JsonDecode(e.to_string()))
    }

    pub fn decode_worker_error(payload: &[u8]) -> Result<WorkerError, ProtocolError> {
        let text = std::str::from_utf8(payload).map_err(|_| ProtocolError::InvalidUtf8)?;
        serde_json::from_str(text).map_err(|e| ProtocolError::JsonDecode(e.to_string()))
    }

    pub fn encode_handshake_response(
        response: &HandshakeResponse,
    ) -> Result<Vec<u8>, ProtocolError> {
        let text = serde_json::to_string(response)
            .map_err(|e| ProtocolError::JsonDecode(e.to_string()))?;
        write_frame(text.as_bytes())
    }

    pub fn encode_handshake_request(request: &HandshakeRequest) -> Result<Vec<u8>, ProtocolError> {
        let text =
            serde_json::to_string(request).map_err(|e| ProtocolError::JsonDecode(e.to_string()))?;
        write_frame(text.as_bytes())
    }

    pub fn decode_task_request(payload: &[u8]) -> Result<TaskRequest, ProtocolError> {
        let text = std::str::from_utf8(payload).map_err(|_| ProtocolError::InvalidUtf8)?;
        serde_json::from_str(text).map_err(|e| ProtocolError::JsonDecode(e.to_string()))
    }

    pub fn encode_task_request(request: &TaskRequest) -> Result<Vec<u8>, ProtocolError> {
        let text =
            serde_json::to_string(request).map_err(|e| ProtocolError::JsonDecode(e.to_string()))?;
        write_frame(text.as_bytes())
    }

    pub fn decode_task_response(payload: &[u8]) -> Result<TaskResponse, ProtocolError> {
        let text = std::str::from_utf8(payload).map_err(|_| ProtocolError::InvalidUtf8)?;
        serde_json::from_str(text).map_err(|e| ProtocolError::JsonDecode(e.to_string()))
    }

    pub fn encode_task_response(response: &TaskResponse) -> Result<Vec<u8>, ProtocolError> {
        let text =
            serde_json::to_string(response).map_err(|e| ProtocolError::JsonDecode(e.to_string()))?;
        write_frame(text.as_bytes())
    }
}
