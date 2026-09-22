# OS 27 适配记录

日期：2026-09-16。

## 基线

- 本机 macOS 27.0，Xcode 27.0（27A266a），iOS/iPadOS/macOS SDK 27.0。
- 保留用户已有的 Xcode 工程升级和主应用最低版本 27.0 设置；将 Live Activity 扩展及 iOS/macOS 测试目标最低版本对齐。
- 主工程仍为 Swift 5 语言模式，本轮没有进行全项目 Swift 6 迁移。

## 已调整

1. 后台调度使用 submitTaskRequest 异步 API，构造和提交在 utility 任务中完成，保留错误处理。SDK 头文件要求避免在主线程或性能关键路径调用。
2. ActivityKit 属性及 ContentState 明确为非隔离值类型，消除新 SDK 下跨并发上下文使用协议实现的诊断。
3. 动图、预览滚动标题和悬浮滚动标题响应 systemPrefersReducedResourceUsage；保留离屏、后台和减弱动态效果规则。
4. 设置导出使用当前窗口的 SwiftUI fileExporter，移除任意 connectedScene/rootViewController 查找及 macOS 阻塞保存面板。
5. 后台调度日志使用非隔离、无共享可变状态的日志函数。
6. 预览跳页控件统一采用 SwiftUI regular.interactive 玻璃并遵循减弱动态效果；已移除试验性的 AppKit 背景桥接。展开与收起共享玻璃过渡，macOS 高度 32 pt、移动端 44 pt。系统透明度联动尚需视觉确认。

## 验证与边界

- 已检查 iOS 构建产物：SDK 27.0、最低系统 27.0、设备类型包含 iPhone/iPad，存在 UILaunchScreen 和 UIApplicationSceneManifest。
- 最终 iOS/iPadOS 27 与 macOS 27 Debug 构建通过，macOS 27 上三个滚动锚点回归测试通过。
- 构建日志：/tmp/ehviewer-os27-ios-final.log、/tmp/ehviewer-os27-macos-final.log；测试日志：/tmp/ehviewer-os27-macos.log。
- 未完成 iPhone/iPad 真机 UI 验收，也未验证后台调度的实际系统执行时机；后者由系统决定。
- 搜索玻璃、预览抬起/归还、iPad 窗口缩放、设置文件导出及首次预览卡顿需要运行验证。编译通过不代表这些行为全部验证。
- 2026-09-22 用户补充：预览控件不跟随系统 Liquid Glass 透明度调整的问题仅存在于 macOS；iOS 卡顿未复现，iPadOS 在第一次 build 后开启出现卡顿，随后未复现。移动端卡顿保留为偶发待定位，不能据此认定缓存、SDK 或调试器是原因；后续优先处理 macOS 透明度问题。
- 先前报告的数据库、解析器和网络编译警告已清理；测试目标可能仍输出 App Intents 元数据提示。

## 官方依据

- [iOS/iPadOS 27 发布说明](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- [场景生命周期迁移要求](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)
- [macOS 27 发布说明](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
- 新 API 签名和可用性同时依据本机 iOS 27 SDK 的 BackgroundTasks 头文件及 SwiftUI swiftinterface 核对。
