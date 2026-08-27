# PathShot 代码审计与迁移建议

日期：2026-08-09  
源码：`/Users/wanglizou/Documents/Codex/2026-05-07/mac-claude-cli`

## 当前状态

- PathShot 0.1.0 仍通过 LaunchAgent `local.pathshot` 自动运行；
- 成品路径：`Build/PathShot.app`；
- 完整 Swift Package 源码存在；
- 2026-08-09 重新执行 `swift test`：8 项测试全部通过；
- 当前进程已确认正在运行。

## 可直接迁移的能力

- AppKit 菜单栏常驻结构；
- `Fn + Control` 的 `flagsChanged` 监听与防重复触发思路；
- 每块屏幕一个透明覆盖窗口的多屏捕获结构；
- 选区交互、尺寸提示、Esc 取消；
- Retina 坐标到像素坐标的向外取整和边界裁切；
- 剪贴板图片/路径写入；
- PNG 命名、防覆盖保存；
- 矩形、箭头、画笔、文字、像素化和撤销/重做；
- 核心逻辑与 AppKit 分离并具备单元测试的结构。

## 需要替换或升级

- `CGDisplayCreateImage` 替换为 ScreenCaptureKit 截图管线；
- 单一快捷键管理器升级为可配置动作路由，并加入 `Fn + Space`；
- 截图后必须先进入剪贴板/项目包，标注不再是必经步骤；
- 内存中的破坏性渲染升级为持久化对象标注和非破坏编辑计划；
- 简单 `NSVisualEffectView` 升级为系统原生玻璃、深浅色和辅助功能适配；
- 保存目录升级为 `.lens` 项目包和统一 Lens 库；
- 增加窗口识别、长截图、OCR、贴图、Quick Access 与恢复机制；
- 现有工程不是 Git 仓库，Lens 应建立新的干净仓库，不直接在旧目录继续堆叠。

## 迁移结论

采用“选择性移植”而不是复制整个工程。先移植经过测试的纯逻辑和交互结构，再以 ScreenCaptureKit、开放项目格式和原生 Lens Glass替换旧实现。
