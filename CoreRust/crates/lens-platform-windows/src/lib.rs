//! Windows platform capabilities for Lens.
//!
//! This crate owns OS resource discovery and device lifecycle for the Windows
//! port. It must not depend on Tauri, React, or project schema types; those
//! boundaries are defined in the Windows CODE PLAN.

#![cfg(windows)]

pub mod audio;
pub mod camera;
pub mod capture;
pub mod disk;
pub mod clipboard;
pub mod display;
pub mod dpi;
pub mod encode;
pub mod events;
pub mod graphics;
pub mod ocr;
pub mod overlay;
pub mod screenshot;
pub mod scrolling;
pub mod session;
pub mod transcript;
pub mod windows;
