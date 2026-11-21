# 卷轴 App Store 准备包

用户已确认三功能完整版、免费、中国大陆、支持邮箱 limingjian.yy@gmail.com、版权 2026 李明健。2026-11-21 已核实付费会员生效，卷轴记录已创建，正式签名构建已上传并处理完成。1.0.0（1）已于北京时间 2026-11-21 21:24 正式提交，当前等待审核。备案适用性待 Apple 答复，当前尚无 APP 备案号。算法修复已补本地回归。用户确认控制中心开始、灵动岛停止的主流程可用。

| 材料 | 路径 | 使用方式 |
| --- | --- | --- |
| 商店字段 | [metadata.zh-Hans.json](metadata.zh-Hans.json) | 包含名称、副标题、分类、关键词、免费定价/地区及联系信息；名称可用性待创建应用记录确认 |
| 商品描述 | [description.zh-Hans.txt](description.zh-Hans.txt) | 可直接复制到简体中文 Description；已写明系统版本、北京时间、覆盖日期和离线边界 |
| 中英审核说明 | [review-notes.md](review-notes.md) | 供审核人员执行三条功能路径，不声称 Apple 已验收 |
| 隐私、分级、备案 | [compliance.md](compliance.md) | 填报依据、素材权利及需要本人提供的资料 |
| 隐私问卷答案 | [privacy-answers.md](privacy-answers.md) | 已按现有 GitHub 托管方案复核，可供填报；保留分类判断与日志未知项 |
| 北京备案准备 | [filing-preparation.md](filing-preparation.md) | 本地工具加公开年度 JSON 下载的适用性待核实，确认适用后再选择办理渠道 |
| 验收 | [acceptance.md](acceptance.md) | 区分本地验证、模拟器和真机结果 |
| 本轮真机记录 | [device-acceptance-2026-11-20.md](device-acceptance-2026-11-20.md) | 当前版本后台响铃通过，滚动长图重复及缺行，记录清理状态 |
| 网站页面 | [介绍](https://lmjian.github.io/apps/scrollstitch/)、[支持](https://lmjian.github.io/apps/scrollstitch/support.html)、[隐私](https://lmjian.github.io/apps/scrollstitch/privacy.html) | 当前更新已部署，三个 URL HTTP 200 且正文匹配。无 JS、分析或外部字体，源文件保存在 site/ |
| 截图交付 | [screenshots.md](screenshots.md) | 本轮准备 8 张 1320×2868 RGB 原始模拟器截图，使用自制素材。旧截图保留历史来源 |
| 剩余状态 | [release-status.json](release-status.json) | 未完成事项保持 pending，不使用虚构的备案号/审核回执 |

## 2026-11-20 更新

当前材料沿用免费、中国大陆、iPhone / iOS 27+、1.0.0（1）。已更新商品描述和审核导航，补充当前 Store 界面的 8 张原始大屏截图。新截图通过真实照片选择器导入三张自制图片并生成拼图，覆盖拼图、闹钟、年度安排及 App 信息。滚动截图的模拟器限制页已排除。

截图来源为 `6256d89`，后续算法修正及操作路径约束已推送。此前发现的长图重复、缺行及开头恢复问题已做本地修正和回归。主流程按用户确认固定为控制中心开始、灵动岛完成。其他结束方式的代理测试已按用户要求排除。当前后台测试闹钟实际响铃，用户确认听到，测试规则已删除，临时工具已卸载。当前交接顺序见 [提交清单](submission-checklist.md)，历史验收仍按原日期和构建记录。

## 本轮提交准备状态

Apple ID 为 `6837656155`，SKU 为 `scrollstitch-ios`。1.0.0（1）已完成 Apple 分发签名、上传和处理，并经用户授权正式提交。版本页和独立提交记录均显示等待审核，提交时间为北京时间 2026-11-21 21:24。中文商品信息、中英审核说明、私有审核联系人、4+ 分级、内容版权声明和中国大陆两项合规适用性声明均已保存。免费、中国大陆单一地区、iPhone 提供范围与手动发布已核对。8 张原始截图已上传，后台为中等屏幕复用大屏素材。用户确认后，隐私标签已发布。

上传构建源码为 `1b44b8b`，与后续检查器和交接文档提交分开记录。主 App 和控制扩展实际分发签名均带批准的新共享组，新增的发行检查会拒绝仅描述文件允许、实际签名遗漏共享组的包。回归同时使用模拟签名夹具与两份实际导出包验证。

备案适用性咨询尚未取得答复结论。已在原官方案例补充正式 Apple ID、Bundle ID 和当前提交状态，官方确认收到并将回复。版本已进入等待审核，后续处理审核反馈及通过后的手动发布。发送原文、案例编号、私有审核电话和签名资料仅本地保存。

## 本地检查与正式候选包

开发版控制扩展的默认后缀为 `app.controls`。正式发行可通过被 Git 忽略的独立 xcconfig 覆盖 `DEVELOPMENT_TEAM`、`SCROLLSTITCH_APP_GROUP` 和 `SCROLLSTITCH_CONTROLS_BUNDLE_SUFFIX`，并用 `xcodebuild -xcconfig` 传入。主 App 与控制扩展使用相同的新共享组，主 App 的 Bundle ID 单独核对。用户已同意首次上架版使用新共享组及控制扩展标识，后续手机更新前先备份并确认数据迁移。

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

`ScrollStitchStore` 的 Store 配置保留全部三项功能、年度文件和控制扩展，仅关闭内部操作工具。正式上传使用经核验的 Apple 分发签名包。本地检查命令生成的未签名 archive 用于结构回归，正式导出包、上传回执与线上构建状态分别保留证据。开发版默认签名配置保留。

## 网站交付

页面源由 `Resources/Store/ProductInfo.json`、商店 metadata 及 `scripts/prepare_store_site.py` 生成。修改后重新生成并检查，避免 App 内和网页隐私说明不一致。

页面发布到现有 GitHub Pages 博客的 `apps/scrollstitch/`。本轮仅更新隐私和支持 HTML，部署提交为 `e114bd8`。三个公开 URL 均返回 200，正文与当前本地生成文件逐字节一致。两份 ProductInfo 已接入支持与隐私网址，同时保留完整离线说明和邮件支持。[当前部署记录](https://github.com/LMJian/LMJian.github.io/actions/runs/44683479856)

今后更新页面仍需先部署、核对公开内容，再更新 App 所承诺的链接或政策版本。当前网络验证不等于已验证中国大陆所有运营商的可达性。

不得使用本地 `file://`、临时预览地址或仓库源文件地址冒充 App Store 隐私政策/支持 URL。个人身份材料、签名配置、真实设备文件、审核电话及本地运行回执不提交源码。
