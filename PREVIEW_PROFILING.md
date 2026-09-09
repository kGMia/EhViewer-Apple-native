# 首次预览卡顿：对照采样

## 当前证据

- 用户确认系统菜单的放大/归还动画已连贯，但冷启动后第一次仍卡顿。
- 当前菜单动作状态来自内存集合/字典；自定义预览只读取已解码缩略图缓存，没有直接网络请求或数据库读写。此结论不覆盖 SwiftUI/UIKit 内部工作及并行启动服务。
- 搜索历史面板另有已确认的主线程数据库读写，现已移至 QuickSearchStore actor；这不是首次预览卡顿的已证实原因。
- 已检测到配对 iPhone/iPad；本轮没有安装、重启设备应用或取得首次卡顿的 Instruments trace。因此没有证据判定是哪项系统服务造成卡顿。

## Debug 对照开关

在 Xcode Scheme → Run → Arguments 中一次只启用一个参数。Release 忽略这些参数。

| 参数 | 对照变量 |
| --- | --- |
| 无参数 | 正常功能基线 |
| `-EHPreviewWithoutShare` | 去掉菜单 ShareLink，检查分享桥接是否影响菜单首次初始化 |
| `-EHPreviewSystemSnapshot` | 瀑布流只用默认系统快照，不创建自定义预览 |
| `-EHPreviewStaticTitle` | 保留自定义封面，去掉滚动标题 TimelineView |
| `-EHSkipInteractionWarmup` | 跳过启动时触感/菜单符号预热，检查它是否与首个手势重叠 |

上述均是诊断对照，不是拟发布的功能删减。

## 采样过程

1. 固定设备、构建配置、列表模式和同一张已缓存封面。每组终止应用进程再启动；不要清空图片缓存，以免混入网络差异。
2. 使用 Instruments Time Profiler、Hangs、Points of Interest；测试手势时避免同时使用断点或 LLDB 暂停。
3. 分别在界面稳定后长按第一次、取消、长按第二次。另录一组首屏出现后立即长按，以辨别启动任务重叠。列表和瀑布流分开测。
4. 每组至少重复三次，比较首次与第二次卡顿区间的主线程调用栈和等待原因。只有耗时/调用栈一致变化才据此选定修复方向。
5. 不把 UI 自动化等待时长等同于渲染耗时，不把模拟器结果当作真机结果。

## 已埋点

- `InteractionWarmup`：应用显式预热的实际同步区间。
- `GalleryMenuContentRequested`：SwiftUI 菜单内容 builder 求值。
- `GalleryPreviewBody`：自定义预览 body 求值。
- `GalleryPreviewAppeared` / `GalleryPreviewDisappeared`：预览视图生命周期。

builder/body 求值可能早于实际长按或发生多次；onAppear 也不等于第一帧已经显示。必须结合 Instruments 的主线程和渲染轨道解释，不能只拿两条事件相减作为手势响应时间。

参考：[Apple SwiftUI 性能分析](https://developer.apple.com/documentation/swiftui/performance-analysis)、[使用 Instruments 优化 SwiftUI](https://developer.apple.com/videos/play/wwdc2025/306/)。
