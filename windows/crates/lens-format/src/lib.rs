//! Platform-neutral part of the Windows port.
//!
//! The capture and rendering crates will depend on this crate, but this crate
//! deliberately has no Windows API dependency. Its job is to enforce the
//! portable `.lens` contract before a platform worker touches media.

use serde::Deserialize;
use serde_json::Value;
use std::fmt;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FormatError {
    UnsupportedRegistryVersion { found: u32, supported: u32 },
    MissingSchemaVersion { path: PathBuf },
    MalformedSchemaVersion { path: PathBuf, value: String },
    UnsupportedSchemaVersion {
        path: PathBuf,
        found: String,
        supported: String,
    },
    InvalidSchemaRange {
        path: PathBuf,
        minimum: String,
        current: String,
    },
    PathEscapesRoot { path: PathBuf },
    SymlinkNotAllowed { path: PathBuf },
    Io(String),
    Json(String),
}

impl fmt::Display for FormatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedRegistryVersion { found, supported } => write!(
                f,
                "schema registry version {found} is unsupported; supported {supported}"
            ),
            Self::MissingSchemaVersion { path } => {
                write!(f, "{} is missing schemaVersion", path.display())
            }
            Self::MalformedSchemaVersion { path, value } => {
                write!(f, "{} has malformed schemaVersion {value}", path.display())
            }
            Self::UnsupportedSchemaVersion {
                path,
                found,
                supported,
            } => write!(
                f,
                "{} has unsupported schemaVersion {found}; supported {supported}",
                path.display()
            ),
            Self::InvalidSchemaRange {
                path,
                minimum,
                current,
            } => write!(
                f,
                "{} has invalid schema range {minimum}...{current}",
                path.display()
            ),
            Self::PathEscapesRoot { path } => {
                write!(f, "{} escapes the .lens root", path.display())
            }
            Self::SymlinkNotAllowed { path } => {
                write!(f, "symlink is not allowed in portable document {}", path.display())
            }
            Self::Io(message) => f.write_str(message),
            Self::Json(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for FormatError {}

impl From<std::io::Error> for FormatError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

impl From<serde_json::Error> for FormatError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error.to_string())
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SchemaRegistry {
    pub schema_registry_version: u32,
    pub documents: Vec<SchemaDocument>,
}

const CURRENT_SCHEMA_REGISTRY_VERSION: u32 = 1;

impl SchemaRegistry {
    fn validate(&self) -> Result<(), FormatError> {
        for document in &self.documents {
            let relative = validate_relative_path(&document.relative_path)?;
            let minimum = parse_version(&document.minimum_readable_version).ok_or_else(|| {
                FormatError::MalformedSchemaVersion {
                    path: relative.to_path_buf(),
                    value: document.minimum_readable_version.clone(),
                }
            })?;
            let current = parse_version(&document.current_version).ok_or_else(|| {
                FormatError::MalformedSchemaVersion {
                    path: relative.to_path_buf(),
                    value: document.current_version.clone(),
                }
            })?;
            if minimum > current {
                return Err(FormatError::InvalidSchemaRange {
                    path: relative.to_path_buf(),
                    minimum: document.minimum_readable_version.clone(),
                    current: document.current_version.clone(),
                });
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SchemaDocument {
    pub identifier: String,
    pub relative_path: String,
    pub minimum_readable_version: String,
    pub current_version: String,
}

impl SchemaDocument {
    pub fn readable_range(&self) -> String {
        format!(
            "{}...{}",
            self.minimum_readable_version, self.current_version
        )
    }

    pub fn accepts(&self, version: &str) -> Result<(), FormatError> {
        let found = parse_version(version).ok_or_else(|| FormatError::MalformedSchemaVersion {
            path: PathBuf::from(&self.relative_path),
            value: version.to_owned(),
        })?;
        let minimum = parse_version(&self.minimum_readable_version).ok_or_else(|| {
            FormatError::MalformedSchemaVersion {
                path: PathBuf::from(&self.relative_path),
                value: self.minimum_readable_version.clone(),
            }
        })?;
        let current = parse_version(&self.current_version).ok_or_else(|| {
            FormatError::MalformedSchemaVersion {
                path: PathBuf::from(&self.relative_path),
                value: self.current_version.clone(),
            }
        })?;
        if found < minimum || found > current {
            return Err(FormatError::UnsupportedSchemaVersion {
                path: PathBuf::from(&self.relative_path),
                found: version.to_owned(),
                supported: self.readable_range(),
            });
        }
        Ok(())
    }
}

pub fn load_registry(path: impl AsRef<Path>) -> Result<SchemaRegistry, FormatError> {
    let registry: SchemaRegistry = serde_json::from_slice(&fs::read(path)?)?;
    if registry.schema_registry_version != CURRENT_SCHEMA_REGISTRY_VERSION {
        return Err(FormatError::UnsupportedRegistryVersion {
            found: registry.schema_registry_version,
            supported: CURRENT_SCHEMA_REGISTRY_VERSION,
        });
    }
    registry.validate()?;
    Ok(registry)
}

/// Reads and validates one portable JSON document without following a path
/// outside the package or through a symlink. The caller can then deserialize
/// the returned value into its platform-specific model.
pub fn read_document(
    package_root: impl AsRef<Path>,
    document: &SchemaDocument,
) -> Result<Value, FormatError> {
    let root = package_root.as_ref().canonicalize()?;
    let relative = validate_relative_path(&document.relative_path)?;
    let candidate = root.join(relative);
    reject_symlink_components(&root, &candidate)?;
    let metadata = fs::symlink_metadata(&candidate)?;
    if metadata.file_type().is_symlink() {
        return Err(FormatError::SymlinkNotAllowed { path: candidate });
    }
    let resolved_parent = candidate
        .parent()
        .ok_or_else(|| FormatError::PathEscapesRoot {
            path: candidate.clone(),
        })?
        .canonicalize()?;
    if !resolved_parent.starts_with(&root) {
        return Err(FormatError::PathEscapesRoot { path: candidate });
    }
    let value: Value = serde_json::from_slice(&fs::read(&candidate)?)?;
    let version_value = value
        .get("schemaVersion")
        .ok_or_else(|| FormatError::MissingSchemaVersion {
            path: candidate.clone(),
        })?;
    let version = version_value
        .as_str()
        .ok_or_else(|| FormatError::MalformedSchemaVersion {
            path: candidate.clone(),
            value: version_value.to_string(),
        })?;
    document.accepts(version).map_err(|error| match error {
        FormatError::MalformedSchemaVersion { value, .. } => {
            FormatError::MalformedSchemaVersion {
                path: candidate.clone(),
                value,
            }
        }
        FormatError::UnsupportedSchemaVersion {
            found, supported, ..
        } => FormatError::UnsupportedSchemaVersion {
            path: candidate,
            found,
            supported,
        },
        other => other,
    })?;
    Ok(value)
}

/// Validates and writes one portable JSON document using the compact,
/// UTF-8-preserving encoding used by the shared golden files. The temporary
/// file is placed beside the target so the final rename never crosses a file
/// system boundary.
pub fn write_document(
    package_root: impl AsRef<Path>,
    document: &SchemaDocument,
    value: &Value,
) -> Result<(), FormatError> {
    let root = package_root.as_ref().canonicalize()?;
    let relative = validate_relative_path(&document.relative_path)?;
    let candidate = root.join(relative);
    reject_symlink_components(&root, &candidate)?;
    let parent = candidate
        .parent()
        .ok_or_else(|| FormatError::PathEscapesRoot {
            path: candidate.clone(),
        })?
        .canonicalize()?;
    if !parent.starts_with(&root) {
        return Err(FormatError::PathEscapesRoot { path: candidate });
    }
    if let Ok(metadata) = fs::symlink_metadata(&candidate) {
        if metadata.file_type().is_symlink() {
            return Err(FormatError::SymlinkNotAllowed { path: candidate });
        }
    }

    let version_value = value
        .get("schemaVersion")
        .ok_or_else(|| FormatError::MissingSchemaVersion {
            path: candidate.clone(),
        })?;
    let version = version_value
        .as_str()
        .ok_or_else(|| FormatError::MalformedSchemaVersion {
            path: candidate.clone(),
            value: version_value.to_string(),
        })?;
    document.accepts(version).map_err(|error| match error {
        FormatError::MalformedSchemaVersion { value, .. } => {
            FormatError::MalformedSchemaVersion {
                path: candidate.clone(),
                value,
            }
        }
        FormatError::UnsupportedSchemaVersion {
            found, supported, ..
        } => FormatError::UnsupportedSchemaVersion {
            path: candidate.clone(),
            found,
            supported,
        },
        other => other,
    })?;

    let mut encoded = serde_json::to_vec(value)?;
    encoded.push(b'\n');
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let temporary = parent.join(format!(
        ".{}.lens-write-{}-{}",
        candidate.file_name().and_then(|name| name.to_str()).unwrap_or("document"),
        std::process::id(),
        nonce
    ));
    fs::write(&temporary, encoded)?;
    if let Err(error) = commit_temporary_file(&temporary, &candidate) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(())
}

fn commit_temporary_file(temporary: &Path, candidate: &Path) -> Result<(), FormatError> {
    #[cfg(not(windows))]
    {
        fs::rename(temporary, candidate)?;
        return Ok(());
    }

    #[cfg(windows)]
    {
        let parent = candidate
            .parent()
            .ok_or_else(|| FormatError::PathEscapesRoot {
                path: candidate.to_path_buf(),
            })?;
        let existing = match fs::symlink_metadata(candidate) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err(FormatError::SymlinkNotAllowed {
                        path: candidate.to_path_buf(),
                    });
                }
                if !metadata.is_file() {
                    return Err(FormatError::Io(format!(
                        "{} is not a regular file",
                        candidate.display()
                    )));
                }
                true
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => return Err(error.into()),
        };
        if !existing {
            fs::rename(temporary, candidate)?;
            return Ok(());
        }

        let temporary_name = temporary
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("document");
        let backup = parent.join(format!(".{temporary_name}.backup"));
        fs::rename(candidate, &backup)?;
        match fs::rename(temporary, candidate) {
            Ok(()) => {
                let _ = fs::remove_file(backup);
                Ok(())
            }
            Err(error) => {
                let _ = fs::rename(&backup, candidate);
                let _ = fs::remove_file(temporary);
                Err(error.into())
            }
        }
    }
}

fn validate_relative_path(value: &str) -> Result<&Path, FormatError> {
    let relative = Path::new(value);
    if value.is_empty()
        || relative.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(FormatError::PathEscapesRoot {
            path: relative.to_path_buf(),
        });
    }
    Ok(relative)
}

/// Reject symlinks in every path component below the canonical package root.
/// Checking only the final document would still allow `alias/manifest.json`
/// to traverse a symlinked parent directory.
fn reject_symlink_components(root: &Path, candidate: &Path) -> Result<(), FormatError> {
    let relative = candidate
        .strip_prefix(root)
        .map_err(|_| FormatError::PathEscapesRoot {
            path: candidate.to_path_buf(),
        })?;
    let mut current = root.to_path_buf();
    let components: Vec<_> = relative.components().collect();
    for (index, component) in components.iter().enumerate() {
        match component {
            Component::CurDir => continue,
            Component::Normal(part) => current.push(part),
            _ => {
                return Err(FormatError::PathEscapesRoot {
                    path: candidate.to_path_buf(),
                });
            }
        }
        let metadata = match fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error)
                if error.kind() == std::io::ErrorKind::NotFound
                    && index + 1 == components.len() =>
            {
                // A write may legitimately target a new final document. The
                // parent is canonicalized by write_document before the rename.
                break;
            }
            Err(error) => return Err(error.into()),
        };
        if metadata.file_type().is_symlink() {
            return Err(FormatError::SymlinkNotAllowed { path: current });
        }
    }
    Ok(())
}

fn parse_version(value: &str) -> Option<(u32, u32)> {
    let mut parts = value.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    #[cfg(windows)]
    use std::os::windows::fs::symlink_dir;

    fn registry() -> SchemaRegistry {
        load_registry(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../shared/golden/schema-registry.json"),
        )
        .expect("golden schema registry")
    }

    #[test]
    fn registry_accepts_current_manifest_and_rejects_future_versions() {
        let registry = registry();
        let manifest = registry
            .documents
            .iter()
            .find(|document| document.identifier == "manifest.json")
            .expect("manifest descriptor");
        assert!(manifest.accepts("0.9").is_ok());
        assert!(matches!(
            manifest.accepts("0.10"),
            Err(FormatError::UnsupportedSchemaVersion { .. })
        ));
    }

    #[test]
    fn reads_the_golden_manifest_through_the_path_boundary() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../shared/golden");
        let registry = registry();
        let manifest = registry
            .documents
            .iter()
            .find(|document| document.identifier == "manifest.json")
            .expect("manifest descriptor");
        let value = read_document(&root, manifest).expect("golden manifest");
        assert_eq!(value["schemaVersion"], "0.9");
    }

    #[test]
    fn reencodes_all_shared_compact_goldens_byte_for_byte() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../shared/golden");
        let names = [
            "edit-plan",
            "insights",
            "manifest",
            "ocr",
            "screenshot-edit",
            "scrolling-capture",
            "segments",
            "transcript",
        ];

        for name in names {
            let source = root.join(format!("{name}.json"));
            let compact = root.join(format!("{name}.compact.json"));
            let value: Value = serde_json::from_slice(&fs::read(&source).expect("golden source"))
                .expect("golden JSON");
            let mut encoded = serde_json::to_vec(&value).expect("compact JSON");
            encoded.push(b'\n');
            assert_eq!(
                fs::read(&compact).expect("compact golden"),
                encoded,
                "{name} compact golden"
            );
        }
    }

    fn temporary_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "lens-format-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temporary root");
        root
    }

    fn manifest_document() -> SchemaDocument {
        SchemaDocument {
            identifier: "manifest.json".to_owned(),
            relative_path: "manifest.json".to_owned(),
            minimum_readable_version: "0.1".to_owned(),
            current_version: "0.9".to_owned(),
        }
    }

    #[test]
    fn rejects_unknown_registry_and_document_versions() {
        let root = temporary_root("future");
        let registry_path = root.join("schema-registry.json");
        fs::write(
            &registry_path,
            br#"{"schemaRegistryVersion":2,"documents":[]}"#,
        )
        .expect("future registry");
        assert!(matches!(
            load_registry(&registry_path),
            Err(FormatError::UnsupportedRegistryVersion { found: 2, .. })
        ));

        fs::write(root.join("manifest.json"), br#"{"schemaVersion":"0.10"}"#)
            .expect("future document");
        assert!(matches!(
            read_document(&root, &manifest_document()),
            Err(FormatError::UnsupportedSchemaVersion { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_missing_and_non_string_document_schema_versions() {
        let root = temporary_root("malformed");
        let document = manifest_document();
        fs::write(root.join("manifest.json"), br#"{"id":"missing"}"#)
            .expect("missing schema document");
        assert!(matches!(
            read_document(&root, &document),
            Err(FormatError::MissingSchemaVersion { .. })
        ));

        fs::write(root.join("manifest.json"), br#"{"schemaVersion":9}"#)
            .expect("malformed schema document");
        assert!(matches!(
            read_document(&root, &document),
            Err(FormatError::MalformedSchemaVersion { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_relative_paths_that_escape_package_root() {
        let root = temporary_root("escape");
        let mut document = manifest_document();
        document.relative_path = "../outside.json".to_owned();
        assert!(matches!(
            read_document(&root, &document),
            Err(FormatError::PathEscapesRoot { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_empty_document_paths_before_touching_package_root() {
        let root = temporary_root("empty-path");
        let mut document = manifest_document();
        document.relative_path.clear();
        let value = serde_json::json!({"schemaVersion": "0.9"});

        assert!(matches!(
            read_document(&root, &document),
            Err(FormatError::PathEscapesRoot { .. })
        ));
        assert!(matches!(
            write_document(&root, &document, &value),
            Err(FormatError::PathEscapesRoot { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_registry_document_paths_that_escape_package_root() {
        let root = temporary_root("registry-path");
        let registry_path = root.join("schema-registry.json");
        fs::write(
            &registry_path,
            br#"{"schemaRegistryVersion":1,"documents":[{"identifier":"bad","relativePath":"../outside.json","minimumReadableVersion":"0.1","currentVersion":"0.1"}]}"#,
        )
        .expect("registry with escaping path");
        assert!(matches!(
            load_registry(&registry_path),
            Err(FormatError::PathEscapesRoot { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_malformed_and_reversed_registry_version_ranges() {
        let root = temporary_root("registry-version-range");
        let registry_path = root.join("schema-registry.json");
        fs::write(
            &registry_path,
            br#"{"schemaRegistryVersion":1,"documents":[{"identifier":"bad","relativePath":"manifest.json","minimumReadableVersion":"0.x","currentVersion":"0.1"}]}"#,
        )
        .expect("malformed registry version");
        assert!(matches!(
            load_registry(&registry_path),
            Err(FormatError::MalformedSchemaVersion { .. })
        ));

        fs::write(
            &registry_path,
            br#"{"schemaRegistryVersion":1,"documents":[{"identifier":"bad","relativePath":"manifest.json","minimumReadableVersion":"0.2","currentVersion":"0.1"}]}"#,
        )
        .expect("reversed registry version range");
        assert!(matches!(
            load_registry(&registry_path),
            Err(FormatError::InvalidSchemaRange { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_symlinked_parent_inside_package_root() {
        let root = temporary_root("symlink-parent");
        let real = root.join("real");
        fs::create_dir_all(&real).expect("real document directory");
        fs::write(real.join("manifest.json"), br#"{"schemaVersion":"0.1"}"#)
            .expect("manifest through real directory");

        let alias = root.join("alias");
        #[cfg(unix)]
        symlink(&real, &alias).expect("symlink parent");
        #[cfg(windows)]
        symlink_dir(&real, &alias).expect("symlink parent");

        let mut document = manifest_document();
        document.relative_path = "alias/manifest.json".to_owned();
        assert!(matches!(
            read_document(&root, &document),
            Err(FormatError::SymlinkNotAllowed { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn writes_compact_document_and_reads_it_back() {
        let root = temporary_root("write-roundtrip");
        let document = manifest_document();
        let value = serde_json::json!({
            "title": "测试记录",
            "schemaVersion": "0.9",
            "state": "ready"
        });

        write_document(&root, &document, &value).expect("write document");

        let mut expected = serde_json::to_vec(&value).expect("encode document");
        expected.push(b'\n');
        assert_eq!(fs::read(root.join("manifest.json")).expect("written bytes"), expected);
        assert_eq!(
            read_document(&root, &document).expect("read written document"),
            value
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn writes_over_existing_document_with_same_contract() {
        let root = temporary_root("write-replace");
        let document = manifest_document();
        let path = root.join("manifest.json");
        fs::write(&path, br#"{"schemaVersion":"0.1","state":"old"}"#)
            .expect("existing document");
        let value = serde_json::json!({"schemaVersion": "0.9", "state": "new"});

        write_document(&root, &document, &value).expect("replace document");
        assert_eq!(read_document(&root, &document).expect("read replacement"), value);
        let backup_leftover = fs::read_dir(&root)
            .expect("read package root")
            .filter_map(Result::ok)
            .any(|entry| entry.file_name().to_string_lossy().ends_with(".backup"));
        assert!(!backup_leftover);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn rejects_write_with_unsupported_schema_version_before_creating_file() {
        let root = temporary_root("write-future");
        let document = manifest_document();
        let value = serde_json::json!({"schemaVersion": "0.10"});

        assert!(matches!(
            write_document(&root, &document, &value),
            Err(FormatError::UnsupportedSchemaVersion { .. })
        ));
        assert!(!root.join("manifest.json").exists());
        let _ = fs::remove_dir_all(root);
    }
}
