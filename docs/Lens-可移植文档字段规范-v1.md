# Lens 可移植文档字段规范 v1

状态：Windows/Rust 实现的接口契约。本文与 `shared/golden/` 一起构成非 Swift 实现的唯一依据。

本文描述**语义、默认值、取值范围和陷阱**；穷举字段清单以 `shared/golden/*.json` 为准（样例刻意填满了每个可选字段）。两者由 `PortableSchemaGoldenTests` 保证与代码一致——文档漂移会导致 `swift test` 失败。

- 目录结构、兼容规则见《[Lens 开放项目格式](Lens-开放项目格式-v0.1.md)》。
- 版本注册表的机器可读镜像：`shared/golden/schema-registry.json`。
- 重新生成：`swift run lens-schema-golden`。

## 1. 编码约定

### 1.1 两种形态

| 形态 | 文件 | 用途 |
|---|---|---|
| 落盘形态 | `shared/golden/<name>.json` | 与 `LensProjectStore` 实际写入磁盘的字节完全一致 |
| 规范紧凑形态 | `shared/golden/<name>.compact.json` | **跨语言逐字节比对用** |

**落盘形态不能用于跨语言字节比对。** Swift 的 `JSONEncoder.outputFormatting = .prettyPrinted` 会输出 `"key" : value`——冒号**两侧都有空格**。serde_json、System.Text.Json、Python `json` 全都输出 `"key": value`。这个差异无法通过配置消除。

因此：

- **读**：任何实现都必须能解析落盘形态并得到相同的值。
- **写**：只要求语义等价，不要求与 Swift 落盘字节一致。
- **一致性测试**：比对紧凑形态。

### 1.2 紧凑形态的确切规则

1. 无任何多余空白（`{"a":1,"b":[2,3]}`）。
2. 对象键按 **UTF-8 码元字典序**升序排列（Swift `.sortedKeys`）。
3. 斜杠 `/` **不转义**（不得写成 `\/`）。
4. 非 ASCII 字符**不转义**为 `\uXXXX`，直接输出 UTF-8 字节。
5. `Date` 编码为 ISO 8601 `YYYY-MM-DDThh:mm:ssZ`，**无小数秒**，始终 UTC。写入前秒数向下取整。
6. `UUID` 编码为**大写**带连字符字符串：`00000000-0000-4000-8000-000000000001`。小写会导致比对失败。
7. `Double` 使用最短往返表示（`2.8` 而非 `2.7999999999999998`）。整数值的 Double 输出为 `1`，不是 `1.0`。

> Rust 提示：`serde_json` 默认按插入顺序输出，需启用 `preserve_order` 之外的排序策略或使用 `BTreeMap`；默认也不转义斜杠，符合要求；`uuid::Uuid::to_string()` 输出小写，必须 `.to_uppercase()`。

### 1.3 日期策略的例外

`AutoEditPlan`（edit-plan.json）和 `RecordingSegmentIndex`（segments.json）**不含任何日期字段**，macOS 侧读写它们时使用未配置日期策略的裸 `JSONDecoder`/`JSONEncoder`。实现时无需为这两份文档准备日期处理。

含日期的文档：`manifest.json`(`createdAt`)、`ocr.json`(`recognizedAt`)、`transcript.json`(`generatedAt`)、`insights.json`(`generatedAt`)。

## 2. 共享基元类型

| 类型 | JSON 形状 | 说明 |
|---|---|---|
| `LensPoint` | `{"x":Double,"y":Double}` | 二维点 |
| `LensRect` | `{"x":D,"y":D,"width":D,"height":D}` | 矩形，**左上角原点** |
| `LensDimensions` | `{"width":Int,"height":Int}` | 像素尺寸 |
| `LensColor` | `{"red":D,"green":D,"blue":D,"alpha":D}` | 各分量 `0...1`，非 0–255 |

颜色另有 **十六进制字符串**形式用于 edit-plan 的若干字段（`clickPulseColorHex`、`accentColorHex`、`backgroundTopHex` 等）。规范化规则：去掉 `#` 和空格、转**大写**、必须恰好 6 位十六进制；不满足则回退到该字段的兜底色。写出时始终带 `#` 前缀。

## 3. 坐标系与时间基准

| 维度 | 约定 |
|---|---|
| 原点 | **左上角**，向右为 +x，向下为 +y。全部文档统一。 |
| 归一化坐标 | `0...1`，用于跨分辨率可移植的位置（OCR 块、标注、画中画中心、运镜中心）。 |
| 逻辑点坐标 | 捕获来源的 `globalBounds` / `sourceRect` 使用逻辑点（非物理像素）。 |
| 像素坐标 | 长截图计划的 `verticalOffsetPixels` / `appendedHeightPixels` 使用物理像素。 |
| 视频编辑时间 | **源素材时间**（秒），不是输出时间。剪切、变速、重排后仍然指向原始录制的同一时刻。 |
| 录制分片时间 | `timelineStartSeconds` 是**去暂停后**的输出时间轴。 |

> 源时间是整套非破坏性编辑的基石：字幕、视频标注、摄像头关键帧全部存源时间，因此重新剪辑不会让它们错位。任何实现都必须保持这个语义，否则剪辑后成片会漂移。

## 4. 文档字段规范

穷举字段见对应黄金文件。以下只列语义、缺省和范围。

### 4.1 `manifest.json`（当前 0.9，最低可读 0.1）

唯一入口。`assets` 中的 `relativePath` **一律相对包根**，禁止绝对路径。

| 字段 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `schemaVersion` | String | 是 | `主.次` |
| `id` | UUID | 是 | 大写 |
| `kind` | `screenshot` \| `recording` | 是 | |
| `createdAt` | ISO8601 | 是 | 秒级向下取整 |
| `title` | String | 是 | |
| `state` | `capturing`/`processing`/`ready`/`interrupted`/`failed` | 是 | |
| `durationSeconds` | Double | 否 | 截图为空 |
| `dimensions` | LensDimensions | 否 | |
| `captureSource` | 见下 | 否 | 录屏来源 |
| `screenshotCaptureSource` | 见下 | 否 | 截图来源 |
| `assets` | `[{role,relativePath}]` | 是 | `role` 见枚举 |

`captureSource` 的帧率字段有历史包袱：`framesPerSecond` 是 0.8 及更早的遗留字段，`requestedFramesPerSecond` 是当前字段。**读取时若后者缺失应回退到前者**；写入时两者都写。`measuredFramesPerSecond`、`p95FrameIntervalMilliseconds`、`droppedFrameCount` 是实测值，可缺失。

`LensAsset.role` 完整枚举（23 项）见 `shared/golden/manifest.json` 与源码 `LensAsset.Role`。

### 4.2 `edits/edit-plan.json`（当前 1.3，最低可读 0.1）

体量最大、陷阱最多。顶层：`schemaVersion`、`preset`、`cursor`、`camera` 为必需，其余（`presenterCamera`、`audio`、`canvas`、`interaction`、`timeline`、`captions`、`videoAnnotations`、`export`、`narrationTrims`）全部可选。

**必须实现的钳制范围**（不实现会导致成片与 macOS 不一致）：

| 字段 | 范围 |
|---|---|
| `camera.zoomScale` | `1...3` |
| `camera.motionBlurStrength` | `0...1`，`0` 是严格旁路 |
| `cursor.motionEffectStrength` | `0.1...1` |
| `cursor.smoothingWindowMilliseconds` | `0...160` |
| `interaction.clickEffectStrength` | `0.1...1` |
| `interaction.clickPulseScale` | `0.5...3` |
| `interaction.clickPulseDuration` | `0.15...1.5` |
| `keystrokes[].holdSeconds` | `0.3...3` |
| `canvas.margin` | `0...0.25` |
| `canvas.cornerRadius` | `0...0.2` |
| `presenterCamera.size` | `0.08...0.45` |
| `presenterCamera.margin` | `0...0.20` |
| `presenterCamera.cornerRadius` | `0...0.5` |
| `audio.systemVolume` / `microphoneVolume` | `0...2` |
| `audio.targetLoudnessLUFS` | `-24...-10` |
| `audio.narrationThresholdDecibels` | `-80...0` |
| `captions.fontScale` | `0.7...1.6` |
| `captions.maxCharactersPerCue` | `8...64` |
| `captions.verticalMargin` | `0...0.3` |
| `timeline` 片段 `playbackRate` | `0.25...4` |
| `transition.durationSeconds` | `0.05...2`；`cut` 强制为 `0` |
| `videoAnnotations[].fadeDurationSeconds` | `0...1` |

**派生值**（缺字段时按公式算，不要另起默认）：

- `camera.resolvedZoomScale` = `zoomScale ?? clamp(1 + 0.58 * (zoomIntensity / 0.42), 1, 3)`
- `cursor.resolvedSmoothingWindowMilliseconds` = `smoothingWindowMilliseconds ?? clamp(smoothing, 0, 1) * 80`
- `cursor.followStyle` 决定实际平滑参数：`faithful` → `(0, nil)`；`smooth` → `(0.72, 26)`；`elastic` → `(1, 80)`；`custom` 或字段缺失 → 使用 `smoothing` 与 `smoothingWindowMilliseconds` 原值。

### 4.3 `edits/screenshot-edit.json`（当前 0.3，最低可读 0.2）

`sourceDimensions` 必需；`annotations` 数组的几何全部是**归一化**坐标；`canvasStyle` 可选，缺失表示不套画布。

`ScreenshotAnnotationStyle.lineWidth` / `fontSize` / `intensity` 是**相对图像短边的比例**，不是像素。`canvasStyle` 的 `padding` / `cornerRadius` / `shadowRadius` 同理，且钳制为 `padding 0.02...0.30`、`cornerRadius 0...0.12`、`shadowRadius 0...0.12`、`shadowOpacity 0...0.80`。

画布输出尺寸由 `ScreenshotCanvasPlanner.layout` 决定：先按 `padding × 短边` 四周留白，再按 `aspectRatio` 扩展（**只扩展、不裁切**），源图居中。实现必须复刻这个算法，否则导出尺寸不一致。

### 4.4 `events/segments.json`（0.1）

`timelineStartSeconds` 是去暂停时间轴。`durationSeconds` 为 `null` 表示该分片**正在写入或被中断**——这是崩溃恢复的判据，不能当成 0。

### 4.5 `events/scrolling-capture.json`（0.1）

`frames[].verticalOffsetPixels` 是该帧在长图中的顶部位置，`appendedHeightPixels` 是去重后新增的行数，`overlapDifference` 是被接受的重叠区归一化平均像素差（`0...1`，首帧为 `0`）。

### 4.6 `analysis/ocr.json`（0.1）

`normalizedBounds` 为 `0...1` 左上原点。`fullText` 缺省由 `blocks` 的 `text` 用 `\n` 拼接。

### 4.7 `analysis/transcript.json`（0.1）

`segments` 写入前按 `startSeconds` 升序（相同则按 `endSeconds`）排序，空文本片段被丢弃。`confidence` 钳制 `0...1`。`fullText` 缺省由片段文本用**单个空格**拼接。`isOnDevice` 标记是否设备端识别——Windows 侧用 whisper.cpp 时应为 `true`。

### 4.8 `analysis/insights.json`（当前 0.2，最低可读 0.1）

`tags` 最多 8 条、`keyPoints` 最多 6 条，均按大小写与变音符号不敏感去重后截断。`chapters` 按 `startSeconds` 升序（相同则按 `index`）。

`sensitiveFindings[].redactedPreview` **只保存掩码提示，绝不写入命中的原值**——这是隐私红线，任何实现都必须遵守。

`customization` 是人工校正覆盖层：`resolvedTitle` = `customization.title ?? suggestedTitle`，摘要与标签同理。重新整理只能覆盖生成字段，**不得清除 `customization`**。

## 5. 跨语言实现须知：解码默认值陷阱

这是最容易踩错的地方。多个字段的**「构造时默认值」与「JSON 缺失时的解码默认值」不同**——后者刻意保持旧项目的原有表现，防止新特性偷偷改变老录屏的画面和声音。

用 Rust 的 `#[serde(default)]` 配合 `Default` 实现会**全部踩错**，必须逐字段显式指定缺失时的值。

| 文档 | 字段 | 构造默认 | **JSON 缺失时** | 原因 |
|---|---|---|---|---|
| edit-plan | `cursor.appearance` | `recorded` | **`macOS`** | 旧项目没有录制光标形态 |
| edit-plan | `cursor.appearance`（值无法识别） | — | **`macOS`** | 新版本写的枚举值不能让整个计划解析失败 |
| edit-plan | `cursor.motionEffect` | `halo` | **`none`** | 旧项目不应突然出现光晕 |
| edit-plan | `cursor.smoothing` | — | `0.72` | |
| edit-plan | `cursor.scale` | — | `1.15` | |
| edit-plan | `cursor.hidesWhenIdle` | — | `true` | |
| edit-plan | `interaction.clickPulseColorHex` | `#FF684D` | **`#00D9FF`** | 旧项目保持旧配色 |
| edit-plan | `interaction.clickEffect` | `ripple` | `ripple` | |
| edit-plan | `interaction.showsKeystrokes` | `false` | `false` | |
| edit-plan | `audio.reducesMicrophoneNoise` | `true` | **`false`** | 缺失即 0.6 之前的项目，不能追加降噪 |
| edit-plan | `audio.normalizesLoudness` | `true` | **`false`** | 同上，不能改变旧项目响度 |
| edit-plan | `camera.mode` | — | `"event-driven"` | |
| edit-plan | `camera.zoomIntensity` | — | `0.42` | |
| edit-plan | `camera.motionBlurStrength` | `0`（顶层默认 `0.12`） | `0` | 缺失表示旧项目，保持无模糊 |
| edit-plan | `captions.isEnabled` | `false` | `false` | |
| edit-plan | `presenterCamera.isEnabled` | `false` | `false` | |

另外两条易错点：

1. **`cursor.isEnabled` 是三态。** 类型为 `Bool?`，`null`/缺失在旧项目里表示**启用**，不是禁用。
2. **未知枚举值的处理不统一。** 只有 `cursor.appearance` 做了「未知值回退」；其他枚举遇到无法识别的值会让**整份文档解析失败**，这是有意为之——版本拒绝优于静默丢字段。实现必须复刻这个差异，不要一律宽松。

## 6. 一致性验收

一个非 Swift 实现被认为符合本规范，当且仅当：

1. 能解析 `shared/golden/*.json`（落盘形态）并得到与 Swift 相同的值；
2. 将解析结果按 §1.2 规则重新编码后，与对应的 `*.compact.json` **逐字节相同**；
3. 复刻 §4 的全部钳制范围与派生公式；
4. 复刻 §5 的全部解码默认值；
5. 对高于 `currentVersion` 或格式非法的 `schemaVersion` 返回明确错误，不静默打开；
6. 通过 `Tests/LensCoreTests/Fixtures/` 下 `LegacyRecordingV0_1` 与 `LegacyScreenshotV0_1` 的只读兼容验收。

macOS 侧对应的守卫是 `PortableSchemaGoldenTests`（6 项）与 `ProjectSchemaCompatibilityTests`。Windows 侧应实现同名的等价测试，共用同一批黄金文件。

## 7. 变更流程

任何可移植文档的 schema 变更必须一次性完成：

1. 修改模型并提升其 `currentSchemaVersion`；
2. 运行 `swift run lens-schema-golden` 重新生成 `shared/golden/`；
3. 更新本文与《Lens 开放项目格式》的版本表；
4. 若为破坏性变更，补旧版黄金样本与迁移器；
5. 同步 Windows 侧实现与其一致性测试。

漏掉第 2 步会让 `swift test` 失败——这是刻意的。
