//! Project path policy: validates relative paths inside a `.lens` package
//! against Windows-specific escapes (junctions, ADS, reserved names).

use std::path::{Component, Path, PathBuf};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PathPolicyError {
    #[error("empty path")]
    Empty,
    #[error("absolute path not allowed: {0}")]
    Absolute(String),
    #[error("parent traversal not allowed")]
    ParentTraversal,
    #[error("windows reserved name: {0}")]
    ReservedName(String),
    #[error("alternate data stream separator not allowed")]
    AlternateDataStream,
    #[error("path escapes package root")]
    Escape,
}

const RESERVED_NAMES: &[&str] = &[
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// Validates a package-relative path. On success returns the normalized path
/// using forward slashes (the on-disk format).
pub fn validate_relative_path(input: &str) -> Result<String, PathPolicyError> {
    if input.is_empty() {
        return Err(PathPolicyError::Empty);
    }

    // Reject Windows alternate data streams early.
    // A colon is only valid as a drive prefix (e.g., "C:"), which is itself
    // an absolute path and rejected below.
    if input.contains(':') {
        return Err(PathPolicyError::AlternateDataStream);
    }

    let path = Path::new(input);
    if path.is_absolute() || input.starts_with('/') || input.starts_with('\\') {
        return Err(PathPolicyError::Absolute(input.to_string()));
    }
    if input.starts_with(r"\\") {
        return Err(PathPolicyError::Absolute(input.to_string()));
    }

    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => {
                let name = part.to_string_lossy();
                let upper = name.to_uppercase();
                let stem = upper.split('.').next().unwrap_or("");
                if RESERVED_NAMES.contains(&stem) {
                    return Err(PathPolicyError::ReservedName(name.to_string()));
                }
                normalized.push(part);
            }
            Component::CurDir => { /* skip */ }
            Component::ParentDir => return Err(PathPolicyError::ParentTraversal),
            _ => return Err(PathPolicyError::Escape),
        }
    }

    if normalized.as_os_str().is_empty() {
        return Err(PathPolicyError::Empty);
    }

    Ok(normalized.to_string_lossy().replace('\\', "/"))
}

/// Resolves a validated relative path against a package root, then confirms
/// the canonicalized result is still inside the root (junction/symlink check).
pub fn resolve_within_root(root: &Path, relative: &str) -> Result<PathBuf, PathPolicyError> {
    let validated = validate_relative_path(relative)?;
    let candidate = root.join(&validated);

    // On Windows, canonicalize resolves junctions and symlinks.
    let canonical_root = root.canonicalize().map_err(|_| PathPolicyError::Escape)?;
    let canonical_candidate = candidate
        .canonicalize()
        .map_err(|_| PathPolicyError::Escape)?;

    if canonical_candidate.starts_with(&canonical_root) {
        Ok(canonical_candidate)
    } else {
        Err(PathPolicyError::Escape)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_relative_paths() {
        assert_eq!(
            validate_relative_path("raw/screen.mp4").unwrap(),
            "raw/screen.mp4"
        );
        assert_eq!(
            validate_relative_path("edits/edit-plan.json").unwrap(),
            "edits/edit-plan.json"
        );
    }

    #[test]
    fn rejects_traversal() {
        assert!(validate_relative_path("../outside.txt").is_err());
        assert!(validate_relative_path("raw/../../outside.txt").is_err());
    }

    #[test]
    fn rejects_absolute() {
        assert!(validate_relative_path("C:/Windows/system32").is_err());
        assert!(validate_relative_path("/etc/passwd").is_err());
        assert!(validate_relative_path(r"\\server\share\file").is_err());
    }

    #[test]
    fn rejects_ads() {
        assert!(validate_relative_path("file.txt:stream").is_err());
    }

    #[test]
    fn rejects_reserved_names() {
        assert!(validate_relative_path("CON").is_err());
        assert!(validate_relative_path("CON.txt").is_err());
        assert!(validate_relative_path("raw/NUL").is_err());
        assert!(validate_relative_path("COM1.dat").is_err());
    }

    #[test]
    fn normalizes_backslashes() {
        assert_eq!(
            validate_relative_path(r"raw\screen.mp4").unwrap(),
            "raw/screen.mp4"
        );
    }
}
