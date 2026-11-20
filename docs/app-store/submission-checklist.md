# 上架材料交接清单

更新日期为 2026-11-20，当前准备版本为三功能完整版 1.0.0（1），免费、中国大陆、iPhone / iOS 27+，审核后手动发布。

## 已准备

- 简体中文名称、副标题、分类、关键词、宣传文本和完整描述，见 `metadata.zh-Hans.json` 与 `description.zh-Hans.txt`。
- 中英审核说明，包含控制中心截图、相册查看、多图拼接和左上角添加闹钟的操作路径，见 `review-notes.md`。
- 隐私问卷、分级及素材权利依据，见 `privacy-answers.md`、`compliance.md`。
- 中国大陆个人主体备案准备，见 `filing-preparation.md`。
- 当前 Store 界面 8 张 1320×2868 RGB PNG，实际选图和生成的自制素材，见 `screenshots.md`。
- 1024×1024 应用图标，源文件为 `Resources/Branding/AppIcon.png`。
- 支持、隐私和介绍页的当前静态 HTML，位于 `site/`。

截图、图标副本、文字材料及文件摘要组成的交付包保留在本地 `.artifacts/release-20261120/`。私人电话、身份材料、开发签名和设备备份分别保留在私有目录。

## 正式提交前待完成

1. 确认 Apple Developer Program 会员及 App Store Connect 权限，创建或确认正式 App 记录、名称、Bundle ID、版本和可用构建号。
2. 取得分发证书和正式描述文件，绑定主 App、App Group 与控制扩展。当前真机使用开发签名，本地未签名 Store archive 属于候选构建。
3. 部署当前 `site/` 并回读三个公开 URL，核对隐私保留策略和支持文字。本站点的历史成功记录不覆盖当前更新，本轮公开隐私页读取超时。
4. 完成适用的中国大陆备案及信息一致性核对。按最终接入商的实际日志实践复核隐私问卷，填写正式分级问卷及适用合规字段。
5. 补充当前滚动截图真机素材，完成实际相册写入、排程恢复、后台/离线响铃与升级数据验收。已有历史记录不能替代当前构建验收。
6. 在 App Store Connect 填写材料，补入私有保存的审核电话，上传签名构建，经处理后选择构建、提交审核，审核通过后由提交人手动发布。

Apple 要求适用的 ICP 备案信息与工信部记录一致，最终以账户中的适用字段及核验结果为准。[Apple App 信息规则](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

截图采用当前官方大屏尺寸。自 2027 年 4 月起，使用 iOS 27.1 SDK 或更新版本提交时还需 iPhone Duo 截图。[Apple 截图规范](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
