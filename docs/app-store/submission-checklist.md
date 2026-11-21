# 上架材料交接清单

更新日期为 2026-11-21，当前准备版本为三功能完整版 1.0.0（1），免费、中国大陆、iPhone / iOS 27+，审核后手动发布。

## 已准备

- 简体中文名称、副标题、分类、关键词、宣传文本和完整描述，见 `metadata.zh-Hans.json` 与 `description.zh-Hans.txt`。
- 中英审核说明，包含控制中心截图、相册查看、多图拼接和左上角添加闹钟的操作路径，见 `review-notes.md`。
- 隐私问卷、分级及素材权利依据，见 `privacy-answers.md`、`compliance.md`。
- 中国大陆备案适用性与个人主体办理材料，见 `filing-preparation.md`。适用性咨询已通过 Apple 官方支持提交并取得回执，等待回复。
- 当前 Store 界面 8 张 1320×2868 RGB PNG，实际选图和生成的自制素材，见 `screenshots.md`。
- 1024×1024 应用图标，源文件为 `Resources/Branding/AppIcon.png`。
- 支持、隐私和介绍页的当前静态 HTML，位于 `site/`。
- 截图源版本为 `6256d89`，后续算法修正与主流程约束已推送至 `origin/main`。网站 `e114bd8` 已部署，三个公开 URL 均 HTTP 200 且正文匹配当前源码。
- 当前真机一次后台响铃通过，用户确认听到。测试闹钟和临时工具已清理，详见 [当前真机记录](device-acceptance-2026-11-20.md)。

截图、图标副本、文字材料及文件摘要组成的交付包保留在本地 `.artifacts/release-20261120/`。私人电话、身份材料、开发签名和设备备份分别保留在私有目录。

## 后台已完成

- 付费会员已启用，卷轴 App 记录已创建，Apple ID `6837656155`。
- Apple 分发签名导出、主 App 与扩展实际共享组授权检查、上传、处理完成及选择 1.0.0（1）。上传源码提交为 `1b44b8b`。
- 商品文案、审核说明与私有联系人已保存，4+ 分级、内容版权声明和大陆 AIGC／安全评估适用性声明已填报。
- 原始大屏截图 8 张已上传并读回。隐私政策 URL 已保存，隐私标签经用户授权发布。
- 免费，中国大陆单一供应范围，Mac 和 Vision Pro 提供选项关闭，版本采用手动发布。
- Apple 接受将该版本加入审核草稿，状态为“可供审核”。

## 正式提交前待完成

1. 等待大陆备案适用性咨询结论。官方支持仍列为未结案例，当前未取得备案号或豁免结论，后台允许创建审核草稿不能代替备案适用性结论。
2. 在已准备的审核草稿执行正式提交，后续处理 Apple 审核反馈。审核通过后由提交人手动发布。
3. 后续向现有手机更新首次上架身份前，按用户决定备份并确认新共享组的数据迁移。此项按安装需求处理。

滚动截图继续使用用户确认的唯一主流程，见 AGENTS.md。本地回归、用户实际使用确认与历史真机证据按各自范围保留。

Apple 要求适用的 ICP 备案信息与工信部记录一致，最终以账户中的适用字段及核验结果为准。[Apple App 信息规则](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

截图采用当前官方大屏尺寸。自 2027 年 4 月起，使用 iOS 27.1 SDK 或更新版本提交时还需 iPhone Duo 截图。[Apple 截图规范](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
