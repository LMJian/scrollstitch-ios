# 隐私、分级、备案与素材准备

准备范围：三功能完整版，免费，中国大陆。本文是根据当前源码整理的填报材料，不是备案号、法律结论或 Apple 已接受的申报。

## 隐私问卷

| 数据/行为 | 当前实现 | 填报依据与待办 |
| --- | --- | --- |
| 图片、录屏画面 | 本机处理，开发者无自动上传接口 | 仅在设备上处理不属于 Apple 定义的“收集”。主动系统分享另由用户选择接收方 |
| 闹钟、单日例外、年度缓存 | 本机与系统闹钟保存 | 下载请求不包含闹钟内容或设备唯一标识 |
| 用户账户、广告、跟踪 | 无登录、广告 SDK、分析 SDK 或跨服务跟踪 | 不申请 ATT；不填写不存在的账户或广告用途 |
| 年度数据 HTTPS 请求 | GitHub Pages 接收并为安全记录 IP；也接收路径和请求时间等网络信息 | 不能简单声称完全“不收集数据”。按最终托管方实际用途核定 IP/网络日志分类，通常涉及安全诊断或 App 功能；是否关联身份、用途和类型要与服务实际一致 |
| 主动邮件反馈 | 用户自己发送邮箱、正文及附件 | 用于回复与排障。Apple 的可选披露例外有条件，不自动把所有邮件/诊断视为豁免 |
| Apple 系统处理 | Photos、AlarmKit、系统备份由用户设置控制 | 区分 App 自身实践和 Apple 的系统服务实践，不保证 App 能删除他方副本 |

`PrivacyInfo.xcprivacy` 已列明本机 required-reason API；隐私清单与 App Store 隐私问卷是不同材料。[逐项填报稿](privacy-answers.md)已核对当前源码与 GitHub Pages 公开政策，并区分确定行为、分类判断和最终接入商需确认的内容。

依据：[Apple 隐私填报](https://developer.apple.com/app-store/app-privacy-details/)、[GitHub Pages 数据收集](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)、[GitHub 隐私声明](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)。

## 年龄分级与内容

应用自身无聊天、公开发布、用户社区、广告、网页浏览器、游戏、赌博、健康诊疗建议或付费抽奖；图片选择和屏幕采集接收的是用户自己的内容，不在 App 内建立内容分发平台。问卷按这一本机工具行为如实填写，由 App Store Connect 计算最终年龄等级，不预先把“4+”视为审核结论。当前未完成全套辅助功能体验验证，不勾选未经验证的无障碍声明。

## 加密与出口

当前仅使用 Apple 系统 HTTPS 和 CryptoKit SHA-256 完整性摘要，无自研加密、VPN、端到端通讯或加密销售。Store Info.plist 配置 `ITSAppUsesNonExemptEncryption = NO`，表示按当前实现不包含非豁免加密，绝非“不使用 HTTPS”。提交人仍须根据当时实际二进制及地区填写出口问卷；功能变化需重新检查。[Apple 出口材料说明](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation)。

## 中国大陆 APP 备案材料

已知：应用名“卷轴”，主体拟为李明健，常住北京市，支持邮箱 limingjian.yy@gmail.com，iOS，免费工具，首发三项功能，年度接口域名为 `lmjian.github.io`。用户确认暂无本人实名注册域名；审核电话已私有保存。[北京备案材料与办理顺序](filing-preparation.md)已准备。

以下尚未提供或需要正式发行身份才能确定，不应提交到公共 Git：

- 主体身份证明、联系方式、地址及备案核验材料。
- 通过接入服务商或省通信管理局确认的备案路径；GitHub Pages 能访问不等于完成备案。需核实当前托管方式和域名是否可用于实际申报，必要时另配可备案域名与静态文件托管。
- 正式 App Bundle ID、签名公钥和证书指纹。当前本地开发标识不能当成未来正式签名信息。
- APP 名称、图标、服务说明、网络资源信息、最终备案号。名称与 App Store 简体中文元数据应保持一致。

没有账户登录、没有自建后端或免费下载，均不能单凭这些事实断言免备案。备案是否适用及具体办理要求应以主管部门和接入服务商核定为准。没有实际获批记录时，`mainlandFilingStatus` 必须保持未完成。

依据：[工信部 APP 备案通知](https://www.miit.gov.cn/jgsj/xgj/wjfb/art/2023/art_dd783a581c9644a4aee10afa582811db.html)、[Apple 中国大陆发行信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)。

## 版权与图标

商店版权字段为 `2026 李明健`。源码保留现有 MIT 许可证和 LMJian 署名，不把商店署名变更误当成删除历史许可义务。

代码版权已由用户确认。用户于本轮明确确认当前图标具有商业使用权，继续使用当前图标；该记录不扩展为其他动漫商标或素材的许可。截图只使用本次合成的自有测试素材，不使用历史社交平台截图、私人聊天或原作品备份。[Apple 知识产权要求](https://developer.apple.com/app-store/review/guidelines/#intellectual-property)。
