//! Local OCR using Windows.Media.Ocr. Chinese quality is machine-dependent.

use serde::Serialize;
use windows::Graphics::Imaging::{BitmapDecoder, BitmapPixelFormat, SoftwareBitmap};
use windows::Media::Ocr::OcrEngine;
use windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

use crate::capture::CapturedFrame;
use crate::screenshot;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OcrBlock {
    pub text: String,
    pub confidence: f64,
    pub normalized_bounds: NormRect,
}

#[derive(Debug, Clone, Serialize)]
pub struct NormRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OcrDocument {
    pub schema_version: String,
    pub engine: String,
    pub recognized_at: String,
    pub recognition_languages: Vec<String>,
    pub full_text: String,
    pub blocks: Vec<OcrBlock>,
}

pub fn recognize_frame(frame: &CapturedFrame) -> windows::core::Result<OcrDocument> {
    let png = screenshot::encode_frame_png(frame).map_err(|err| {
        windows::core::Error::new(windows::Win32::Foundation::E_FAIL, err.to_string())
    })?;
    recognize_png(&png)
}

pub fn recognize_png(png: &[u8]) -> windows::core::Result<OcrDocument> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let result = recognize_png_inner(png);
    unsafe {
        CoUninitialize();
    }
    result
}

fn recognize_png_inner(png: &[u8]) -> windows::core::Result<OcrDocument> {
    let stream = InMemoryRandomAccessStream::new()?;
    let writer = DataWriter::CreateDataWriter(&stream)?;
    writer.WriteBytes(png)?;
    writer.StoreAsync()?.join()?;
    writer.FlushAsync()?.join()?;
    stream.Seek(0)?;
    let decoder = BitmapDecoder::CreateAsync(&stream)?.join()?;
    let bitmap: SoftwareBitmap = decoder.GetSoftwareBitmapAsync()?.join()?;
    let converted = SoftwareBitmap::Convert(&bitmap, BitmapPixelFormat::Bgra8)?;
    let engine = OcrEngine::TryCreateFromUserProfileLanguages()?;
    let language = engine
        .RecognizerLanguage()
        .ok()
        .and_then(|lang| lang.LanguageTag().ok())
        .map(|tag| tag.to_string())
        .unwrap_or_else(|| "und".into());
    let ocr = engine.RecognizeAsync(&converted)?.join()?;
    let text = ocr.Text()?.to_string();
    let mut blocks = Vec::new();
    if let Ok(lines) = ocr.Lines() {
        let count = lines.Size().unwrap_or(0);
        for index in 0..count {
            if let Ok(line) = lines.GetAt(index) {
                let line_text = line
                    .Text()
                    .map(|value| value.to_string())
                    .unwrap_or_default();
                if line_text.trim().is_empty() {
                    continue;
                }
                blocks.push(OcrBlock {
                    text: line_text,
                    confidence: 1.0,
                    normalized_bounds: NormRect {
                        x: 0.0,
                        y: index as f64 / count.max(1) as f64,
                        width: 1.0,
                        height: 1.0 / count.max(1) as f64,
                    },
                });
            }
        }
    }
    Ok(OcrDocument {
        schema_version: "0.1".into(),
        engine: "windows.media.ocr".into(),
        recognized_at: lens_now(),
        recognition_languages: vec![language],
        full_text: text,
        blocks,
    })
}

fn lens_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}
