# Lens Windows 平台接口与日志契约 v1

面向在 Windows 上用 Rust 实现 Lens 的人。

## 0. 这份文档管什么

已有文档划分：

| 文档 | 管什么 |
|---|---|
| [开放项目格式](Lens-开放项目格式-v0.1.md) | `.lens` 目录结构、兼容规则 |
| [可移植文档字段规范](Lens-可移植文档字段规范-v1.md) | 字段语义、钳制范围、解码默认值陷阱 |
| [核心工作进程协议](Lens-核心工作进程协议-v0.1.md) | 跨进程 worker 的帧格式 |
| [Windows 移植计划](Lens-Windows-移植计划-v1.md) | 里程碑、技术选型 |
| **本文档** | **两侧必须行为一致的纯策略，以及诊断日志的逐字段契约** |

上面四份说的是"数据长什么样"。这份说的是"**行为必须一样的那部分逻辑长什么样**"——它们不碰任何平台 API，却决定了用户能不能观察到两个平台行为一致。写 Rust 的时候，这些不是"参考实现"，是**规范**。

> **关于本文档里的 Rust 代码**：这台开发机没有 Rust 工具链，下面所有 Rust 签名都**未经编译验证**，是签名草案，用来固定语义而不是拿来直接粘贴。以 Swift 侧的行为描述为准；签名对不上就改签名，别改行为。

---

## 1. 必须逐位一致的纯策略

这五块在 macOS 侧都是零平台依赖的纯逻辑。Rust 侧重新实现时，**可观察行为必须完全一致**，包括边界情况。

### 1.1 任务身份与去重（`RecordingTaskCoordinator`）

参考实现：[`Sources/LensMac/Support/RecordingTaskCoordinator.swift`](../Sources/LensMac/Support/RecordingTaskCoordinator.swift)

录制结束后的渲染、转写、整理、恢复四类任务共用一套身份规则。

**键** = `(标准化后的包路径, 任务种类)`。注意**不含版本号**——版本是用来判断"取代"的，不是键的一部分。

```rust
pub enum TaskKind { Render, Transcription, Organization, Recovery }

pub enum TaskPhase {
    Queued, AudioPreparation, Transcription, Organization,
    Effects, Verification, Publishing, Completed, Cancelled, Failed,
}

pub enum TaskOutcome { Completed, Cancelled, Failed }

pub enum CancellationReason {
    Superseded,           // 被更新版本取代
    OperationCancelled,   // 任务自身被取消
    PackageGateUnavailable, // 抢不到包级串行闸门
    UserRequested,        // 用户主动取消
}

pub enum TaskPriority {
    Background = 0,
    UserInitiated = 50,
    RecordingFinalization = 100,
}
```

**必须一致的行为**：

1. 相同 `(包, 种类, 版本)` 且尚无结果 → **复用同一个 token**，返回"不是新任务"。调用方据此**不得**再跑一遍闭包。这是防止同一批媒体文件被两个 worker 同时读写的唯一防线。
2. 相同 `(包, 种类)` 但版本不同 → 旧任务立刻以 `Cancelled` / `Superseded` 记入历史，然后建新 token。
3. `advance(token, phase)`：只在 `token` 匹配且尚无结果时生效。**首次进入非 `Queued` 阶段时才写入 `started_at`**——排队时间和执行时间由此分开。
4. `finish(token, outcome, reason)`：`cancellation_reason` **仅在 `outcome == Cancelled` 时保留**，其余情况必须清空。阶段由结果推导（`Completed`/`Cancelled`/`Failed`）。
5. 历史上限 **100 条**，超出从头部丢弃。
6. `active_snapshots()` 排序：**优先级降序，同优先级按入队时间升序**。
7. `snapshot(包, 种类, 版本)`：先查活跃表（要求版本匹配），未命中则**倒序**查历史取第一个匹配。

**计时口径**（会进日志，必须一致）：

- `queue_ms = max((started_at - queued_at) * 1000, 0)`，`started_at` 为空时不产出
- `execution_ms = max((finished_at - started_at) * 1000, 0)`，两者任一为空时不产出

### 1.2 准入策略（`RecordingTaskSchedulingPolicy`）

纯函数，**判定顺序不能变**：

```rust
pub enum Admission { Start, DeferredWhileRecording, AlreadyQueued, AtCapacity }

pub fn admission(
    priority: TaskPriority,
    while_recording: bool,
    is_active: bool,
    is_pending: bool,
    active_count: usize,
    max_concurrent: usize, // 转写固定为 1
) -> Admission {
    if is_active || is_pending { return Admission::AlreadyQueued; }
    if while_recording && priority < TaskPriority::RecordingFinalization {
        return Admission::DeferredWhileRecording;
    }
    if active_count >= max_concurrent { return Admission::AtCapacity; }
    Admission::Start
}
```

要点：

- **录制期间只有 `RecordingFinalization` 能跑**。这是为了不和录制抢 CPU/磁盘。
- **设备端转写并发上限固定为 1**。Windows 侧用 `whisper-rs` 同理——多个模型实例互抢会让两个都变慢。
- 顺序重要：已在队列里的请求**先于**"录制中延后"返回，否则同一个请求会被反复排队。

### 1.3 包级串行闸门（`RecordingProcessingGate`）

参考实现：[`Sources/LensMac/Support/RecordingProcessingGate.swift`](../Sources/LensMac/Support/RecordingProcessingGate.swift)

**不同包互不阻塞，同一个包严格串行。**

两条容易写错的规则：

1. **释放时把钥匙直接交给队首等待者，而不是先放回池子再让大家抢。** 否则"释放后立刻重新获取"的调用方会插队到已排队者前面。
2. **被取消的等待者直接以 `false` 返回，不消耗名额。** 否则一个被取消的渲染会把后面所有任务永久堵死。

macOS 侧用 actor + continuation 实现。Rust 侧建议 `tokio::sync::Mutex` 管状态 + 每个等待者一个 `oneshot`，语义对齐即可：

```rust
impl ProcessingGate {
    pub async fn acquire(&self, key: &Path) -> bool; // false = 已取消，未持有
    pub async fn release(&self, key: &Path);
}
```

> 这里原本是 120 ms 轮询，改成了让出式等待。Windows 侧别退回轮询——录制期间占着 CPU 轮询会直接影响掉帧。

### 1.4 存储保护集（`ActiveStoragePackagePolicy`）

参考实现：[`Sources/LensMac/Support/LensStorageMigrationQueue.swift`](../Sources/LensMac/Support/LensStorageMigrationQueue.swift)

**这一条是从一个真实 bug 里长出来的，Windows 侧照抄结论就能少踩一次。**

同一个"正在写入的包"集合被两个调用方使用，但**匹配规则不同**：

| 调用方 | 怎么用这个集合 |
|---|---|
| 迁移闸门 | 只判断**是否为空**。非空就延后迁移。 |
| 临时文件清理 | 拿每个临时文件**所属的包**去集合里精确匹配。 |

于是：**能报出自己包路径的写入方，必须贡献真实路径**。只塞一个哨兵值能骗过迁移闸门，但对清理等于没保护——清理会把这个包正在写的暂存文件删掉。

哨兵只留给**报不出包路径**的忙碌状态：截图捕获还没发布包、素材库窗口只是钉住存储根目录。

```rust
pub const UNNAMED_WRITE_SENTINEL: &str = ".lens-storage-write-active";

pub fn resolve_active_packages(
    root: &Path,
    task_packages: &[PathBuf],      // 各任务注册表里的真实包
    editing_packages: &[Option<PathBuf>], // 编辑器持有的真实包
    has_unnamed_write: bool,        // 捕获中 / 库窗口可见 / 录制中
) -> HashSet<PathBuf>
```

### 1.5 存储分类（`LensStorageManager`）

参考实现：[`Sources/LensCore/LensStorageManager.swift`](../Sources/LensCore/LensStorageManager.swift)

路径 → 分类的判定表。**清理只允许动 `Temporary`。**

包**外**（相对存储根）：

| 路径 | 分类 |
|---|---|
| `.index/…` | `Index` |
| 其余 | `Other` |

包**内**（相对包根）：

| 首段 | 细则 | 分类 |
|---|---|---|
| `raw/…` | — | `Source` |
| `previews/<名>` | `<名>` 命中临时前缀表 | `Temporary` |
| `previews/narration-draft.caf` | — | `Rebuildable` |
| `previews/auto.mp4`、`previews/annotated.png` | — | `Rendered` |
| `previews/…` | 其余 | `Derived` |
| `events/`、`analysis/`、`edits/`、`diagnostics/` | — | `Derived` |
| `manifest.json` | — | `Derived` |
| 其余 | — | `Other` |

**临时前缀表**（前缀匹配，共 9 项）：

```
.auto-  .audio-mix-  .auto-mixed-  .timeline-transitions-
.screen-effects-  .system-transitions-  .conditioned-microphone-
.microphone-transitions-  .g3-mixed-
```

清理时若某项**拿不到所属包路径**（`package_relative_path` 为空），必须**跳过而不是删除**。

**贯穿性不变量：原始素材永不改写。** `raw/` 下的任何文件在任何路径下都不得被修改或删除，迁移也只复制不删源。

---

## 2. 诊断日志契约

参考实现：[`DiagnosticEvent.swift`](../Sources/LensCore/DiagnosticEvent.swift) / [`LocalDiagnosticLog.swift`](../Sources/LensMac/Support/LocalDiagnosticLog.swift)

这是**隐私边界**，不是调试便利设施。Windows 侧必须逐条对齐，否则同一个产品在两个平台上的隐私承诺不一致。

### 2.1 落盘形态

- 格式：**JSONL**，一行一个事件，行尾 `\n`（`0x0A`）
- 位置：应用数据目录下 `Lens/diagnostics/`
  - macOS：`~/Library/Application Support/Lens/diagnostics/`
  - Windows 建议：`%APPDATA%\Lens\diagnostics\`
- 文件：`events.jsonl`（当前）+ `events.previous.jsonl`（上一轮），**只有这两个**
- 轮转：写入前若 `当前大小 + 本次字节数 > 512 KiB`，则删除 `previous`、把 `active` 改名为 `previous`。上限下探保护为 256 字节。
- 读取近期事件：`previous` + `active` 合并，**按时间戳升序排序**后取末尾 N 条

### 2.2 事件结构

```jsonc
{"code":"task.render.completed","level":"info","metadata":{"executionMilliseconds":"8420","phase":"completed","queueMilliseconds":"12","taskKind":"render","taskOutcome":"completed"},"timestamp":"2026-09-08T12:34:56Z"}
```

四个字段，**键名排序输出**，时间戳 **ISO 8601**，**不转义斜杠**。`metadata` 缺失时按空表解码。

`level` 三档：`info` / `warning` / `error`。

### 2.3 白名单（最关键的一条）

**`metadata` 的键必须在白名单内，不在的静默丢弃。** 当前 26 个键：

```
appVersion            averageMilliseconds   build
cancellationReason    captureMode           count
durationMilliseconds  errorCode             errorDomain
eventCaptureMode      eventStatus           executionMilliseconds
frameRate             intent                maximumMilliseconds
measuredFrameRate     phase                 queueMilliseconds
renderEncodePassCount renderMilliseconds    renderPeakPhysicalFootprintBytes
status                storageLevel          taskKind
taskOutcome           totalMilliseconds     videoStatus
```

新增键要**同时**改两侧并更新本表。白名单是"默认拒绝"，加字段是有意识的动作。

### 2.4 清洗规则（两套，别混）

**`code`（事件码）**：

- 允许字符：字母、数字、`.`、`_`、`-`
- 先截断到 **80 个 Unicode 标量**，再逐字符替换非法字符为 `_`
- 结果为空 → 回退为 `diagnostic.invalid_code`

**`metadata` 的值**：

- 先去首尾空白
- 空、长度 > 80、或**含任何非法字符** → **整个键值对丢弃**（注意：不是替换成 `_`，是丢掉）
- 允许字符集同上

这个差异是有意的：事件码丢了就没法归类，值不干净则宁可不要。

### 2.5 事件码命名

`<域>.<动作>` 或 `<域>.<子域>.<动作>`，全小写蛇形。现有域：

```
app.*         应用生命周期      app.launched / app.previous_session_unclean
task.*        后处理任务        task.<kind>.<outcome>
preview.*     渲染与成片        preview.completed / preview.failed / preview.effects_verified
recording.*   录制              recording.failed / recording.processing_resume_detected
organization.*  本地整理        organization.completed / organization.failed
library.*     素材库加载        library.manifest_load_failed
ocr.*         文字识别          ocr.failed
storage.*     存储管理
hotkey.*      快捷键            hotkey.registration_fallback
crash_reports.*  崩溃指纹
onboarding.*  首次启动
```

任务完成事件由统一的上报器生成，格式固定：

- 事件码：`task.<kind>.<outcome>`
- 级别：`outcome == failed` → `warning`，否则 `info`
- metadata：`taskKind`、`taskOutcome`、`phase`，外加可选的 `cancellationReason`、`queueMilliseconds`、`executionMilliseconds`
- 毫秒值格式化为**无小数点的整数字符串**

### 2.6 绝对不能进日志的东西

```
截图 / 录屏 / 音频的任何内容或片段
转写正文、OCR 正文、整理摘要正文
窗口标题、应用内文档名
文件路径、项目路径、用户名
调用栈、崩溃时的内存内容
任何自由文本形式的错误描述
```

错误只能以 `errorDomain` + `errorCode` 两个受清洗的标识符出现。Windows 侧对应：`errorDomain` 用稳定的模块标识（如 `lens.capture`、`windows.graphics.capture`），`errorCode` 用 `HRESULT` 的十进制或十六进制字符串——**不要**把 `FormatMessage` 的结果写进去，那是本地化自由文本。

诊断摘要末尾必须原样保留这句承诺：

> 隐私：不包含截图、录屏、声音、转写正文、窗口标题或项目路径。

### 2.7 系统日志

macOS 侧同时向 `os.Logger`（`subsystem = "app.lens"`）打一条，**只打事件码，且标记为 public**——不打 metadata。Windows 侧对应 ETW 或 `tracing`，同样只输出事件码。

---

## 3. 建议的 crate 划分

`lens-format` 已存在（里程碑 0）。上面这些策略建议放在一个同样零平台依赖的新 crate，这样它能和 `lens-format` 一样在**任何机器上**开发和测试，不必等 Windows 环境：

```
windows/crates/
├── lens-format/     .lens 读写            ← 已有
├── lens-policy/     本文档第 1 节的五块策略  ← 建议新增，纯逻辑
├── lens-diagnostics/ 本文档第 2 节的日志    ← 建议新增，纯逻辑
├── lens-capture/    Windows.Graphics.Capture + WASAPI
├── lens-render/     Skia + FFmpeg
└── lens-app/        Tauri 外壳 + 原生浮层
```

把策略和日志放进纯逻辑 crate 的理由和 `lens-format` 一样：**它们是最容易出隐蔽 bug、又最容易测的部分。** 第 1.4 节那个 bug 就属于"纯逻辑测试全绿、接线处出错"，放在能大量写单元测试的地方能显著降低复发概率。

---

## 4. 怎么证明两侧一致

`lens-format` 靠 `shared/golden/` 的逐字节比对。本文档这两部分建议同样做成可比对的产物：

**策略**——用状态机轨迹。给定一串操作，两侧应产出相同的快照序列：

```jsonc
// 建议放 shared/golden/task-coordinator-trace.json
{
  "operations": [
    {"op": "begin", "package": "A.lens", "kind": "render", "version": "v1", "priority": "recordingFinalization"},
    {"op": "advance", "phase": "effects"},
    {"op": "begin", "package": "A.lens", "kind": "render", "version": "v2", "priority": "recordingFinalization"}
  ],
  "expectedHistory": [
    {"kind": "render", "version": "v1", "outcome": "cancelled", "cancellationReason": "superseded"}
  ]
}
```

**日志**——用清洗前后的对照表，覆盖各类边界：非法字符、超 80 字符、空值、白名单外的键、空 code。两侧喂同一份输入，输出应逐字节相同。

```jsonc
// 建议放 shared/golden/diagnostic-sanitizer-cases.json
[
  {"in": {"code": "task.render.completed", "metadata": {"taskKind": "render", "windowTitle": "机密文档"}},
   "out": {"code": "task.render.completed", "metadata": {"taskKind": "render"}}},
  {"in": {"code": "", "metadata": {}},
   "out": {"code": "diagnostic.invalid_code", "metadata": {}}},
  {"in": {"code": "a b/c", "metadata": {"status": "ok done"}},
   "out": {"code": "a_b_c", "metadata": {}}}
]
```

这两份黄金文件**还没有生成**。做的时候两侧都要接进各自的测试，否则一致性只是口头承诺。

---

## 5. 在 Windows 上起步

```powershell
# 装 Rust（Windows 用 rustup-init.exe，或 winget）
winget install Rustlang.Rustup
```

```powershell
cd windows
cargo test
```

**第一件事是让 `cargo test` 在 `lens-format` 上跑绿。** 它到今天为止一次都没编译过——代码是在没有工具链的 macOS 上写的，先当它有编译错误来对待，而不是当它已经能用。

跑绿之后的建议顺序：

1. `lens-format` 通过 `shared/golden/` 全部比对
2. 按第 1 节实现 `lens-policy`，补第 4 节的轨迹黄金文件，两侧对齐
3. 按第 2 节实现 `lens-diagnostics`，补清洗对照表，两侧对齐
4. 再进 `lens-capture`——到这一步才真正需要 Windows API

前三步都不碰 Windows API，在哪台机器上都能做。
