# Lens Windows 移植计划 v1

状态：执行中。里程碑 0 的契约部分已完成，实现部分等待 Rust 工具链。

本文是 Windows 版的总计划。目标定位与 macOS 版不同：**自用 + 开源，不是商业发行**，因此不追求发布品质对等，只追求能力对等。

## 1. 决策与依据

### 1.1 为什么是「独立实现 + 只共享数据」

早期设想是 Rust 共享核心 + 两个原生壳（即《Lens 1.0 产品与研发总计划》2.5 节的路线）。实测数据推翻了这个方案：

统计 macOS 版最近 13 次真实改动的落点：

| 类型 | 核心占比 | 例子 |
|---|---:|---|
| 纯逻辑改动 | 90–100% | 窗口命名规则、录制恢复策略 |
| 混合改动 | 17–33% | UI 质量改造、录制恢复 |
| **纯 UI/交互改动** | **0%** | 贴图手感、权限引导、玻璃质感、选区吸附缓存 |

**合计：核心 3,346 行 / 平台 26,204 行 —— 只有 11% 落在可共享的纯逻辑。**

结论：为了那 11% 去建共享核心（需用 Rust 重写 15,000 行已测逻辑 + 7,157 行测试），投入产出不成立。而且 0% 核心占比的那些改动本来就**不该**跨平台复用——Windows 应用不该长成 macOS 毛玻璃的样子，Windows 也没有 TCC 权限模型。

因此确定：

- **两边不共享代码，只共享 `.lens` 数据契约。**
- 可以不同：界面外观、交互手感、权限模型、快捷键、渲染后端。
- 必须相同：`.lens` 读写结果、规划算法输出、schema 版本拒绝行为。

### 1.2 已推翻的假设

《Lens 1.0 产品与研发总计划》第 129 行写「Windows 后续只替换平台捕获适配器，不重写整个产品」——**这句已不成立**。当前需要替换的是 37,300 行中的绝大部分，其中 19,285 行是 UI。该文档需要在本计划确认后同步修订。

### 1.3 成本预期

Windows 版完成功能对等约需 **9–12 个月**（单人）。这不是一次性成本的全部：跨平台后每个新功能的成本约为 **1.8 倍**（共享逻辑只能省下约 11%，深度优化后上限约 35%）。

接受这个代价的前提是自用需求真实存在。若后续判断不值，可以停在任一里程碑——每个里程碑结束都是可用状态。

## 2. 当前状态

### 2.1 已完成

| 交付 | 位置 |
|---|---|
| 跨语言契约文档 | [Lens 可移植文档字段规范](Lens-可移植文档字段规范-v1.md) |
| 黄金文件（8 落盘 + 8 紧凑 + 1 注册表） | `shared/golden/` |
| 黄金文件生成器 | `Sources/lens-schema-golden/`、`Sources/LensSchemaGoldenKit/` |
| 漂移守卫测试（6 项） | `Tests/LensCoreTests/PortableSchemaGoldenTests.swift` |
| Windows 层规划 | `windows/README.md` |

基线：**727 项测试全部通过**，公开源码审计通过（368 个跟踪文件）。

### 2.2 途中修正的问题

1. 版本表漂移：manifest 文档标 0.8 / 实际 0.9；edit-plan 标 1.2 / 实际 1.3。已修正。
2. Swift `.prettyPrinted` 输出 `"key" : value`（冒号两侧空格），跨语言无法逐字节复现。已增加紧凑形态作为比对基准。
3. 若干字段的「JSON 缺失默认值」与「构造默认值」刻意不同（旧项目保护）。已在规范第 5 节全部列出——这是移植中最易出错处。

### 2.3 未决

- Rust 工具链尚未安装，`windows/` 下无可编译代码。
- 3,650 行错位逻辑（住在 `LensMac` 但只依赖 Foundation）尚未归位。

## 3. 里程碑

| # | 内容 | 估时 | macOS 上可验证 | 完成后能做什么 |
|---|---|---:|:---:|---|
| **0** | `lens-format` crate | 1–2 周 | ✅ 完全 | 契约闭环，协作模式验证 |
| **1** | 截图链 | 2–3 月 | ❌ | **Windows 上用上最高频功能** |
| **2** | 录屏捕获与落盘 | 2–3 月 | ❌ | Windows 录、Mac 编 |
| **A** | 转写与整理（可并行） | 1 月 | ✅ 大部分 | 字幕与本地整理 |
| **3** | 成片渲染 | 3–4 月 | ⚠️ 部分 | 自动成片 |
| **4** | 编辑器 UI | 1–2 月 | ❌ | 完整对等 |

里程碑 A 与 1/2 无依赖，可在等待 Windows 环境时推进。

---

### 里程碑 0 — `lens-format`

**目标**：Rust 完整读写 8 份可移植文档，通过黄金文件一致性验收。

**范围**

- 8 份文档的 Rust 模型（对应 `shared/golden/schema-registry.json`）
- 复刻规范 §4 的全部钳制范围（22 项）与派生公式
- 复刻规范 §5 的全部解码默认值陷阱（**不可用 `#[serde(default)]`**）
- 规范 §1.2 的紧凑编码：键排序、斜杠不转义、UUID 大写、ISO8601 无小数秒
- schema 版本拒绝：高于 `currentVersion` 或格式非法时明确报错

**验收**

1. 解析 `shared/golden/*.json` 得到与 Swift 相同的值；
2. 重新编码后与 `*.compact.json` 逐字节相同；
3. 通过 `Tests/LensCoreTests/Fixtures/` 下 `LegacyRecordingV0_1`、`LegacyScreenshotV0_1` 只读兼容；
4. 未来版本 / 畸形版本被拒绝。

**前置**：Rust 工具链（`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`）

**为什么先做这个**：纯数据、零平台 API，**可以在 macOS 上完整验证**。在拿到 Windows 环境之前就能检验契约是否完整、协作循环是否顺畅。

---

### 里程碑 1 — 截图链

**目标**：Windows 上完成「截图 → 标注 → 存 `.lens` → Mac 能打开」。

**范围**

| 模块 | 对应 macOS 实现 | 可照搬的算法 |
|---|---|---|
| 区域/窗口/显示器捕获 | `ScreenCaptureService`(458) | — |
| 选区浮层与边缘吸附 | `CaptureOverlayView`(1100) | `CaptureGeometry`(373)、`RegionSnapRectCachePolicy`(53) |
| 九类对象标注 | `ScreenshotAnnotationEditor*`(1653) | `ScreenshotAnnotationGeometry`(310)、`ScreenshotEditPlan`(269) |
| 标注/画布渲染 | `ScreenshotAnnotationRenderer`(624) | `ScreenshotCanvasPlanner.layout` |
| 长截图 | 取帧部分需重写 | `VerticalScrollingCaptureAssembler`(413) 纯算法 |
| OCR | `VisionOCRService`(**68**) | `OCRDocument`(57) |
| 贴图窗口 | `PinnedImageWindowController`(952) | — |
| 库与搜索 | `LensLibraryView`(1092) | `LensLibrary`(257)、`LensLibraryPersistentIndex`(269) |

**技术**：Windows.Graphics.Capture、Skia、RapidOCR、原生 `windows-rs` 直绘浮层（不走 Tauri，`一按即捕捉` 对延迟敏感）。

**验收**：Windows 截的 `.lens` 在 macOS 版 Lens 库中能打开、标注可见、OCR 文本可搜索；反向亦然。

---

### 里程碑 2 — 录屏捕获与落盘

**目标**：Windows 上录制并写出合法 `.lens`，可在 macOS 版编辑器中打开编辑。

**范围**

- 视频流：Windows.Graphics.Capture，30/60 FPS 可选，帧率写入 manifest
- 系统音频：WASAPI loopback
- 麦克风、摄像头独立轨（不混进屏幕流）
- 分片写入与真实暂停/继续 —— 必须符合 `segments.json` 契约，注意 `durationSeconds: null` 表示**正在写入或被中断**，不是 0
- 四类事件轨 JSONL：`pointer` / `clicks` / `keyboard` / `windows`
- 隐私收敛：键盘轨只记录快捷键与非文本控制键，**普通文字输入永不记录**；应用轨不保存窗口标题
- 磁盘空间监控与安全停止
- 崩溃恢复：复刻 `RecordingRecoveryAssessment`(183) 的判据

**验收**：Windows 录制的项目在 macOS 编辑器中时间轴、音轨、事件轨全部正确；强杀进程后可恢复。

---

### 里程碑 A — 转写与整理（可并行）

**目标**：本地转写与整理，产出 `transcript.json` 与 `insights.json`。

- 转写：whisper.cpp（替代 Apple Speech，语言更多、可离线）
- 长音轨分片与重叠去重：照搬 `TranscriptChunking`(196)
- 字幕规划：照搬 `CaptionCuePlanner`(388)，含中日文紧凑断句
- 本地整理：照搬 `LocalLensOrganizer`(758)、`SensitiveRedactionPlanner`(83)

**隐私红线**：`sensitiveFindings[].redactedPreview` 只写掩码提示，**命中的原值绝不落盘**。

**大部分可在 macOS 上验证**（纯算法 + whisper.cpp 跨平台）。

---

### 里程碑 3 — 成片渲染

**目标**：读 `edit-plan.json` 渲染出 MP4。

这是最重的一块，但比表面看起来便宜。拆解 `AutoPreviewRenderer`(1709) 的 251 个平台符号：

- **~102 个是 `CGRect`/`CGPoint`/`CGFloat`/`CGSize`/`CGAffineTransform`** —— 纯几何数学，不是平台锁定
- ~97 个 Core Image（滤镜合成）→ Skia 同类替换
- **仅 8 个 AVFoundation** —— 视频 IO 只是薄薄一层

因为编辑是非破坏性的（`edit-plan.json` 存的是**意图**），Windows 侧不需要复刻 AVFoundation 对象模型，只需实现「edit-plan → FFmpeg filter 链」的执行器。

**范围**：运镜关键帧、光标平滑/替换/特效、点击反馈、背景画布、圆角阴影、人像画中画、字幕烧录、九类视频标注、音频混音/降噪/K 加权响度、三档导出预设。

**验收**：同一份 `.lens` 在两边渲染，关键帧位置、时长、音轨、画中画像素位置一致（容差内）。

---

### 里程碑 4 — 编辑器 UI

时间线、入出点、分割、变速、三种转场、摄像头画布拖放、字幕逐条校对、标注绘制。

技术：Tauri + Web 前端。

## 4. macOS 侧的并行工作

| 事项 | 时机 | 说明 |
|---|---|---|
| 3,650 行错位逻辑归位 | 当前功能提交后 | 21 个文件只依赖 Foundation 却住在 `LensMac`。归位后 Windows 侧才分得清「算法」与「macOS 实现」 |
| Developer ID 签名与公证 | 里程碑 1 之前 | macOS 1.0 的最后阻断项 |
| 修订总计划 2.5 节 | 本计划确认后 | 第 129 行的假设已失效 |
| README 测试数校准 | 随手 | README 写 634 项，实际 727 项 |

## 5. 验证机制

**这是本计划最大的风险点。** 开发在 macOS 上进行，但里程碑 1、2、4 无法在 macOS 上验证。

两个方案：

| 方案 | 循环速度 | 前提 |
|---|---|---|
| **Windows 机器上也开 Claude Code** | 基准 | 该机可安装 |
| 交叉编译产物 + 人工回传日志 | **慢 3–5 倍** | 无 |

强烈建议第一个。两边通过 `github.com/leolemon777/Lens` 同步：macOS 侧写共享逻辑与契约，Windows 侧写平台层并真机验证。

无论哪种方案，**「使用体验」的判断必须由人做**——手感、跟手程度、浮层响应速度无法自动化验收。

## 6. 待决事项

| # | 事项 | 状态 |
|---|---|---|
| 1 | Rust 工具链安装 | **阻塞里程碑 0** |
| 2 | Windows 机器能否安装 Claude Code | **阻塞里程碑 1** |
| 3 | Windows 系统版本（Windows.Graphics.Capture 需 Win10 1903+，部分能力需 Win11） | 待确认 |
| 4 | 当前改动的提交策略（并入 `ui/quality-overhaul` 还是另开分支） | 待确认 |
| 5 | Tauri 与原生浮层的边界（哪些界面走 Web） | 里程碑 1 前确定 |

## 7. 退出条件

任一里程碑结束都是可停点。若判断 1.8 倍的长期成本不值得，可以：

- 停在里程碑 1：Windows 上有截图工具，录屏仍用 macOS；
- 停在里程碑 2：Windows 录、Mac 编，两边数据互通；
- 完全停止：`shared/golden/` 与规范文档对 macOS 版无害，且已修正了三处真实问题。
