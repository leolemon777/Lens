# Dependencies and distribution notices

The source archive does not contain FFmpeg, WebView2, Rust toolchains, or a compiled application.

Direct dependencies include Tauri / tauri-build / tauri-plugin-single-instance, windows-capture 2.0.1, wasapi 0.24.0, Microsoft windows-rs 0.62.2, serde, serde_json, uuid, chrono, tempfile, parking_lot, dirs and fs2. Each dependency remains governed by its own published licence. The complete transitive dependency inventory must be generated from the actual Cargo.lock before binary redistribution; no complete licence audit is claimed by this file.

Reference repositories / documentation:

- Tauri: https://github.com/tauri-apps/tauri
- Windows Capture: https://github.com/NiiightmareXD/windows-capture
- WASAPI Rust: https://github.com/HEnquist/wasapi-rs
- Microsoft windows-rs: https://github.com/microsoft/windows-rs
- FFmpeg legal information: https://ffmpeg.org/legal.html
- Optional Windows FFmpeg builds: https://github.com/BtbN/FFmpeg-Builds

scripts/prepare-media.ps1 requests the specifically LGPL-labelled Windows x64 release asset. The complete extracted upstream directory and provenance metadata are retained. Archive SHA-256 validation is an integrity check, not a licence audit or independent proof of upstream authenticity. Review the selected release's notices, build configuration, dependency licences and source-availability obligations before redistribution. Selecting an LGPL-labelled archive is not a blanket guarantee about all distribution obligations or codec patents.

The icon in this source package was constructed for this Windows prototype; it is not the original Lens macOS app icon. No font files are distributed.
