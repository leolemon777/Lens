use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LensSchemaDescriptor {
    pub identifier: String,
    pub relative_path: String,
    pub minimum_readable_version: String,
    pub current_version: String,
}

impl LensSchemaDescriptor {
    pub fn readable_range(&self) -> String {
        format!(
            "{}...{}",
            self.minimum_readable_version, self.current_version
        )
    }

    pub fn validate(&self, version: &str) -> Result<(), SchemaError> {
        let candidate = parse_version(version).ok_or_else(|| SchemaError::Malformed {
            document: self.identifier.clone(),
            found: version.to_string(),
        })?;
        let min = parse_version(&self.minimum_readable_version).expect("valid built-in version");
        let current = parse_version(&self.current_version).expect("valid built-in version");
        if candidate >= min && candidate <= current {
            Ok(())
        } else {
            Err(SchemaError::Unsupported {
                document: self.identifier.clone(),
                found: version.to_string(),
                supported: self.readable_range(),
            })
        }
    }
}

fn parse_version(value: &str) -> Option<(u32, u32)> {
    let parts: Vec<&str> = value.split('.').collect();
    if parts.len() != 2 {
        return None;
    }
    let major = parts[0].parse().ok()?;
    let minor = parts[1].parse().ok()?;
    Some((major, minor))
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SchemaError {
    #[error("{document} 的 schemaVersion 无效：{found}")]
    Malformed { document: String, found: String },
    #[error("{document} 的 schemaVersion {found} 不受支持；当前可读取 {supported}")]
    Unsupported {
        document: String,
        found: String,
        supported: String,
    },
}

pub fn manifest() -> LensSchemaDescriptor {
    LensSchemaDescriptor {
        identifier: "manifest.json".into(),
        relative_path: "manifest.json".into(),
        minimum_readable_version: "0.1".into(),
        current_version: "0.9".into(),
    }
}

pub fn screenshot_edit() -> LensSchemaDescriptor {
    LensSchemaDescriptor {
        identifier: "screenshot-edit".into(),
        relative_path: "edits/screenshot-edit.json".into(),
        minimum_readable_version: "0.2".into(),
        current_version: "0.3".into(),
    }
}
