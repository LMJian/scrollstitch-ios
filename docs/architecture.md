# 代码结构

| 模块 | 主要入口 | 负责内容 |
| --- | --- | --- |
| App | `ScrollStitchApp`、`ScrollCaptureHome`、`CollageWorkspace`、`WorkdayAlarmViews` | 三个功能的导航和交互 |
| 控制与原生采集 | `Controls/`、`Shared/`、`ScrollCaptureCoordinator`、`ScrollNativeCapture` | App Intent、控制中心、Live Activity、ScreenCaptureKit 生命周期 |
| Core | `Sources/ScrollStitchCore/` | 文件事务、状态机、编辑、导出记录、年度规则和排程协调 |
| Imaging | `Sources/ScrollStitchImaging/` | 图片校验、布局、拼接、渲染 |
| 验证 | `Tests/`、`Tools/`、`scripts/` | 合成场景、真实生产 API 测试、可选外部素材回放、构建检查 |

## 滚动截图数据路径

`ScrollCaptureCoordinator` 持有会话，不依赖视图存活。`ScrollNativeCapture` 通过系统全屏共享选取屏幕，串行接收 ScreenCaptureKit 帧；只接收屏幕，不接收音频。`ScrollFrameArchive` 按采样间隔写入 JPEG、时间戳及显式换页边界，忽略本 App 前台画面，封存后才交给计算。

`CapturePipeline` 校验输入和版本，调用 `FrameStitcher`。预处理、重叠估计、水平表格匹配和位置去重共同决定输出；渲染分块受资源预算限制。成功输出写为不可变图片，通过 `CaptureResultSet` 原子发布。重试只复用完整结果，失败结果重新计算。照片保存使用持久化账本，逐张保存，已成功项跳过，不确定项停止。

App Group 下 `Library/ScrollStitch/scrolls/<session>` 为每次滚动截图保存独立 TaskStore。会话已标记保存、完整结果的每一页都在 Photos 写入账本中确认成功，且账本没有待确认写入时，TaskStore 持有采集与导出锁，归档结果描述并移除本地图片、采集素材和派生缓存。保留会话和写入账本，清理中断后可继续。打开 App 时按同样条件检查旧缓存。系统录制中断、保存失败或记录不足时保留素材。

## 拼图数据路径

`PickerBatchLoader` → `ImageImporter` → `TaskStore` 导入事务 → `EditSnapshot` → `LayoutEngine` → `ImageRenderer` → `ResultManifest` → `PhotoExportController` / 系统分享。

`TaskStore` 使用文件锁、原子写入、版本检查和占用租约，防止旧任务覆盖新编辑或清理仍在使用的文件。渲染不复制原图 EXIF/GPS 字典。Photos 保存意图先落盘，再写入相册并记录完成；未确认完成的写入不会自动重试。

## 闹钟数据路径

`WorkdayAlarmService` 负责 App 生命周期和 UI；`WorkdayHolidayStore` 在内置与缓存中逐年选最高有效版本。HTTPS 下载索引及不可变年度文件，完成校验后原子替换缓存；失败保留旧版本。

`WorkdayPlanner` 计算未来 90 天最近 64 个事件。`WorkdayAlarmEngine` 持久化规则和事件所有权，撤销过期配置、调用 `WorkdayAlarmSystem`、回读系统实际状态。原生实现是 `NativeWorkdayAlarmSystem`，测试使用替身。事件使用稳定 ID；停止回调标记消费并补齐未来排程。后台刷新只提供额外补齐机会。

核对前先读取系统排程，仅清理已确认不存在的历史归属，再合并新计划并检查 1024 条上限。读取失败时保留未确认归属。后续取消和补排前仍先持久化归属，操作后再次回读，支持归属达到上限后的跨日恢复。

## 构建边界

Xcode 项目由 `scripts/generate_project.py` 生成。开发版和 Store 版均嵌入 `ScrollControls`，保留滚动截图、拼图、AlarmKit 与随包年度数据。Store 模式通过 `SCROLLSTITCH_STORE` 关闭内部操作工具，主 App 与扩展版本一致；不会依据启动参数或偏好开启内部入口。Swift Package 在 macOS 上验证 Core/Imaging，不代表 iPhone 系统授权、后台执行或实际响铃通过。
