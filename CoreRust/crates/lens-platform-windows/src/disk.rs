//! Library-root free space for recording warnings and safe-stop.

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows::core::{Result, PCWSTR};
use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

pub const WARN_BYTES: u64 = 5 * 1024 * 1024 * 1024;
pub const STOP_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskStatus {
    Ok,
    Warn,
    Stop,
}

impl DiskStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Warn => "warn",
            Self::Stop => "stop",
        }
    }
}

pub fn free_bytes(path: &Path) -> Result<u64> {
    let probe = if path.exists() {
        path.to_path_buf()
    } else {
        path.ancestors()
            .find(|ancestor| ancestor.exists())
            .map(|ancestor| ancestor.to_path_buf())
            .unwrap_or_else(|| Path::new("E:\\").to_path_buf())
    };
    let wide: Vec<u16> = OsStr::new(&probe)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let mut free = 0_u64;
    unsafe {
        GetDiskFreeSpaceExW(PCWSTR(wide.as_ptr()), Some(&mut free), None, None)?;
    }
    Ok(free)
}

pub fn status(free: u64) -> DiskStatus {
    if free < STOP_BYTES {
        DiskStatus::Stop
    } else if free < WARN_BYTES {
        DiskStatus::Warn
    } else {
        DiskStatus::Ok
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_thresholds_match_spec() {
        assert_eq!(status(STOP_BYTES - 1), DiskStatus::Stop);
        assert_eq!(status(WARN_BYTES - 1), DiskStatus::Warn);
        assert_eq!(status(WARN_BYTES), DiskStatus::Ok);
    }

    #[test]
    fn free_bytes_of_existing_temp_is_nonzero() {
        let free = free_bytes(&std::env::temp_dir()).expect("temp volume");
        assert!(free > 0);
    }
}
