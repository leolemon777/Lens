# Lens Windows 平台层

Windows 版 Lens 的实现目录。与 macOS 版**同仓库、同分支**，一个 commit 可以同时改两边。

## 与 macOS 版的关系

两边**不共享代码，只共享数据契约**：

```
Sources/          Swift  — macOS 平台层（AppKit/SwiftUI/ScreenCaptureKit/AVFoundation）
windows/          Rust   — Windows 平台层（本目录）
shared/golden/    JSON   — 两边都必须通过的黄金文件（唯一契约）
```

这个选择是刻意的。经验数据：macOS 版最近 13 次改动里只有 **11%** 落在可共享的纯逻辑，89% 是平台相关的界面与捕获代码。强行共享代码会为了那 11% 付出很大的耦合代价，而两边的 UI 本来就应该长得不一样。

因此约定：

- **可以不同**：界面外观、交互手感、权限模型、快捷键、渲染后端。
- **必须相同**：`.lens` 项目包的读写结果、运镜/字幕/标注等规划算法的输出、schema 版本拒绝行为。

## 契约文档

| 文档 | 作用 |
|---|---|
| [Lens 可移植文档字段规范](../docs/Lens-可移植文档字段规范-v1.md) | **必读。** 字段语义、钳制范围、解码默认值陷阱 |
| [Lens 开放项目格式](../docs/Lens-开放项目格式-v0.1.md) | 目录结构与兼容规则 |
| `../shared/golden/` | 黄金文件；`*.compact.json` 用于逐字节比对 |
| `../shared/golden/schema-registry.json` | 版本注册表的机器可读镜像 |

规范第 5 节列出的**解码默认值陷阱**是移植中最容易出错的地方——若干字段「JSON 缺失时的值」与「构造默认值」不同，用 `#[serde(default)]` 会全部踩错。逐字段显式指定。

## 目录规划

```
windows/
├── Cargo.toml                  workspace
└── crates/
    ├── lens-format/            .lens 读写（纯逻辑，可在 macOS 上开发和测试）
    ├── lens-capture/           Windows.Graphics.Capture + WASAPI（需 Windows）
    ├── lens-render/            Skia 图像 + FFmpeg 视频（edit-plan 执行器）
    └── lens-app/               Tauri 外壳 + 原生截图浮层
```

`lens-format` **不依赖任何 Windows API**，可以在 macOS 上完整开发和验证。这是第一个里程碑的落点。

## 技术选型

| 层 | 选择 | 替代的 macOS 能力 |
|---|---|---|
| 屏幕捕获 | `windows-rs` → Windows.Graphics.Capture | ScreenCaptureKit |
| 系统音频 | WASAPI loopback | ScreenCaptureKit 音频 |
| 图像渲染 | `skia-safe` | Core Image |
| 视频编码合成 | `ffmpeg-next` | AVFoundation |
| OCR | RapidOCR / PaddleOCR | Apple Vision |
| 语音转写 | `whisper-rs` | Apple Speech |
| 外壳 UI | Tauri | SwiftUI |
| 截图浮层 | 原生 `windows-rs` 直绘 | AppKit overlay window |

截图浮层不走 Tauri：`一按即捕捉` 对延迟敏感，webview 启动开销不可接受。

## 里程碑

| # | 内容 | 能在 macOS 上验证？ |
|---|---|---|
| **0** | `lens-format` 读写 + 通过 `shared/golden/` 一致性测试 | ✅ 完全可以 |
| 1 | 截图 + 标注 + 贴图 + OCR + 长截图 | ❌ 需 Windows |
| 2 | 录屏捕获与落盘 | ❌ 需 Windows |
| 3 | edit-plan → FFmpeg 成片 | 部分 |
| 4 | 视频编辑器 UI | ❌ 需 Windows |

里程碑 0 刻意选在「纯数据、无平台 API」的位置，这样在拿到 Windows 环境之前就能验证契约是否完整、协作方式是否顺畅。

## 构建

需要 Rust 工具链（尚未在开发机安装）：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

安装后：

```bash
cd windows && cargo test
```

## 状态

当前仅有目录规划与契约文档，尚无可编译代码。`lens-format` 的实现等待 Rust 工具链就位后开始——在能实际编译和跑测试之前不写投机代码。
