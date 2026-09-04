# Lens 开放项目格式 v0.1

状态：Public Beta 前冻结候选。本文记录当前 App 实际读写的 `.lens` 包，不承诺尚未实现的云服务或 Windows 平台细节。

## 设计约束

- `.lens` 是普通目录包；用户原始截图、录屏、麦克风和摄像头素材位于 `raw/`，自动处理不得覆盖它们。
- `manifest.json` 是唯一入口，所有资产使用相对包根目录的路径；不得写入绝对用户路径。
- 截图/OCR 坐标使用左上角原点；可移植画布位置使用 0...1 归一化坐标；视频编辑、字幕和标注保存源素材时间。
- `analysis/` 与 `previews/` 可重新生成；人工整理校正和 `edits/` 中的非破坏编辑计划属于需要保留的用户数据。
- 读取旧项目不写回任何文件。只有用户明确保存编辑、附加分析结果或完成恢复时，相关文档才允许升级到当前 schema。

## 目录结构

```text
Example.lens/
├── manifest.json
├── raw/
│   ├── screenshot.png | screen.mp4
│   ├── microphone.caf
│   ├── camera.mov
│   ├── segments/
│   └── scrolling/
├── events/
│   ├── pointer.jsonl
│   ├── clicks.jsonl
│   ├── keyboard.jsonl
│   ├── windows.jsonl
│   ├── segments.json
│   └── scrolling-capture.json
├── analysis/
│   ├── ocr.json
│   ├── transcript.json
│   └── insights.json
├── edits/
│   ├── screenshot-edit.json
│   └── edit-plan.json
└── previews/
    ├── screenshot.png
    └── auto.mp4
```

不存在的可选文件表示对应能力没有运行或没有启用；不能据此删除其他资产。事件 JSONL 采用每行一个 JSON 对象，键盘事件只记录经过隐私收敛的快捷键和非文本控制键，不记录普通文字输入。

## 可移植 JSON 文档版本

| 文档 | 路径 | 最低可读 | 当前写入 | 说明 |
|---|---|---:|---:|---|
| Manifest | `manifest.json` | 0.1 | 0.9 | 类型、状态、尺寸、来源和资产索引 |
| 自动编辑计划 | `edits/edit-plan.json` | 0.1 | 1.3 | 运镜、光标形态/拖动状态与特效、音频、画中画、时间线、字幕、标注和导出意图 |
| 截图编辑计划 | `edits/screenshot-edit.json` | 0.2 | 0.3 | 对象化标注与非破坏画布样式 |
| 录制分片索引 | `events/segments.json` | 0.1 | 0.1 | 暂停无关时间线与三轨分片 |
| 长截图计划 | `events/scrolling-capture.json` | 0.1 | 0.1 | 源帧、重叠结果与纵向放置 |
| OCR | `analysis/ocr.json` | 0.1 | 0.1 | 文本、置信度与归一化位置 |
| 转写 | `analysis/transcript.json` | 0.1 | 0.1 | 引擎、语言、设备端标记与源时间片段 |
| 整理结果 | `analysis/insights.json` | 0.1 | 0.2 | 标题、摘要、标签、章节、脱敏提示与人工校正层 |

源码中的 `LensProjectSchema.portableDocuments` 是这张表的可执行权威来源，测试会校验它与各模型的 `currentSchemaVersion` 一致。`shared/golden/schema-registry.json` 是同一张表的机器可读镜像，供非 Swift 实现读取，`PortableSchemaGoldenTests` 校验两者一致。`.index/library-v1.json` 是可删除重建的本机缓存，不属于开放项目格式。

字段级定义、编码约定和跨语言实现须知见《[Lens 可移植文档字段规范](Lens-可移植文档字段规范-v1.md)》。

## 兼容规则

1. 版本严格使用 `主版本.次版本` 两段十进制格式。
2. 当前读取器只接受上表列出的闭区间；无法解析或高于当前版本的文档会返回明确错误，不能静默打开后丢字段。
3. 同一可读区间内新增字段必须提供安全默认值；缺失的新效果不能改变旧项目原有画质、声音或时间线。
4. 支持区间内的 JSON 允许出现附加未知字段，读取器会忽略它们；当前 App 重写同一文档时不承诺保留无法理解的字段，因此扩展工具应使用独立命名文件或先推动 schema 升级。当前 App 不会在未知 schema 上继续编辑。
5. 原始媒体始终是恢复锚点。索引、OCR、转写、整理或预览损坏时只能重建派生层，不能删除 `raw/`。
6. schema 升级必须同时更新模型常量、中央注册表、本文、旧版黄金样本/测试和 Windows/Rust 黄金一致性数据。

## 黄金兼容样本

仓库在 `Tests/LensCoreTests/Fixtures/` 保留两个不含真实媒体的最小项目：

- `LegacyRecordingV0_1`：Manifest 0.1、自动编辑 0.1、分片 0.1、转写 0.1、整理 0.1。
- `LegacyScreenshotV0_1`：Manifest 0.1、截图编辑 0.2、OCR 0.1、长截图计划 0.1。

`ProjectSchemaCompatibilityTests` 将样本复制到临时 `.lens` 包后，通过真实 `LensProjectStore` 逐项读取，比较读取前后的全部文件字节，并验证未来/畸形版本被拒绝且不会进入 Lens 库。样本不包含图片、音视频或用户数据。

## 仍需冻结的 1.0 边界

- Public Beta 反馈可能要求在 1.0 前增加字段；只允许向后兼容的可选字段，破坏性变化必须提升 schema 并提供迁移器。
- Rust worker 与 Windows 平台层必须复用这里的相对路径、坐标、源时间和版本拒绝规则，并加入跨语言黄金样本一致性测试。
- 1.0 发布后，项目格式变更必须提供升级说明、旧版读取测试和回滚策略。
