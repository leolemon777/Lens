use lens_core::schema::*;

#[test]
fn manifest_schema_accepts_current() {
    let m = manifest();
    assert!(m.validate("0.9").is_ok());
    assert!(m.validate("0.1").is_ok());
}

#[test]
fn manifest_schema_rejects_future() {
    let m = manifest();
    assert!(m.validate("1.0").is_err());
}

#[test]
fn manifest_schema_rejects_malformed() {
    let m = manifest();
    assert!(m.validate("abc").is_err());
    assert!(m.validate("1.2.3").is_err());
    assert!(m.validate("").is_err());
}

#[test]
fn screenshot_edit_schema_accepts_supported_and_rejects_future() {
    let descriptor = screenshot_edit();
    assert!(descriptor.validate("0.2").is_ok());
    assert!(descriptor.validate("0.3").is_ok());
    assert!(descriptor.validate("0.4").is_err());
}
