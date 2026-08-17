# 参与贡献 ScreenTrace

感谢你帮助改进屏迹。当前项目处于 macOS Alpha 验收前阶段，优先级是捕获可靠性、原始素材安全、本地隐私、可恢复性和可编辑的非破坏计划。

> 许可：本项目采用 [MIT 许可证](LICENSE)。提交 PR 即表示你同意以相同许可证授权你贡献的代码。

## 开发环境

- macOS 15.2 或更高版本；
- 当前 Xcode 及其 Swift 6 工具链；
- 能够在真机上手动管理屏幕录制、麦克风、摄像头和语音识别权限。

首次验证：

```bash
swift test
bash Scripts/build-app.sh
open Build/ScreenTrace.app
```

Release 严格编译和本地候选包：

```bash
swift build -c release --product ScreenTrace -Xswiftc -warnings-as-errors
bash Scripts/build-release-artifacts.sh
```

本地脚本生成的是 ad-hoc 签名 App，不能代替 Developer ID 签名和 Apple 公证。

## 代码结构

- `Sources/ScreenTraceCore/`：平台无关的开放项目格式、编辑/运镜规划、索引、转写与整理数据结构。
- `Sources/ScreenTraceMac/`：macOS 捕获、权限、媒体渲染与 AppKit/SwiftUI 界面。
- `Tests/`：纯逻辑、AppKit 事件、像素、真实媒体导出和 UI 快照验证。
- `docs/`：产品总计划、格式边界、测试记录与发布门槛。

## 工作方式

1. 用 Issue 说明问题、用户影响、复现步骤和预期结果。安全或隐私问题不要公开附带真实媒体。
2. 保持改动聚焦；项目中所有原始媒体必须保持非破坏性。
3. 先为回归增加可失败的测试，再实现修复。捕获几何、时间映射、编解码和隐私过滤必须有直接断言。
4. 合成媒体优先使用程序生成的色块、棋盘格、正弦波或无敏感内容样本，不要提交个人屏幕、声音、人脸或真实项目包。
5. 修改开放 JSON 格式时提升 schema 版本，对旧文件增加明确的向后兼容测试。
6. 提交前运行全量测试、warnings-as-errors Release 构建和 `git diff --check`。

## 真机验收

自动化工具不能代替 TCC 授权、物理 `Fn` 键、多显示器混合缩放、真实麦克风/摄像头和长时录制。如果 PR 涉及这些路径，请附上：

- macOS 版本、Mac 型号和显示器布局；
- 已授予的权限；
- 实际执行的操作步骤与结果；
- 只含无敏感合成内容的截图或录屏证据。

## Pull Request 要求

- 说明“改了什么”和“为什么”；
- 列出执行过的测试与真机矩阵；
- 说明对隐私、项目格式、性能和无障碍的影响；
- 不包含构建产物、本地项目包、崩溃报告、密钥、公证凭据或个人媒体；
- 当修改 UI 时，增加或更新对应尺寸的快照/像素验证。
