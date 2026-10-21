# 年度 JSON 下载

客户端默认下载 `https://lmjian.github.io/assets/holidays/cn/index.json`，再从同一目录下载索引中的 `YYYY.vN.json`。这些静态文件可以放在 GitHub Pages 博客的 `assets/holidays/cn/`，无需改变博客页面、导航或模板。

仓库 `Resources/Holidays/` 包含相同格式的随包年度数据。目前内置 2026 年安排，来源地址、发布日期和完整日期覆盖在文件中。客户端不会抓取国务院网页；维护者依据官方通知审核后生成文件并发布。

索引字段为 `schemaVersion: 1`、`region: "CN"` 和 `years`。每项包括 `year`、正整数 `revision`、精确匹配 `YYYY.vN.json` 的 `file` 及文件原始字节的 SHA-256 `sha256`。最多 16 年，索引不超过 64 KiB。

年度文件字段为 `schemaVersion: 1`、`region: "CN"`、`timeZone: "Asia/Shanghai"`、`year`、`revision`、`source` 和 `overrides`。`source` 包含官方通知 `title`、HTTPS `gov.cn` 域名下的 `url`、`publishedAt`。每个覆盖项包含 `date`（YYYY-MM-DD）、`kind`（work/rest）和 `name`。同一年日期不得重复，不超过 366 项，文件不超过 128 KiB。

发布更正时增加 revision，创建新文件，最后更新索引；不能原地改写同一版本。先上传年度文件再更新索引，避免指向不存在的文件。内置交付时也同步更新 `Resources/Holidays/index.json` 并运行 `python3 scripts/check_alarm_data.py`。端点不可信响应、重定向、错误版本、错误哈希和部分失败均不能覆盖有效缓存。

App 对每年选择内置和缓存中的最高版本。缓存可离线读取；下载成功后重新核对未来排程。进入闹钟功能后触发自动检查，已有成功检查时相隔至少一天；首次失败时当前进程内相隔至少一小时。手动检查不受这一频率限制。自动检查可关闭。

未知年度不会按普通工作日猜测排程。年度 JSON 只表达放假和补班规则，不含用户闹钟、个人例外或图片；文件托管服务会接收普通网络连接所需的信息，App 不附带用户业务数据或认证凭据。
