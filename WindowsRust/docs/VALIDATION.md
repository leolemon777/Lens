# 本次验证记录

## 交付判定

**源码工程已生成；没有编译成功的 Windows EXE，没有原生录屏验收结果。**

这里不把“写了代码”“浏览器能显示界面”“模拟接口测试通过”替换成“Windows 版本已经可用”。目标用户拿到的是源码和执行构建的脚本。

## 已实际执行

| 检查 | 结果 | 所证明的范围 |
|---|---|---|
| Node 前端检查 | 23/23 通过 | 时间显示、选区缩放/边界/取整、按钮状态、搜索、静态命令接线 |
| Chromium 交互检查 | 13/13 通过 | 使用模拟 Tauri 接口的界面交互、异常提示、缺失组件限制、区域页面坐标 |
| 浏览器直接打开模式 | 通过 | 明确显示“仅界面预览”，拒绝假装录屏 |
| 前端 ES Module 语法 | 通过 | node --check，不验证 Rust/Windows |
| 本地 JSON/TOML 解析 | 通过 | 配置文件语法，不等于完整 Tauri 构建验证 |
| synthetic manifest JSON Schema | 通过 | 本工程定义的源合同子集，不是 Mac 应用真实往返 |
| UI 图像检查 | 已执行 | docs/UI-PREVIEW.png 为浏览器前端截图，保留了未连接原生引擎的说明 |

原始结果见 `docs/validation-evidence.json`、`docs/node-tests.tap` 和 `docs/ui-smoke-results.json`。

浏览器测试直接把本地 HTML/CSS/JavaScript 输入 Chromium；模拟接口只在 `tests/ui_smoke.py` 中注入，不打包进 `frontend/`。本次测试没有真实录制显示器、没有采集麦克风、没有产生测试视频。

## 已编写、未执行

- Rust 核心及合同测试：25 项，覆盖路径、schema、状态守卫、暂停时间线、QPC、BGRA、WAV与合成合同样本。
- Rust 类型检查、cargo fmt、clippy：未执行。
- Windows x64 MSVC 编译与链接：未执行。
- PowerShell 下载/构建脚本：未执行。
- WGC、H.264 编码、WASAPI、FFmpeg 合成：未执行。
- Windows 全局热键、透明选区窗口、退出保护、混合 DPI：未执行。
- GitHub Actions：未运行。
- Mac / Windows .lens 双向往返、长录制、崩溃与低磁盘：未执行。

## 阻塞证据

当前容器是 Linux，`cargo`、`rustc`、`rustfmt`、Windows PowerShell 均不在可用工具链中，也没有 Windows 录制桌面。尝试访问 Rust 分发端点时容器 DNS 无法解析，未安装 Rust。没有把 Python/Node 结果写成 Rust 测试结果。

GitHub 连接可以读取原项目，但创建 `codex/windows-rust-mvp` 分支的实际操作返回：

```text
HTTP 403
Resource not accessible by integration
```

因此没有创建该分支、提交文件、打开 PR 或触发远程 Windows 构建。原始 macOS main 和源码保持不变。

## 首次 Windows 构建后应更新的证据

记录 Rust 版本、Cargo.lock、编译日志、EXE SHA-256、核心测试结果；然后单独记录真实 WGC/WASAPI/合成/退出/DPI/长录制测试。只有完成这些验证，才能把本次“源码交付”升级为“已验证可用的 Windows 版本”。
