//! Lens core: portable data rules shared between macOS and Windows.

pub mod edit;
pub mod interop;
pub mod manifest;
pub mod project;
pub mod protocol;
pub mod quality;
pub mod schema;
pub mod screenshot_edit;
pub mod worker_client;

pub use protocol::{
    CoreWorkerProtocol, HandshakeRequest, HandshakeResponse, ProtocolError, TaskRequest,
    TaskResponse, WorkerError,
};
pub use schema::LensSchemaDescriptor;
pub use screenshot_edit::{
    layout_canvas, LensColor, ScreenshotAnnotation, ScreenshotAnnotationKind,
    ScreenshotAnnotationStyle, ScreenshotCanvasAspectRatio, ScreenshotCanvasBackgroundKind,
    ScreenshotCanvasStyle, ScreenshotEditPlan,
};
pub use worker_client::WorkerClient;
