# 实现架构

## 代码边界

```text
frontend/                      本地 HTML / CSS / JavaScript
  app.mjs                      界面状态；只调用显式 Rust 命令
  region.mjs                   透明选区窗口；CSS → 物理像素、向内取整
src-tauri/src/
  main.rs                      Tauri 命令、窗口、作用域、单实例、退出保护
  service.rs                   录制会话、状态机、库、保存和异常编排
  native.rs                    WGC 帧采集、区域裁剪、PNG、原生 H.264 编码
  audio.rs                     WASAPI 系统 loopback / 默认麦克风
  media.rs                     FFmpeg 本地参数化封装、合并和混音
  shortcuts.rs                 两个全局热键；不采集普通键盘文本
crates/lens-core/src/
  model.rs                     manifest / segment / options / phase
  project.rs                   JSON 持久化、版本和路径检查
  timing.rs                    QPC 与帧时码；BGRA 行翻转
  wave.rs                      带时间戳位置的 PCM16 WAV 写入
```

只共享数据合同和未来可以移植的纯逻辑，没有引入 Swift、AppKit 或 ScreenCaptureKit。macOS 原工程未被修改。

## 捕获链路

```text
Windows Graphics Capture 回调
    → 裁剪与 CPU readback
    → BGRA 最新帧槽位（不发往 WebView）
    → 独立编码线程按目标 FPS 取最新帧
    → windows-capture VideoEncoder / Windows Media Transcoding H.264
    → raw/segments/NNNN/video.mp4
```

这是 CPU 交接实现，不是预先规划的完整 Direct3D → GPU encoder 零拷贝实现。静止桌面不依赖 WGC 持续产生新帧：编码线程会按目标帧率重复最后一帧，避免停留画面被时间压缩。

`flip_bgra_rows` 用于满足所选库原始缓冲编码输入的行方向。PNG 使用 WGC 原始方向保存。必须用真实非对称画面验证最终 MP4，没有把纯字节单元测试等同于设备渲染验证。

帧尺寸变化会停止当前分段，而不是直接混合尺寸造成不可预期输出。最大画面尺寸防御性限制在 7680×4320，**这不是性能承诺**。目标 FPS 是编码设置，不代表实际采集达到该速率；首版尚未实现 Mac 版完整捕获健康统计。

捕获侧只有最新帧槽位；第三方编码器内部排队未完成审计。下一阶段需要检查编码背压、RSS 趋势与 GPU 时间，不能凭使用 Rust 声称不会内存增长。

## 同一时间基准

所有音频设备先完成初始化并等待。H.264 编码器就绪后，由编码线程发布 `QueryPerformanceCounter` 转换后的 100ns 时间原点，并开始 CFR 视频时码。

WASAPI 包提供的 100ns 时间戳相对于同一原点映射为 48kHz PCM 帧位置。系统静音期间可能没有音频回调，WAV 中的空隙保留为静音，而不是把后续声音前移。音频在结束时裁齐/补齐到分段视频时长。

字幕、旁白降噪、设备漂移自适应重采样没有在本次实现。音频时间戳错误会停止并保留素材，不默默用错误时码继续。长时间音画同步需要真机测量。

## 暂停、停止和保存

```text
Idle → Starting → Recording → Pausing → Paused → Starting → Recording
                         ↘ Stopping ←─────────────┘
                              ↓
                          Processing → Idle
```

Service 的互斥与显式 Phase 检查拒绝重复操作。耗时工作在阻塞任务线程执行，UI 500ms 获取状态，不把编码工作放到界面线程。暂停真正结束当前分段，继续创建新分段；暂停时间不会追加到输出时间线。

停止先完成采集/编码，再生成分段 screen.mp4，并写入分段有效时长。最终将已完成分段合并，麦克风保持独立 WAV，同时生成带基础混音的 preview.mp4。没有降噪、响度规范化和自动 ducking。

JSON 每个文件使用同目录临时文件、同步和原子替换；**多个文件之间不是事务**。原始 MP4 不是碎片化崩溃安全容器。发生强退时只尝试重新合成已完成分段；活动分段不能保证可播放或恢复。

FFmpeg 超时会终止该子进程并保留源文件，不进行无限重试。低磁盘检查不能保证磁盘耗尽场景最终封装成功。

## 合同兼容

原仓库参考：
- `leolemon777/Lens/Sources/LensCore/LensManifest.swift`：0.9、kind/state、asset role/path、可选字段。
- `leolemon777/Lens/Sources/LensCore/RecordingSegments.swift`：0.1、pause-free timeline。

Windows `createdAt` 写 RFC3339 秒精度，UUID 使用标准格式。未知 manifest 字段保留；未来 schema 拒绝写入。Windows 侧真实媒体和 macOS JSON 日期策略、CAF/MOV 解码、编辑器导入仍需跨平台往返测试。

本版不假装生成 Mac 运镜/编辑计划，不伪造事件轨，不把 Windows 物理像素当作 macOS logical points。窗口来源和开关保存在 `analysis/windows-session.json`；`captureSource` 暂缺失，属于需要补充的跨平台合同工作。

## 安全与权限

原生 API 只解析当前枚举出的来源 ID。用户标题不成为文件名。项目路径禁止绝对路径、盘符、反斜杠、父目录跳转和超出 canonical 根目录的链接。公开前端命令没有通用 shell 或文件路径执行能力。

主界面/选区请求 Windows 排除捕获本窗口，但是否生效需按系统版本和捕获方式验证；失败会提示最小化主窗口。此选项也可能使别的录屏工具无法录到 Lens 自己的窗口。

应用没有自动上传、遥测、云账户、AI API 或网络抓取。项目库仍是普通本地文件，任何具有该用户文件访问权限的程序都可能读取，不宣称加密隔离。
