# 卷轴 App Store 准备包

用户已确认：**三功能完整版、免费、中国大陆、支持邮箱 limingjian.yy@gmail.com、版权 2026 李明健**。账号注册暂缓。当前分支完成本地准备，不表示已签名分发、备案、上传或获批。

| 材料 | 路径 | 使用方式 |
| --- | --- | --- |
| 商店字段 | [metadata.zh-Hans.json](metadata.zh-Hans.json) | 包含名称、副标题、分类、关键词、免费定价/地区及联系信息；名称可用性待创建应用记录确认 |
| 商品描述 | [description.zh-Hans.txt](description.zh-Hans.txt) | 可直接复制到简体中文 Description；已写明系统版本、北京时间、覆盖日期和离线边界 |
| 中英审核说明 | [review-notes.md](review-notes.md) | 供审核人员执行三条功能路径，不声称 Apple 已验收 |
| 隐私、分级、备案 | [compliance.md](compliance.md) | 填报依据、素材权利及需要本人提供的资料 |
| 隐私问卷答案 | [privacy-answers.md](privacy-answers.md) | 已核对源码与托管政策；给出逐项答案及最终接入商需复核的日志边界 |
| 北京备案准备 | [filing-preparation.md](filing-preparation.md) | 个人主体、当前域名缺口、可直接使用的服务说明和静态文件迁移顺序 |
| 验收 | [acceptance.md](acceptance.md) | 区分本地验证、模拟器和真机结果 |
| 本轮真机记录 | [device-acceptance-2026-10-27.md](device-acceptance-2026-10-27.md) | 记录已观察结果、发现的问题及用户暂停后的剩余验收/清理项 |
| 网站页面 | [介绍](https://lmjian.github.io/apps/scrollstitch/)、[支持](https://lmjian.github.io/apps/scrollstitch/support.html)、[隐私](https://lmjian.github.io/apps/scrollstitch/privacy.html) | 已部署并验证，无 JS、分析或外部字体；源文件保存在 site/ |
| 截图交付 | [screenshots.md](screenshots.md) | 已整理 10 张真实截图（6 张模拟器、4 张真机），均为自有素材；最新代码修复仍待真机复测 |
| 剩余状态 | [release-status.json](release-status.json) | 未完成事项保持 pending，不使用虚构的备案号/审核回执 |

## 本地检查与正式候选包

```sh
python3 scripts/generate_project.py --check
python3 scripts/prepare_store_site.py --check
python3 scripts/check_store_materials.py
bash scripts/check.sh unit
bash scripts/check.sh config
python3 scripts/check_store_mode.py
bash scripts/check.sh store-archive
python3 scripts/check_release.py --mode local --app .build/StoreArchive.xcarchive/Products/Applications/ScrollStitchStore.app
```

`ScrollStitchStore` 的 Store 配置保留全部三项功能、年度文件和控制扩展，仅关闭内部操作工具。包仍需绑定正式团队并完成分发签名；本地未签名 archive 无法直接给用户安装或上传发行。当前开发身份和 App Group 不为制作材料而更改。

## 网站交付

页面源由 `Resources/Store/ProductInfo.json`、商店 metadata 及 `scripts/prepare_store_site.py` 生成。修改后重新生成并检查，避免 App 内和网页隐私说明不一致。

页面已发布到现有 GitHub Pages 博客的 `apps/scrollstitch/`，仅新增本目录对应的三份 HTML，未修改博客布局、导航、文章、脚本或年度 JSON 接口。[部署记录](https://github.com/LMJian/LMJian.github.io/actions/runs/40362639245)对应提交 `c19a725`。三个公开 URL 均返回 200，正文与本地生成文件逐字节一致；两份 ProductInfo 已接入支持与隐私网址，同时保留完整离线说明和邮件支持。

今后更新页面仍需先部署、核对公开内容，再更新 App 所承诺的链接或政策版本。当前网络验证不等于已验证中国大陆所有运营商的可达性。

不得使用本地 `file://`、临时预览地址或仓库源文件地址冒充 App Store 隐私政策/支持 URL。个人身份材料、签名配置、真实设备文件、审核电话及本地运行回执不提交源码。
