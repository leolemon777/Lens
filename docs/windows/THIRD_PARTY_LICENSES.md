# Lens Windows 第三方许可与发布说明

本文件随 Lens Windows 安装包分发，用于记录主要运行时组件。正式公开发布前仍须由发布负责人结合最终二进制清单完成法律复核。

## Tauri 与 Rust 依赖

Tauri 及多数 Rust 依赖采用 MIT、Apache-2.0 或双许可证。逐包精确版本由 `Desktop/src-tauri/Cargo.lock` 与 `CoreRust/Cargo.lock` 冻结。打包脚本会调用 `Scripts/windows/generate-third-party-notices.ps1`，针对 Windows x64 解析 Cargo 依赖图和 npm 锁文件，生成逐包版本、许可证表达式、上游仓库及本地依赖包携带的许可证/NOTICE 正文；缺少许可证元数据时打包失败。

## FFmpeg 与 ffprobe

当前打包脚本使用构建机上实际解析到的 `ffmpeg.exe` 和 `ffprobe.exe`。本批验证所用 Gyan.dev full build 启用了 GPL v3 组件（包括 libx264/libx265），因此不能按 LGPL-only 分发。发布方必须履行对应 GPL v3 源码提供、许可证文本及修改说明义务，或改用经批准的可再分发构建。

- 项目与许可证：https://ffmpeg.org/legal.html
- 当前二进制供应方：https://www.gyan.dev/ffmpeg/builds/

## Microsoft WebView2 Runtime

Lens 使用系统安装的 Microsoft Edge WebView2 Runtime。安装器当前不内嵌 Evergreen Runtime；隔离环境验收必须确认缺失时的安装/提示策略。

## 发布前仍需人工完成

- 冻结 FFmpeg/ffprobe 的供应来源、版本、构建配置、SHA-256 与对应源代码归档位置。
- Authenticode 签名与公开发布法律复核。
