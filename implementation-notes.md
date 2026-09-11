# Implementation Notes

## Spec Interpretation
- Windows product is Tauri 2 + React + Rust in `Desktop/` + `CoreRust/`.
- macOS product stays in `Sources/`, `Tests/`, `Package.swift`.
- Same capture → finished media → findable library path. Not an AppKit/Fn/Vision clone.

## Decisions Made
- Deleted the entire `Windows/` WinForms / C# / C++ tree and C# stress runners.
- Default `Scripts/windows/*.ps1` only build, test, run, and package Tauri/Rust.
- CI `windows.yml` no longer installs .NET or compiles CMake/C#.
- Repo layout is documented in README; SPM paths were not moved.

## Changes From Spec
- Historical C# evidence in the old execution log is no longer a product source of truth.
- Authenticode / G-W1 / G-W2 / real CER-WER remain open.

## Tradeoffs
- Did not rename `Sources/` or Mac `Scripts/*.sh` so Swift Package and macOS CI keep working.

## Verification
- `cargo test --workspace --offline` in `CoreRust` passed.
- `npx tsc --noEmit` in `Desktop` passed.
- `Sources/LensMac`, `Tests/`, `Package.swift`, `Assets/AppIcon.png` still present; no `.cs` / `.csproj` left.

## Risks / Follow-up
- G-W1 / G-W2 matrices, Authenticode, camera mux.
