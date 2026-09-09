# Windows implementation handoff

This repository is an independent Windows Rust implementation of Lens. It is NOT a tested binary release.

1. Do not edit the original leolemon777/Lens macOS main branch, Swift sources or Mac CI.
2. Read README.md and docs/VALIDATION.md. Do not convert "not run" into "passed" without execution evidence.
3. Use a Windows x64 MSVC environment. Run scripts/build-windows.ps1. Fix compilation errors, then repeat the core tests and build. Preserve Cargo.lock once resolved. Run cargo fmt and clippy after a Rust toolchain is available.
4. Run the manual Windows acceptance checklist. A GitHub Actions build does not validate interactive WGC capture, WASAPI devices, global shortcuts, DPI, or long recordings.
5. The existing source uses windows-capture 2.0.1, wasapi 0.24.0 and windows 0.62.2. Check the EXACT versions' APIs. Do not "fix" compile errors by deleting native capture and replacing it with simulated frontend state or getDisplayMedia.
6. Keep .lens manifest 0.9 and segment index 0.1 aligned. Never rewrite an unknown future schema. Raw video/audio must survive export failures.
7. No shell command injection, general-purpose frontend shell access, arbitrary path opening, cloud upload, keyboard text logging, or unverified executable downloads.
8. Known engineering follow-ups: third-party encoder queue/backpressure audit; native encoder row direction/format validation; bounded stop behavior on hung drivers; audio-clock drift measurement; real Mac project roundtrip; robust orphan segment inspection; additional telemetry excluding captured content.
9. Changes to scope should be explicit. Automatic camera motion, camera tracks, OCR, ASR, subtitles and full timeline editing are not implemented here.
10. Deliver a real compiled EXE/portable ZIP with build evidence and test report only after the build completes. Never rename a source archive as an installer or claim that mocked browser tests prove native recording.
