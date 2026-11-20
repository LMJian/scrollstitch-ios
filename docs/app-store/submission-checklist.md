# 上架材料交接清单

更新日期为 2026-11-20，当前准备版本为三功能完整版 1.0.0（1），免费、中国大陆、iPhone / iOS 27+，审核后手动发布。

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

## 正式提交前待完成

1. 滚动截图采用用户确认的固定主流程，见 AGENTS.md。重复、缺行和开头恢复修正已有本地回归；用户确认日常使用正常。不得因上架擅自追加其他结束路径或重复要求手机验收。
2. 用户已确认会员费用付款成功且有订单收据。已登录官网核验，会员生效尚未确认，App Store Connect 明确提示账户尚未启用 iTunes Connect。待权限生效后创建或确认正式 App 记录、名称、Bundle ID、版本和可用构建号。
3. 取得分发证书和正式描述文件，绑定主 App、App Group 与控制扩展。正式导出已实际失败，当前团队无权创建 App Store 描述文件，主 App 和扩展均缺少发行描述文件。
4. 先核实本地工具加 GitHub Pages 年度 JSON 下载是否适用中国大陆备案要求，已向 Apple 官方支持提交咨询并取得回执，等待答复，必要时咨询北京市通信管理局。确认适用后再办理备案及信息一致性核对，域名和云资源采购另由用户决定。按实际托管方日志实践复核隐私问卷，填写正式分级问卷及适用合规字段。
5. 按用户确认的流程使用现有材料。手机验收按明确授权及具体缺陷安排，扩展设备场景保留证据边界，不自动增加为用户待办。当前一次后台响铃由用户确认，历史结果仍按原构建使用。
6. 在 App Store Connect 填写材料，补入私有保存的审核电话，上传签名构建，经处理后选择构建、提交审核，审核通过后由提交人手动发布。

Apple 要求适用的 ICP 备案信息与工信部记录一致，最终以账户中的适用字段及核验结果为准。[Apple App 信息规则](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

截图采用当前官方大屏尺寸。自 2027 年 4 月起，使用 iOS 27.1 SDK 或更新版本提交时还需 iPhone Duo 截图。[Apple 截图规范](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
