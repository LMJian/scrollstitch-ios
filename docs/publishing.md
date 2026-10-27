# 公开文件与发布检查

可发布：`App/`、`Controls/`、`Shared/`、`Sources/` 源码，`Resources/` 图标/隐私说明/年度数据，`Tests/` 合成测试代码，`Tools/`、`scripts/`、`docs/`，生成的 `ScrollStitch.xcodeproj`、`Package.swift`、公共配置和 Harness 项目命令配置。

不可发布：`Config/Local.xcconfig`、证书/私钥/描述文件、设备标识与安装回执、作品/录屏/相册备份、私有测试素材、日志、`.build/`、`.swiftpm/`、DerivedData、`.artifacts/`、`DeviceEvidence/`、Xcode 用户目录，以及 `.harness/runs/`、`worktrees/`、`knowledge/`。`.git/` 的本地对象和内部引用不是项目文件；不要用镜像推送或推送所有引用。

`.gitignore` 只能防止新文件误加入，不能移除已经被跟踪的文件。`python3 scripts/check_public_tree.py` 会检查实际跟踪和待加入的公开文件、敏感格式、绝对用户路径及常见凭据格式。它不能代替人工判断图像内容、代码权属或完整凭据审计。

历史开发文档、任务状态、UI 草稿素材及本地作品备份不进入公开版本。默认公开图片只有两个相同的 App 图标文件；回归测试即时生成合成像素，不包含个人屏幕画面。用户已批准公开支持邮箱和版权署名，保存在 App 内说明与 `docs/app-store/`；公开页面未部署验证时，App 的网页链接保持空值。身份证件、审核电话、签名材料和真实设备截图仍不得公开。

发布前确认：

1. 测试和构建通过，重新查看 `git diff --cached --stat` 及公共文件检查结果。
2. main 仅保留整理后的初始提交，避免首次推送带出旧素材历史。
3. 本项目采用根目录 `LICENSE` 中的 MIT 许可证；分发时保留版权声明和许可文本。
4. 明确 GitHub 目标仓库及访问权限。只推送 `main`，不自动推送标签、其他分支或内部引用。若远程已有内容，先检查，不擅自覆盖。
5. 推送完成后核对远程提交和公开文件列表。GitHub 源码发布不等同于 App Store 上架。
