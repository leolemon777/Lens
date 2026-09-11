# Lens Windows：Rust + Tauri 2 编码实施计划

- 版本：v2.1，2026-09-10，旧 `Windows/` C# 工程已删除。
- 决策：后端 Rust；桌面宿主 Tauri 2；UI React + TypeScript + Vite。
- 状态：当前默认工程是 `Desktop/` + `CoreRust/`。`Scripts/windows/build.ps1` 只构建该栈。G-W1/G-W2/签名仍未宣称通过。
- 工作目录：`E:\Users\Administrator\Desktop\LENS`；其他机器使用实际检出路径。
- 产品范围：[Windows SPEC PLAN](Lens-Windows-SPEC-PLAN.md) 的首版功能、G-W1 至 G-W6 和硬件矩阵继续有效。
- 冲突处理：本文替代旧 CODE PLAN 的 C#/WinForms、WinUI 3 与 C++ 主实现路线。macOS Swift 源码保持不动。当前状态见 [windows/执行记录](windows/执行记录.md)。

## 1. 技术栈与边界

| 层 | 选型 | 职责 |
|---|---|---|
| 桌面宿主 | Tauri 2、Rust | 生命周期、窗口、单实例、托盘、原生对话框、命令入口 |
| UI | React、TypeScript、Vite | 操作中心、素材库、截图编辑器、视频时间线、属性区、字幕与任务界面 |
| 视觉系统 | CSS variables、组件样式、语义化 HTML | 明暗主题、间距/字体/颜色 token、焦点、高对比度、减少动画、200% 缩放 |
| 业务后端 | Rust | 项目读写、索引、任务状态、编辑计划、模型管理、导出调度、诊断 |
| Windows 平台 | Rust + `windows` crate | Win32/WinRT、WGC、D3D11、Media Foundation、WASAPI、剪贴板、热键、DPI |
| 可移植规则 | 现有 `lens-core` 扩展 | schema、时间线、运镜、光标、字幕、确定性整理；与 Swift 黄金对照 |
| 隔离工作进程 | Rust `lens-worker` | 重计算、识别和渲染任务；继续兼容既有 stdio 协议 |
| 媒体与识别依赖 | 经验证的 FFmpeg/本地引擎 | Rust 显式管理版本、参数、进程、取消和许可证，不形成第二套业务后端 |

UI 选择理由：Web 布局适合素材卡片、时间线、属性面板和一致主题；Tauri 负责桌面集成，Rust 负责本地能力。前端编译为本地静态资源，生产包不依赖 Node.js 服务、远程网页或登录。Tauri 支持 Web 前端与 Rust 集成，Windows 宿主使用 WebView2；这些是选型依据，不是本项目性能已达标的证明。[Tauri 官方介绍](https://v2.tauri.app/start/)

不新增 WPF、WinUI 或 WinForms 正式界面。macOS 现有 Swift 应用继续维护，本次不迁移其 UI；新 Rust 规则仍需双端语义一致。Windows 11 x64 为首版基线，ARM64、Windows 10、Linux 等不因 Tauri 支持跨平台就自动纳入交付。

“后端 Rust”指产品业务、平台调度和自有采集实现使用 Rust。系统 DLL、图形驱动、FFmpeg 和识别引擎等外部原生依赖允许存在，但须列入清单。旧自有 C++ 媒体 DLL 仅可用于迁移对照/临时实验；最终默认构建不得依赖它或 C# worker。若某项 Rust 平台能力无法通过原型验证，阶段保持未通过，记录具体缺口，不静默恢复旧技术栈。

## 2. 仓库基线与模块位置

2026-09-10 清理后，Windows 产品只保留下列目录：

| 位置 | 职责 |
|---|---|
| `Desktop/` | Tauri 2 宿主、React UI、Vite 前端 |
| `CoreRust/` | `lens-core`、`lens-project`、`lens-platform-windows`、`lens-worker` |
| `Scripts/windows/` | 构建、运行、测试、打包；不再接受 `-IncludeLegacy` |
| `Sources/`、`Tests/`、`Package.swift` | macOS Swift 产品，路径不迁移 |

`Windows/` 下的 WinForms、C# 平台层和 C++ 媒体库已删除，不再作为参考实现或默认构建目标。

旧行为对照只用于理解产品回路，验收以 Tauri/Rust 真机与 `CoreRust` 测试为准。

## 3. 目标目录与模块所有权

以下目录是当前 Windows 产品布局（macOS 仍在仓库根的 Swift Package 路径）：

```text
Desktop/
  package.json / package-lock.json       # npm scripts 与精确依赖锁
  vite.config.ts / tsconfig.json
  src/
    app/                                # 路由、布局、错误边界
    components/ / styles/               # 可复用组件与视觉 token
    features/capture/ / library/ / screenshot-editor/
    features/video-editor/ / captions/ / analysis/ / settings/
    bridge/                             # typed commands、事件订阅、运行时校验
  src-tauri/
    Cargo.toml / tauri.conf.json / build.rs
    capabilities/ / permissions/         # 按窗口授权
    src/                                # Tauri 入口、状态管理、command adapters
  tests/                                # 组件、浏览器交互、桌面端到端
CoreRust/
  Cargo.toml / Cargo.lock / rust-toolchain.toml
  crates/lens-core/                      # 纯数据规则与协议
  crates/lens-project/                   # 文件、索引、锁、schema 迁移
  crates/lens-platform-windows/          # OS 资源、设备、Windows API
  crates/lens-media/                     # 管线、时间、合成、播放、导出
  crates/lens-analysis/                  # 模型、OCR/转写、整理、队列
  crates/lens-worker/                    # 受控子进程任务入口
Scripts/windows/                        # 保留统一命令入口
Build/Windows/<arch>/                    # 新版构建输出
Build/Windows/evidence/<run-id>/         # 证据及报告
```

Tauri crate 作为独立应用 crate 依赖 `CoreRust` 内的库；分别维护其 Cargo.lock，CI 检查共用 crate/协议版本，避免建立互相嵌套的 Cargo workspace。`lens-core` 不依赖 Tauri、React 或 Windows 类型；系统接口只位于平台 crate，非 Windows 构建使用条件编译。依赖具体版本在 M0/M1 根据实测冻结，不写浮动 `latest`。

## 4. 通信、状态与数据权限

### 4.1 三个边界

1. React ↔ Tauri：使用命名、类型化 commands 与事件/通道。前端接收任务 ID、项目 ID、状态和小型元数据；业务真相由 Rust 持有，刷新 WebView 后可查询恢复。
2. Rust 宿主 ↔ Rust worker：复用既有协议 v1 的 4 字节大端长度、1 MiB 帧上限、requestID、能力协商和稳定错误码。2 秒握手与长任务超时分开；业务方法、取消、结果、进度补充独立黄金用例。宿主直接调用库的普通操作不绕经 worker。
3. 采集/渲染/解码：专用线程或 worker 持有纹理、音频缓冲和文件句柄，有界队列传递。原始视频帧不逐帧 JSON/base64 传给 React，不通过每帧启动 FFmpeg 实现连续播放。

### 4.2 计划接口

| 分组 | 命令示例 | 契约 |
|---|---|---|
| 应用/来源 | `get_app_state`、`list_capture_sources`、`choose_library_root` | 能力与实际目录可查询；来源选择不擅自扩大 |
| 截图/录制 | `capture_screenshot`、`start_recording`、`pause_recording`、`resume_recording`、`stop_recording` | 返回资源/会话 ID；错误和重复请求有确定结果 |
| 项目/库 | `open_project`、`query_library`、`save_edit`、`rebuild_index` | 写入检查 schema、项目授权和 revision，冲突不覆盖 |
| 编辑/播放 | `load_edit_plan`、`apply_edit`、`open_preview`、`seek_preview`、`close_preview` | 整数时码与统一时间基；拖动合并为一次撤销 |
| 后处理 | `start_export`、`enqueue_analysis`、`cancel_task`、`retry_task` | 返回 taskId，终态可查询；失败不改原始轨道 |
| 模型/恢复 | `list_models`、`download_model`、`recover_project` | 显示体积/许可证/位置；可取消、重试、校验 |

DTO 从 Rust 契约生成或校验 TypeScript 类型；schemaVersion、revision、taskId、sequence 明确。JS 无法安全表示的 64 位时码/ID 用十进制字符串传输；HWND 不持久化为可移植项目身份。错误返回稳定 code、可操作说明和重试信息，内部栈另写受限日志。

按主窗体、选区、贴图、控制条划分 capabilities；UI 不拥有通用 shell、任意文件写入或任意 URL 加载权限。自定义 commands 在 Rust 中继续验证调用窗口、项目授权和路径，不能以配置权限代替业务鉴权。媒体用受限 asset/protocol 或原生表面访问，校验资源 ID、范围读取和关闭后的授权撤销；不暴露整盘路径。[Tauri capabilities](https://v2.tauri.app/security/capabilities/)

项目文件使用原子替换、单写者锁和版本检查；校验贯穿实际句柄打开，覆盖 junction/reparse point、ADS、保留名、大小写碰撞和 TOCTOU。CSP 使用打包资源允许列表，生产构建不放开远程脚本。识别、字幕和文件名始终按不可信文本显示。

## 5. 按依赖执行的迁移阶段

### M0：架构与环境冻结（承接 W0）

- ✅ 已执行（2026-09-09）：盘点实际源码、dirty 状态、旧 UI 功能、Rust crate、构建产物及历史未验收项；新旧对应清单见本文第 2 节与 [windows/执行记录](windows/执行记录.md)。
- ✅ 已执行（2026-09-09）：同步 SPEC/ADR 的技术栈、进程通信和部署章节，记录本次技术决定；原产品需求和指标不变。见 [Windows SPEC PLAN](Lens-Windows-SPEC-PLAN.md) §0.2/§3.1 与 [ADR-001](windows/ADR-001-技术栈与部署.md)。
- ✅ 已执行（2026-09-09，RUST-001）：检查 Rust MSVC target、Windows SDK/MSVC 链接工具、Node/npm、WebView2 与候选稳定依赖；实测版本、缓存路径和基准机记录于[工具链与环境](windows/工具链与环境.md)。Tauri/React 依赖按计划留待 M1 建立锁文件时冻结。
- Rust 原型验证真实 WGC 纹理、H.264、WASAPI 双音轨、摄像头分轨与 5 秒分片。验证 COM apartment、回调线程、纹理所有权、设备丢失和停止取消。
  - ✅ 已执行（2026-09-09，RUST-002 第一阶段）：新增 `CoreRust/crates/lens-platform-windows`（windows crate 0.62.2 锁定）。Per-Monitor DPI V2 使显示器枚举返回物理像素（本机实测 3840x2160@144，未开启时被虚拟化为 2560x1440@96）；DXGI 适配器/输出清单（RTX 4070 + 输出坐标/旋转/显存）；D3D11 硬件视频设备创建（BGRA+VIDEO_SUPPORT，feature level 0xB100，WARP 回退）；WGC `GraphicsCaptureSession.IsSupported()` 实测为 true；负坐标保留策略有单元测试。证据：`Build/Windows/evidence/m0-rust-002-20260909/platform-inventory.txt`；`cargo fmt --check`、workspace 测试（含 --ignored 基线真机项）、clippy `-D warnings` 全部通过。
  - ✅ 已执行（2026-09-09，RUST-002 第二阶段之一）：WGC 真实纹理捕获闭环。`GraphicsCaptureItem`（monitor interop）→ `Direct3D11CaptureFramePool` → `GraphicsCaptureSession` → `TryGetNextFrame` → `IDirect3DDxgiInterfaceAccess` 取 `ID3D11Texture2D` → staging 纹理 → `Map` 读回 CPU → 紧凑 BGRA。专用 MTA 线程隔离 COM apartment；主显示器实测 3840x2160、33,177,600 字节、PNG 证据已人工核验为真实桌面内容（非空白/mock）。证据：`Build/Windows/evidence/m0-rust-002-20260909/wgc-primary-frame.png`（4,600,474 字节，SHA-256 `8C451740C9E5E1546B0D786834C3A257AD0745445239A1F6CF6FFBAEAC90BCED`）；`#[ignore]` 真机集成测试断言尺寸与非黑内容。
  - ✅ 已执行（2026-09-09，RUST-002 第二阶段之二）：`FrameArrived` 事件驱动捕获与回调线程模型。`CreateFreeThreaded` FramePool + `TypedEventHandler` 闭包订阅，回调内记录 OS 线程 ID 并用 `TryGetNextFrame` 排干帧池；停止顺序为 session.Close → RemoveFrameArrived → framePool.Close。实测 worker 线程 16096、回调线程 53648（明确不在创建线程上执行），2 秒 burst 到达/排干 1 帧（静态桌面仅初始合成），elapsed 2.05s。真机测试断言：至少 1 帧回调、全部排干、回调线程 ≠ worker 线程、运行满请求时长。
  - ✅ 已执行（2026-09-09，RUST-002 第二阶段之三）：Rust WGC → Media Foundation H.264 编码 → MP4 → 解码回读全链路。`MFStartup`/D3D manager（`MF_SINK_WRITER_D3D_MANAGER` + `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`）；Sink Writer 输出 H.264、输入 ARGB32；`FrameArrived` 回调内 `MFCreateDXGISurfaceBuffer` 包装 WGC 纹理（GPU 路径，无 CPU 像素拷贝），设置 sample 时长并 `WriteSample`；关键修复：DXGI surface buffer 必须显式 `SetCurrentLength`，否则 `WriteSample` 返回 E_INVALIDARG。自带 15Hz 动画测试窗口驱动真实内容变化。验证用 Source Reader 强制 RGB32 视频处理逐帧解码并检查非零像素，不接受 ffprobe 元数据。实测枚举到 NVIDIA H.264 Encoder MFT（硬件）、Microsoft AVC DX12 Encoder（硬件）、H264 Encoder MFT（软件）；最新 5 秒 4K 证据 107 帧、解码 107 帧、3,550,003,200 字节解码数据、非零像素 true（首轮曾为 284 帧/9,422,438,400 字节，桌面内容变化导致帧数不同；当前文件以后来重跑为准）；2 秒测试多轮 63–99 帧录制与解码一致。证据：`Build/Windows/evidence/m0-rust-002-20260909/wgc-h264-recording.mp4`（6,142,331 字节，SHA-256 `43BA18869CB87FF370FE41DE7337927AF2CA1A415866DF06EE691AACE657D25C`）与 `platform-inventory.txt`；`#[ignore]` 真机测试 `records_and_decodes_h264_from_real_wgc_frames` 通过。
  - ✅ 已执行（2026-09-09，RUST-002 第二阶段之四，正常切分路径）：5 秒分片录制 + journal + 每片独立解码验证。`record_primary_monitor_h264_segmented()` 在同一次 WGC 会话内轮转多个 Sink Writer：新分片 writer 先 `BeginWriting`，再原子替换当前 writer（锁内换引用、锁外 Finalize 旧片），分片边界帧写入新片不丢失；`manifest.json` 记录 version/尺寸/帧率/segments（index/file/state/frames/起止 100ns 时戳），`writing → confirmed` 只有在该片 Finalize 后经 Source Reader 逐帧解码且非零像素才提交；manifest 用临时文件 + `MoveFileExW(REPLACE_EXISTING)` 原子替换。分片内 sample 时戳相对本片首帧（SystemRelativeTime 差值）。修复了同进程多次录制时测试窗口类重复注册导致第二次 `RegisterClassExW` 失败的问题（进程内一次注册复用）。实测 5 秒/2 秒分片：2 片 confirmed，66+17 帧全部独立解码、非零像素；4 秒/1.5 秒测试同样通过（末片允许短尾 ≥1 帧）。证据：`wgc-h264-segments/seg-000000.mp4`（66 帧，SHA-256 `76A2EEC0F4ABE9EF9E6DEB96F16AE6680E52762A9881A88789E8C73FF9BCF7FE`）、`seg-000001.mp4`（17 帧，SHA-256 `6DB160E80AE6DC0CA8796A27DC203ACCF7EA2B833B1E2D3BE73B4975EDC0836E`）、`manifest.json`（SHA-256 `C5D2865F0A29937A37D70F05FA5083707573606DE55D695F8FF35AC19C07D39D`）、`segmented-recording.txt`；`#[ignore]` 真机测试 `records_segmented_h264_with_confirmed_journal` 通过（5 项硬件测试串行全绿）。
  - ✅ 已执行（2026-09-09，RUST-002 第二阶段之五，强杀恢复路径）：只读恢复扫描器 + 子进程强杀损失边界验证。`scan_segmented_recording()` 读取 manifest 后**按真实逐帧解码判定可恢复性而非盲信 journal 状态**：journal 为 `writing` 但文件实际完整的分片照样恢复，`confirmed` 却解码失败的分片报告损坏；同时输出 recoverable_frames、broken_segments 与逐片错误，且不修改任何原始文件。新增子进程录制工具 `segmented_recorder`（bin target），测试在 8 秒强杀 15 秒录制（2 秒分片）后扫描：实测 seg-0/1/2 confirmed 且全部可解码（62+14+21 帧），仅强杀瞬间正在写入的 seg-3 损坏 —— **损失边界恰好 1 个分片，可恢复 97 帧**；另一轮完整套件中 seg-2 journal 仍为 writing 但实际完整，扫描器正确恢复（69+6+25=100 帧），仅 seg-3 损坏。断言覆盖：≥2 片可解码、损坏 ≤1 片、所有 confirmed 片可解码、recoverable_frames ≥30。证据：`forced-kill-recovery.txt`；`#[ignore]` 真机测试 `recovers_segments_after_forced_process_termination` 通过（6 项硬件测试串行全绿）。
  - ✅ 已执行（2026-09-09，RUST-002 第二阶段之六）：WASAPI 系统声 loopback + 默认麦克风双音轨并行采集。新增 `audio::capture_dual_audio()`：两路各自 MTA 线程 + `IMMDeviceEnumerator` 默认端点（render+LOOPBACK / capture），共享模式 `WAVEFORMATEX` 48kHz/2ch/16bit PCM，轮询 `IAudioCaptureClient::GetBuffer` 落独立 WAV（RIFF 头手工写入、data 长度一致）；同时渲染 440Hz 低幅参考音保证 loopback 有真实非静音内容。每轨记录 QPC 起/止与频率、端点 ID、帧数、非零样本；麦克风缺失按无设备处理不视为错误。实测 3 秒双轨：system 143,520 帧 / mic 143,520 帧（2.990s），均 48kHz 立体声 16bit、非零样本 true、QPC 频率 10MHz 一致；2 秒测试 system 96,000 帧 / mic 95,040 帧，WAV 头与 data 长度校验通过。证据：`wasapi-dual-audio/system-loopback.wav`（2.990s，SHA-256 `F56D76525AB199FEF8105D9D70B938FD873100AD39F76BF5EF04BEA1F6375A17`）、`microphone.wav`（2.990s，SHA-256 `892F23F88F17127B0B86CDC85ACEA06C6972779F8F10C59FB34A57F8B79B7B60`）、`wasapi-dual-audio.txt`；`#[ignore]` 真机测试 `captures_dual_wasapi_audio_with_clock_metadata` 通过（7 项硬件测试串行全绿）。
  - ✅ 已执行（2026-09-09，RUST-002 第二阶段之七，摄像头设备枚举/降级子步）：新增 `camera::enumerate_video_capture_devices()`，走真实 Media Foundation `MFEnumDeviceSources`（属性：source type = VIDCAP），读取 friendly name、symbolic link、硬件源标志；空结果被视为合法硬件状态并显式提示“无摄像头，摄像头轨降级”，不注入 mock 设备。处理了无设备时激活数组为空指针的边界。本机 PnP（Camera/Image 类）与 MF 枚举均实测为空列表；证据工具输出 `(none; camera track must degrade explicitly on this machine)`；`#[ignore]` 真机测试 `enumerates_video_capture_devices_without_mocking_absence` 通过。
  - ⏳ 待执行：真实摄像头帧采集与独立分轨（**本基准机当前无摄像头，需接入摄像头后在有设备机器补真实帧证据**）、GPU 设备丢失重建、完整停止/取消竞态矩阵、音视频合并录制与同步、长时稳定性。
- ✅ 已执行（2026-09-10，UI-001 选区/隐藏子步）：`lens-platform-windows::overlay` 抽出虚拟桌面并集（负原点保留）、CSS→物理映射（origin + DPR）、焦点恢复目标、`WDA_EXCLUDEFROMCAPTURE`（成功或显式 Fallback，不忽略返回值）。`Desktop/` probe 打开透明置顶选区窗时调用排除 API 并记录；单屏真机交互已补验：`Ctrl+Alt+1` → 拖拽 → Confirm 得到 `750,750 · 600×600`（DPR 1.50），主窗刷新显示 `Excluded`/`main`；Esc 取消不改写，Alt+F4 隐藏主窗且进程继续驻留。负坐标/混合 DPI 由单元夹具覆盖；证据见 [windows/执行记录](windows/执行记录.md) UI-001 与 `Build/Windows/evidence/m0-ui-001-20260910/runtime-ui-verification.txt`。托盘 Show main/Exit 菜单已实现，通知区域点击验收仍待下一步。
- 预览原型验证 WebView2 本地 H.264/AAC、seek、范围请求与实际延迟；选择代理预览或 Rust 原生表面方案并记录性能。复杂效果必须能与导出共用计划。

退出：真实 60 秒媒体、分片恢复、预览方案、桌面浮层和干净普通用户机器启动有证据。旧 C++ 原型通过只能作对照，不能替代 Rust 原型。基础媒体/部署未通过时先修复阻断，不扩展全部 UI。

### M1：工程、通信与项目服务（承接 W1）

- 建立 Desktop/Tauri/React 工程、类型化 bridge、Rust 模块和锁文件；主入口显示真实 Rust 应用状态。
- 迁移项目 schema/读写、路径授权、任务模型、设置、索引、资源服务；打开旧项目只读不改字节。
- 保留 worker 协议黄金，新增业务命令、任意分片、超长帧、超时/崩溃、事件重连、取消竞态用例。
- 建立设计 token、键盘操作和页面结构：操作中心、素材库、预览/时间线/属性编辑器、任务与设置。
- 重写构建/运行/测试入口和 Windows CI，默认入口必须生成 Tauri 应用；旧 C# 测试独立标为 legacy。

退出：干净检出构建成功，Tauri EXE 可启动并真实调用 Rust 项目服务；未来 schema 拒绝写入，坏输入不写盘；生产资源不依赖开发服务器。

### M2：截图、录屏、恢复的可用闭环（承接 W2）

- 截图：热键 → 来源选择 → Rust 捕获 → 原图原子保存 → 剪贴板 → Quick Access → 素材库；取消无残留，复制失败保留图像并可重试。
- 录制：来源/音频/摄像头确认 → 倒计时 → 录制/暂停/继续 → 安全停止 → 原片立即播放 → 后台草稿。显示时长、电平、空间、实际设备及状态。
- Rust 状态机：Idle → Preparing → Recording ↔ Paused → Finalizing → Ready；异常 Interrupted/Failed。重复停止和各阶段取消不得生成多个项目或死锁。
- 独立音轨、摄像头和事件映射到单调时钟；暂停时间不进入素材。低于 5 GiB 警告、低于 1 GiB 安全停止，并按码率估剩余时间。
- 分片独立可解码，确认后提交 journal；恢复保留损坏原件，生成派生恢复文件。锁屏/休眠/来源丢失安全停止；设备重建写不连续记录。
- 素材库支持筛选、查询、打开、导入旧项目、定位、重建索引和明确确认的删除；E 盘掉线不自动改到 C 盘。

退出：Tauri UI 发起的真实截图/粘贴、录制播放和恢复成立；W2 可称内测，不能称完整 1.0。执行 100 次截图、60 分钟录制及故障矩阵，记录所有尚未达标项。

### M3：完整截图编辑（承接 W3）

迁移九类可编辑标注：矩形、椭圆、箭头、画笔、高亮、编号、文字、模糊、像素化。React 负责交互和局部草稿，Rust 持有可保存编辑计划、历史和最终渲染规则。增加撤销/重做、背景、PNG/JPEG、贴图置顶/缩放/透明度/锁定/复制、多窗口层级合成。

长截图由用户滚动触发，Rust 做重叠、重复帧和稳定性判断，保存源帧与拼接计划；固定页头、动画、无重叠均有停止策略。OCR 在截图交付后异步执行。截图坐标统一处理桌面物理像素、Web CSS 像素、逻辑 DPI、素材像素，测试往返与多屏切换。

退出：每项从热键到编辑、导出、粘贴和历史重开通过；最终遮挡像素不可读出原文字；原始素材摘要不变。

### M4：成片编辑与连续播放（承接 W4）

- 将时间线、运镜、光标、点击、字幕、摄像头避让和关键帧迁入 Rust，用 Swift/旧输出对照确定行为。
- 编辑器连接真实项目：裁切、分割、复制/重排、0.5×–3×、转场、撤销/重做、未保存提示、字幕编辑和原子保存。
- 实现连续解码、音频时钟、seek、播放/暂停/重播、末尾处理与过期帧丢弃。时钟按实际单调时间推进，不按定时器回调次数假设帧率；不能用 PNG 轮询冒充音视频播放器。
- 预览与导出消费同一版本化 RenderPlan：运镜、光标、点击、背景、视频标注、画中画、位置关键帧、旁白混音、字幕及三档输出。
- 原画/平衡/轻量分别冻结帧率、分辨率、质量和音频配置；未知编码器明确失败或由用户选择回退。字体缺失、中文覆盖和跨端替换规则要可解释。
- 代理和缓存键覆盖源摘要、计划/revision、时间基、字体、参数及分辨率；修改计划失效，关闭项目释放资源。

退出：最终 MP4 解码帧与音频逐项反事实对比通过；字幕/事件误差 ≤1 输出帧；音频无累积漂移；失败/取消保留旧导出及原片。原始播放与完整效果预览分别验收，不将前者冒充后者。

### M5：本地智能与跨端互通（承接 W5）

- Rust 模型管理：用户选择目录，展示体积/许可证；续传校验 Content-Range、大小与 SHA-256，取消保留可恢复片段，坏数据不替换有效模型。
- 迁移可恢复任务队列，明确进程退出后 Running 的恢复策略；超时、取消、模型缺失、空转写均有可重试状态。
- 接入真实离线 OCR/中英文转写引擎，固定样本/参考文本/来源许可/摘要/归一化规则，记录模型版本、环境、CER/WER、耗时和内存。模型没有真实运行时不宣称质量通过。
- 字幕使用源时码；标题、摘要、标签、章节和统一搜索接入项目库，保留人工覆盖层。重新识别或更换模型不得覆盖人工编辑，索引可重建。
- 使用权威 Swift schema 与开放格式定义，不把旧 C# 的 `0.1` 常量直接作为当前唯一可编辑版本。字段/资产不兼容时明确只读或拒绝。
- Mac → Windows → Mac 及反向真实往返，覆盖 CAF/MOV、Windows 音视频、字幕、时间线、缺失侧轨、未来 schema、中文/空格/长路径；新写格式先补双端读取。

退出：固定断网语料 OCR CER ≤5%，转写中文 CER/英文 WER ≤15%；真实双端测试及人工校正保护通过。Windows 上的 mock provider/JSON 测试不能代替 macOS 运行证据。

### M6：发布、旧入口退出与维护（承接 W6）

- Tauri NSIS EXE 安装器支持选择目录；验证 WebView2 存在、安装失败和离线部署。具体采用固定版本或离线运行时安装资源在 M0 冻结，清单包含体积与再分发条件。[Tauri Windows 安装说明](https://v2.tauri.app/distribute/windows-installer/)
- 发布包包含 Rust/Tauri 应用、所需 worker/媒体/识别依赖、静态 UI、许可证、符号、SHA-256 和机器可读 release.json。不包含旧 WinForms/C# 产品 DLL，不要求安装 .NET 应用运行时。
- 安装器 Authenticode 与更新包签名分别校验，签名检查不能替代文件摘要。提供普通用户安装、升级失败回滚、录制中延后更新、保留上一版本及卸载保留项目。
- 检查旧程序/快捷方式/托盘/配置迁移冲突；旧库只读导入，不自动改写 schema。更新回滚遇未来 schema 拒绝写入，提供备份副本入口。
- 默认 `build/run/package` 与 CI 彻底切到新栈；旧实现从产品依赖退出后再处理归档清单。新测试不能只是读取源码字符串检查是否“有控件”。
- 补齐安装使用、权限排障、数据备份互通、发布回滚、兼容矩阵五份文档，覆盖新 UI 的实际路径和运行时依赖。

退出：G-W1 至 G-W6、首版全部功能和干净机器全流程通过；无未解释的原始数据损坏、隐私泄露或静默错误成片。发布到外部仍按用户当次发布授权执行。

## 6. 构建与验证入口契约

现有同名脚本还服务旧工程。以下是重写后的目标契约，必须先实现再作为新栈验收命令使用；不能运行旧脚本后报告迁移通过。

| 入口 | 目标行为 |
|---|---|
| `check-env.ps1 -Architecture x64 -ReportPath <json>` | 检查 Rust/MSVC/SDK、Node/npm、WebView2、锁版本及目录；区分缺失/不匹配 |
| `build.ps1 -Configuration Debug/Release -Architecture x64` | npm 锁定安装、TypeScript 检查、Vite 静态构建、Rust/Tauri 同 profile 构建；Release 必须传 Rust release profile |
| `run.ps1 -Configuration Release -DataRoot <path>` | 仅启动匹配的新 Tauri EXE；缺少产物报错，不启动 dev server/旧 .NET |
| `test.ps1 -Suite <name> -Configuration Release` | 分发新版 Rust、前端、桌面和真实媒体测试；缺失套件失败，跳过项显式列出 |
| `run-recording-stress.ps1 -DurationSeconds 3600 -DataRoot <path>` | 调用新版 Rust 耐久工具，结束后逐片完整解码、同步分析、失败报告 |
| `package.ps1 -Channel internal/beta/stable -Architecture x64 -Version <version>` | Tauri 安装包、依赖/符号/摘要；公开通道 clean 源码与正式签名 |
| `verify-release.ps1 -ManifestPath <json> -Mode Development/Public` | 独立核对技术栈产物、profile、架构、commit、文件摘要、签名与运行时 |

测试套件必须保留 Unit、Protocol、Project、Media、Screenshot、Recording、Recovery、Effects、Analysis、Interop、Accessibility、SyncFixture、Install，新增 Frontend 和 Desktop。每一项列出 runner、测试清单、数量、跳过及原始报告。Analysis 明确分开下载/队列单元测试与真实模型质量。SyncFixture 只用于测量校准，不能替代实际 WGC/WASAPI 注入。

底层验证包括 `cargo fmt --check`、锁定依赖的 cargo check/clippy/test、前端 typecheck/build/组件交互测试；精确 npm scripts 在 M1 建立。浏览器测试可验证布局和交互，Tauri 真机测试必须覆盖实际 IPC/权限/窗口/剪贴板。测试运行器和 WebView2/WebDriver 兼容版本先做原型，不能假定浏览器测试可直接控制桌面宿主。

统一退出码：0 成功、1 工作失败、2 环境/输入不满足；每个外部命令独立检查。构建报告包含依赖锁摘要、dirty 文件摘要、实际 profile 与产物路径。清理只作用于已解析的本次输出子目录。

长任务只启动一次并保存 PID、runId、源码/构建摘要、日志及结果路径；后台运行时推进独立工作。验证新代码使用独立产物目录，不覆盖正在执行的耐久二进制；不得反复重启录制。结束状态与最终报告一起核验，进程存在或分片数量增长不能证明完成。

## 7. 保留的质量门槛与证据口径

| 闸门 | 新栈验收要求 |
|---|---|
| G-W1 | Release 真实截图 100 次；100/100 文件正确，剪贴板成功或可重试；交付 P95 ≤500 ms |
| G-W2 录制 | 动态 1080p60 + 系统声/麦克风/摄像头 60 分钟；丢帧 <0.1%，无未解释黑帧/冻结，内容级音画偏差绝对值 ≤80 ms |
| G-W2 停止/恢复 | 至少 10 次停止，原片可播放 P95 ≤5 秒；强杀/满盘/拔设备/GPU 故障各 ≥10 次，确认分片 100% 找回，损失目标 ≤5 秒 |
| G-W3 | 每项效果实际进入最终媒体，0.5×/3×、裁切/重排/重复/转场映射误差 ≤1 输出帧；音频无累积漂移 |
| G-W4 | 热启动 P95 ≤2 秒；空闲平均 CPU ≤1%；录制私有内存 ≤1 GiB 且无持续增长；UI 帧工作 P95 ≤16.7 ms，无重复超过 100 ms 卡顿 |
| G-W5 | 固定中英文断网样本，OCR CER ≤5%，转写 CER/WER ≤15%；失败不阻塞媒体 |
| G-W6 | 无开发环境普通用户机器，E 盘安装/升级/回滚/卸载可用，原始项目摘要不变 |

性能统计包含 Tauri、WebView2、worker 和外部媒体进程，不能只测 Rust 主进程。完整解码使用真正解码到帧/音频的过程；ffprobe 读取流信息不是“已逐片解码”，音视频总时长接近不是内容同步证明。报告保留输入摘要、起止时间、设备/驱动、失败项、实际帧数与时钟分析。

完整矩阵沿用 SPEC §7.2：多屏/混合 DPI/负坐标/竖屏/插拔/SDR-HDR；Intel/AMD/NVIDIA/混合显卡；USB/蓝牙/44.1–48 kHz/静音/占用/权限；中英文/AltGr/休眠/锁屏/管理员来源/RDP 限制；本地 NTFS、长路径/只读/满盘/改盘符；真实浏览器、Office、IDE、聊天软件粘贴；Narrator、键盘、高对比度、减少动画、200% 文本。

原始 `raw/`、长截图源帧与人工编辑始终有摘要/回读证据。未知能力明确禁用并解释，但禁用不等于完成首版功能。

## 8. 执行状态与首批任务

| 阶段 | 当前状态 | 下一项可执行工作 |
|---|---|---|
| 文档重规划 | 已完成本文重写 | 实施时同步 SPEC/ADR 架构描述 |
| M0 原型/冻结 | 进行中：RUST-001 已执行；RUST-002 媒体原型大部分通过；UI-001 Tauri 桌面原型已执行（选区几何、捕获排除、焦点恢复、E 盘清单） | RUST-002 剩余（真实摄像头采集待摄像头硬件、设备丢失/停止取消竞态、音视频合并）、MEDIA-001 连续播放/效果预览验证、BUILD-001 |
| M1 工程/契约 | 进行中：`lens-project` + Desktop 操作中心/库已可启动 | 补 worker 业务黄金、新栈默认 build.ps1 |
| M2 最小闭环 | 进行中：区域/屏幕截图落盘+剪贴板、屏幕录制分片+停止预览 | 暂停/窗口来源、100 次截图与 60 分钟闸门 |
| M3 完整截图 | 未开始迁移 | 标注、贴图、长截图和 OCR |
| M4 成片编辑 | 未开始迁移 | Rust RenderPlan、连续播放与编辑导出 |
| M5 智能/互通 | 未开始迁移 | 真实模型质量与 Mac 双向往返 |
| M6 发布/退出旧栈 | 未开始迁移 | 安装、性能矩阵、新栈默认构建和旧依赖退出 |

首批任务按顺序执行：RUST-001 环境与锁版本盘点；RUST-002 Rust 媒体原型；UI-001 Tauri/React 桌面原型；MEDIA-001 连续播放/效果预览技术验证；BUILD-001 新栈构建与离线安装烟测。RUST-002、UI-001、MEDIA-001 可在接口确定后独立并行；M0 退出必须汇总三条链和部署证据。

每次交付记录：任务/阶段、基线 commit 与 dirty 摘要、环境、改动行为、实际命令/profile/退出码、证据位置、未通过项和下一步。只有新栈对应测试与真实使用路径均通过，才更新该阶段状态。旧 C# 测试数、mock 返回值、单帧 PNG 签名、编译成功都不能替代整项能力验收。

下一次编码任务指令：

> 从本计划 M0 开始实施 Rust + Tauri 2 + React/TypeScript 迁移。先盘点工作区和后台任务，保留已有数据，同步技术决策并完成 Rust 采集、Tauri 多窗口与连续播放原型。后端业务和平台实现迁入 Rust；不继续扩展 WinForms。原型验证后推进 M1，再按完整产品范围交付，逐阶段记录真实证据。本文重写本身不授权提前宣称代码迁移完成。
