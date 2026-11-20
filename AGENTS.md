# ScrollStitch contributor rules

## 用户确认的滚动截图路径与验收边界

用户于 2026-11-20 明确确认以下唯一主流程。开发、使用说明、上架材料和验收均以此为准。

1. 打开要截取内容的目标 App，停在内容起点。
2. 打开控制中心，点击「卷轴」开始截图。
3. 在 Apple 系统面板确认「共享整个屏幕」，收起系统面板，返回目标内容。
4. 沿选定方向滚动需要截取的内容。
5. 点击或展开灵动岛中的卷轴实时活动，点击「完成」停止截图。
6. 卷轴自动整理并保存到系统「照片」，在相册查看成品。

- 用户已确认自己使用上述流程没有问题。不得因准备上架而默认要求用户重新测试已确认可用的流程。
- 不得擅自改用「再次打开控制中心停止截图」或其他结束方式进行验收，也不得扩展这些路径的适配、兼容或测试矩阵。只有用户明确提出该路径的问题或明确要求支持时，才可纳入范围。
- 其他路径的测试失败不得自动升级为上述主流程或 App Store 提交的阻塞项。报告必须写明实际操作路径及证据范围。
- 主流程出现具体问题时，先留存输入，在 Mac 上复现、修复并补自动化回归。不得反复占用用户手机排查算法。
- 必须使用手机时，先说明具体问题、操作步骤、必要性及总占用时限，并取得本次明确授权。累计遵守约定时限，超时前结束并释放手机，不得自行延长、重置计时或扩大路径。
- 用户确认的实际使用结果、本地自动化、文件回放与本轮真机操作应分别记录。未经执行的步骤不得写成通过，也不得通过扩大验收范围反复向用户索要测试。

## Project rules

- Use the current branch by default. Do not create or switch development branches, detached checkouts, or worktrees without the user's explicit request or consent.
- Harness owns agent workflow state. Store only portable commands in `.harness/project.json`; keep runs, logs, generated evidence and worktrees ignored. Use a fresh review task for new work; do not reuse historical acceptance as current proof.
- Before Computer Use or GUI automation, describe purpose and scope and obtain explicit approval for that task. CLI builds, local file checks and API requests are separate. Do not launch Xcode, a simulator or phone automation indirectly through scripts without GUI approval.
- Preserve App identity, App Group, existing works and uncertain Photos write records. Device installation requires task-specific authorization; back up and verify existing device data before an authorized update. Explicit user requests to delete local backups override retention for those backups only.
- Both editions require iOS 27+ and ScreenCaptureKit. The user approved the full App Store edition on 2026-10-27: capture, collage and workday alarms. `ScrollStitchStore` disables operator tools while retaining all three features and the control extension. Do not reintroduce ReplayKit or legacy capture entry points.
- Capture is single-session, processes images locally and retains no audio. Normal completion must reconstruct complete content and save automatically. Do not require frame selection, cropping or manual seam repair. Never automatically repeat an uncertain Photos write.
- Keep annual data updates atomic and verified. Alarm time is Asia/Shanghai; report system-confirmed coverage and missing years honestly. Do not claim indefinite offline replenishment.
- Update code, current documentation and meaningful tests together. Use README and docs/testing.md commands. Compilation, file replay, mocked scheduling, actual device ringing and Store publication are distinct evidence layers.
- Never publish local signing configuration, credentials, private recordings, works backups, device identifiers, logs, build caches or Harness state. Check the Git index as well as `.gitignore`.
