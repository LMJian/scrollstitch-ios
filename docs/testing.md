# 验证

所有默认检查不需要私人素材或历史 Harness 状态。需要 macOS、Xcode 27、Swift 6 和 Python 3。命令行构建不会安装应用或操作 GUI。

```sh
python3 scripts/generate_project.py
python3 scripts/check_public_tree.py
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
