# Windows 构建指南

## 当前状态

这是一份未经过 Windows 编译的源码工程。`Build.cmd` 是执行编译的入口，不是已经生成的 EXE。需要根据 Windows 首次编译日志修正可能出现的类型/API/依赖问题，不能预先保证一次构建成功。

## 环境准备

使用 Windows 11 x64。安装：

- Rust stable，默认 host 选择 `x86_64-pc-windows-msvc`。官方安装入口：https://rustup.rs/
- Visual Studio 2022 Build Tools 或包含 C++ 工具的 Visual Studio：选择“使用 C++ 的桌面开发”，包含 MSVC x64/x86 编译工具与 Windows 10/11 SDK。官方入口：https://visualstudio.microsoft.com/visual-cpp-build-tools/
- Microsoft Edge WebView2 Evergreen Runtime。官方入口：https://developer.microsoft.com/microsoft-edge/webview2/

Tauri Windows 环境说明：https://v2.tauri.app/start/prerequisites/

安装之后重新打开终端，再运行 `rustc --version` 与 `cargo --version`。建议把源码放到普通用户可写的目录，例如 `D:\Dev\Lens-Windows-Rust`，不要放在受保护的 Program Files 或正在云盘同步的工作目录中。不要关闭系统安全功能来解决编译问题。

## 构建步骤

打开 PowerShell，进入项目根目录：

```powershell
# 需要声音与分段合并时先准备后处理组件。
.\Prepare-Media.cmd

# 执行核心测试、编译、便携包生成。
.\Build.cmd
```

也可以逐步执行：

```powershell
rustup target add x86_64-pc-windows-msvc
cargo generate-lockfile
cargo test --locked -p lens-core --target x86_64-pc-windows-msvc
cargo build --locked --release -p lens-windows --target x86_64-pc-windows-msvc
```

手动 cargo build 的二进制位于 `target\x86_64-pc-windows-msvc\release\lens-windows.exe`；`Build.cmd` 额外将它与组件、许可证、锁文件、构建证据打包到 `dist\Lens-Windows`。本工程前端不需要 Node 构建步骤。

成功后打开 `dist\Lens-Windows\Lens.exe`。`.exe` 没有购买代码签名证书，也没有进行签名发行；请只使用自己构建并验收的结果。

## 常见失败定位

| 现象 | 检查 |
|---|---|
| `cargo` 找不到 | Rust 是否安装；终端是否在安装后重开 |
| `link.exe` / SDK 找不到 | C++ Build Tools、Windows SDK 和 MSVC target 是否安装 |
| 第三方 Rust API 类型错误 | 保留完整 build.log；不要把该版本标记为可用，应修正后重新测试 |
| 程序启动失败 / WebView2 缺失 | 安装官方 Evergreen Runtime，检查系统版本 |
| 界面提示没有 FFmpeg | Prepare-Media.cmd 是否成功；是否重新 Build；tools 文件夹是否与 EXE 一起复制 |
| 音频设备初始化失败 | 检查 Windows 麦克风隐私权限、默认输入/输出设备，先尝试单一音轨 |
| 没有收到窗口画面 | 检查窗口是否最小化、关闭、受保护或权限受限 |
| 合成失败 | 保留整个 `.lens`；查看其中的 `diagnostics/export.log` |

下载媒体组件脚本用同一上游发布页提供的 digest/checksum 验证传输完整性，不是可独立证明上游供应链安全的代码审计。首次分发前还要审查当前 FFmpeg 构建的依赖与许可证。

## GitHub Actions

本工程包含独立 `.github/workflows/windows.yml`。放入独立的 Windows 仓库后，它可以在 push/PR 或手动触发时编译，上传便携 ZIP 与 build.log。它需要普通 Actions 执行环境与网络；桌面录制的真机测试不由无交互 CI 自动完成。

当前 GitHub 连接的写入操作返回 403。因此本次没有远程 Windows 构建日志、产物或可声称成功的工作流。
