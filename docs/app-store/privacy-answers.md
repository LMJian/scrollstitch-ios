# App Store 隐私问卷准备稿

核对日期：2026-10-27。适用于当前三功能 Store 候选包和 GitHub Pages 年度下载入口。此稿已完成源码与公开托管政策核对，尚未在 App Store Connect 提交；更换备案接入商后须复核其日志实践。

## 已核定的代码行为

`WorkdayHolidayStore` 使用临时 URLSession，只请求公开 JSON；关闭 Cookie，不使用凭据存储，不携带账户、广告标识或闹钟内容。缓存写入经过大小、格式、年份、修订号及 SHA-256 校验。图片、录屏、规则和单日例外在本机处理。Store 关闭内部诊断工具，没有广告、分析 SDK 或自动上传诊断接口。

`ProductInformationView` 的邮件入口由用户主动打开邮件客户端；支持和隐私网页入口由系统浏览器打开。用户决定是否发送邮件及附件。开发者收到的反馈可包含发件邮箱和用户主动提供的排障内容。不能因为没有登录就推断这些信息不关联身份。

## 逐项填报建议

| 项目 | 准备答案 | 依据与边界 |
| --- | --- | --- |
| 是否收集数据 | 按“是”准备，保留下面的托管日志与主动客服反馈 | 不把“图片不上云”扩大为“所有数据均不收集” |
| 跟踪用户 | 否 | 当前无跨公司广告跟踪、广告归因或数据经纪用途；不申请 ATT |
| Email Address | 主动邮件反馈；App Functionality；Linked to User：是；Tracking：否 | 用于联系用户和处理反馈；不套用未经证明满足全部条件的可选披露例外 |
| Customer Support | 主动提交的客服内容；App Functionality；Linked to User：是；Tracking：否 | 不把用户所有本地照片声明为上传；提交的反馈本身另按客服内容处理 |
| 托管方安全日志 | 建议 Other Data Types；App Functionality；保守按 Linked to User：是；Tracking：否 | IP 用于安全日志的分类是本项目的填报判断，不是 Apple 对 GitHub 的专项裁定；没有证据证明采集前已匿名化 |
| Photos or Videos / Audio / Contacts / Health / Purchases 等 | 不因本机处理而勾选收集 | 当前 App 不上传这些内容；不把 Apple 的照片同步当作开发者的收集 |
| Device ID、Coarse Location、Other Diagnostic Data | 暂不仅因存在 IP 就自动勾选 | 只有实际用于设备识别、位置推断或技术诊断时才映射到相应类型；见下方需复核项 |

Apple 按实际收集与用途判断类型，安全用途也可能需要披露；本机处理和隐私清单不等于商店问卷答案。以上分类按当前实现准备，最终由提交人确认。[Apple 填报规则](https://developer.apple.com/app-store/app-privacy-details/)。

## 托管日志的确定事实与剩余边界

GitHub Pages 明确会保存访问者 IP 用于安全，即使访问者没有登录。当前静态页面没有自建分析脚本、广告、外部字体或表单。[GitHub Pages 说明](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)。

GitHub 的通用隐私声明另涉及位置推断、使用数据等多种服务行为，但不能据此确认匿名 Pages JSON 请求逐项执行了这些行为；公开材料也没有给出本项目日志的具体保存期或采集前匿名化保证。[GitHub 隐私声明](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)。

正式提交前，将最终接入商关于 IP、位置推断、标识关联、用途和保存期的答复保存在私有发行材料中。若实际行为超出上表，补充对应类别；不要为了勾选“不收集”虚构不落日志承诺。本轮不把该待核实的服务商行为标成已获 Apple 接受。

审核联系人的私人电话号码是提交给 Apple 的联系方式，不是 App 收集用户电话号码的功能，不填入公开 metadata、网页或隐私收集类别。
