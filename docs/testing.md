# 验证

所有默认检查不需要私人素材或历史 Harness 状态。需要 macOS、Xcode 27、Swift 6 和 Python 3。命令行构建不会安装应用或操作 GUI。

```sh
python3 scripts/generate_project.py
python3 scripts/check_public_tree.py
python3 scripts/prepare_store_site.py --check
python3 scripts/check_store_materials.py
bash scripts/check.sh unit
bash scripts/check.sh config
python3 scripts/check_alarm_data.py
swift scripts/generate_icon.swift --check
bash scripts/check.sh device-build
python3 scripts/check_store_mode.py
bash scripts/check.sh store-archive
python3 scripts/check_release.py --mode local --app .build/StoreArchive.xcarchive/Products/Applications/ScrollStitchStore.app
```

`unit` 包含 Swift 核心、图像测试及 Python 发布检查的负例。重点验证：拼图排序/裁剪/导出像素和元数据、取消与事务恢复、往返滚动和换页重建、失败缓存重试、Photos 写入账本、2026 年每一天规则、跨年未知状态、下载完整性与版本优先级、年度修正后的取消/补排及离线重启。相册和 AlarmKit 适配器使用测试替身，不把替身成功当作系统响铃或真实相册写入。

可单独运行变化相关场景，例如：

```sh
swift test --scratch-path .build/tests --filter CapturePipelineTests
swift test --scratch-path .build/tests --filter Workday
bash scripts/check_holiday_endpoint.sh
```

最后一个命令使用生产下载代码读取真实 GitHub Pages 入口，在临时目录缓存并校验年度文件，然后重新打开离线缓存；不修改博客或手机。它需要网络，属于可选在线检查，失败不会被解释为离线功能失败。

`Tools/ScrollReplay` 可回放外部提供的帧目录并比较独立基线；输入不随仓库发布。历史真实素材及作品备份已经移除，默认检查不再引用它们。不要生成“真机通过”收据来替代缺少的设备证据。

本地单元测试和构建不能证明控制中心启动、系统共享确认、后台/锁屏生命周期、实际照片写入、静音/专注下响铃、重启后行为。这些需要明确授权的设备验收。设备安装、证据采集与测试数据清理应单独记录；额外设备矩阵、iCloud Photos 和真实低磁盘/内存压力不是本次本地审查覆盖范围。

## Store 模拟器验证

启动模拟器、安装、UI 自动化与截图需要本任务单独授权。使用新建的测试模拟器和自有合成素材，不导入用户作品。模拟器包也需要保留 App Group entitlement；`CODE_SIGNING_ALLOWED=NO` 的构建只适合编译检查，不能作为共享容器可用的运行候选包。下面的临时签名不使用开发者账号，也不生成可分发的真机包：

```sh
xcodebuild -project ScrollStitch.xcodeproj -scheme ScrollStitchStore \
  -configuration Store -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/StoreSimulator \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build
```

记录所测包的源码摘要、版本、系统和截图尺寸。UI 检查应走实际照片选择器、编辑、生成和保存路径，核对输出文件内容；不能只断言页面出现。照片选择器的可访问性结构随系统版本变化，定位失败应先检查实际元素，不能改成无条件通过。截图须等待导航动画结束，并保留原始像素。商店截图说明与当前交付状态见 [app-store/screenshots.md](app-store/screenshots.md)。
