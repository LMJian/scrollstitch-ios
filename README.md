# 卷轴 / ScrollStitch

卷轴是一个 iPhone 工具 App，提供滚动截图、多图拼接和调休闹钟。开发环境为 macOS、Xcode 27、Swift 6 和 Python 3；设备要求 iOS 27 或更新版本。图片在本机处理，不依赖第三方 Swift 包。

| 功能 | 使用方式 | 实现与边界 |
| --- | --- | --- |
| 滚动截图 | 在控制中心启动，确认系统全屏共享，滚动后点“完成”；自动拼接并保存照片 | ScreenCaptureKit 屏幕帧；支持纵向、横向、往返去重与暂停换页；不录音。中断或无法确认完整时保留素材并显示原因 |
| 多图拼接 | 选择 2–20 张图片，排序、裁剪、设置间距和背景，生成后保存或分享 | JPEG、PNG、HEIC/HEIF 输入；PNG/JPEG 输出；编辑可撤销、可恢复；超出输出预算时需确认缩小 |
| 调休闹钟 | 设置时间和重复规则，授予系统闹钟权限 | AlarmKit；支持法定工作日、每天、自选星期、单日例外；内置年度数据，也可从静态 JSON 下载更新 |

闹钟固定使用北京时间。最多预排未来 90 天内最近 64 次，打开闹钟页、停止闹钟及系统允许的后台刷新会补齐；后台刷新不是无限期保障。请关注首页实际回读确认的覆盖日期。缺少某年的年度数据时，不猜测该年的法定工作日。已下载数据和已排程闹钟可离线使用。

`ScrollStitch` 是开发版；`ScrollStitchStore` 是包含全部三个功能的正式发行目标，保留控制中心、灵动岛与年度数据，并关闭内部操作工具。首发准备为免费、中国大陆、iPhone / iOS 27+。仓库源码、未签名候选包和 App Store 上架是不同的交付物。

## 构建和运行

```sh
python3 scripts/generate_project.py
bash scripts/check.sh unit
bash scripts/check.sh config
bash scripts/check.sh device-build
```

这些命令不安装 App、不启动模拟器，也不操作手机。安装开发版前，将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`，填写自己的开发团队、唯一 Bundle ID 前缀和 App Group，并在 Xcode 中完成对应能力及签名配置。已有安装应保持原 App 身份和 App Group，避免失去已有作品入口。不要提交本地签名配置。

`generate_project.py` 是 Xcode 工程、plist、entitlements 和 schemes 的生成源，新增文件或修改这些配置时先修改生成脚本再运行。应用图标源文件是 `Resources/Branding/AppIcon.png`，通过 `swift scripts/generate_icon.swift --check` 检查资源一致性。

## 项目文档

- [功能和交互](docs/requirements.md)
- [架构与数据路径](docs/architecture.md)
- [年度 JSON 协议与更新](docs/holiday-data.md)
- [验证方式和证据边界](docs/testing.md)
- [公开文件与发布检查](docs/publishing.md)
- [隐私 API 使用清单](docs/privacy-inventory.json)
- [App Store 准备包与剩余事项](docs/app-store/README.md)

年度下载入口为 [GitHub Pages JSON 索引](https://lmjian.github.io/assets/holidays/cn/index.json)。入口只是静态文件，不依赖博客网页、页面脚本或账号登录。维护者需要根据官方通知发布新年度或更正版本；客户端不会抓取新闻并自动推断放假日期。

## 协作与许可

默认在当前分支开发，创建或切换开发分支、另建开发 worktree 需要用户明确同意。Harness 只保留可共享的配置；运行状态、日志和素材均为被忽略的本地文件，不是构建依赖。普通贡献者可直接运行上述命令，无需安装 Harness。

本项目采用 [MIT 许可证](LICENSE)。使用、修改或分发时请保留版权声明和许可证文本。
