# App Review 说明

这是待填写到 App Store Connect 的审核说明。审核电话已私有保存，提交时补入 App Store Connect；支持与隐私网址已发布并核验。当前尚未上传构建，也没有 Apple 审核结论。

## 中文说明

卷轴是一款免费的 iPhone 工具，提供滚动截图、多图拼接和中国调休闹钟。无需注册或登录，没有广告、内购、订阅、付费解锁或远程执行代码。首发地区为中国大陆，最低系统版本 iOS 27。

三个标签分别为“滚动截图”“多图拼接”“调休闹钟”。正式构建包含全部功能及 WidgetKit 控制扩展，不包含内部诊断/素材注入入口。

### 滚动截图

1. 在“滚动截图”页查看使用方法，按提示授予仅添加照片权限。
2. 将“卷轴”和“卷轴 · 接下一页”添加到控制中心。
3. 打开可供测试的自有网页或其他有权截取的内容，停在起点，从控制中心点“卷轴”。
4. 在 Apple 系统面板确认共享整个屏幕，等待系统提示和控制面板收起后，保持同一方向轴缓慢滚动。
5. 需要换页时用“接下一页”暂停，切换页面后继续。完成时使用灵动岛操作或再次点击控制中心“卷轴”。
6. App 在本机自动拼接并添加到照片；也可在作品中查看结果。照片权限拒绝或保存结果不确定时，不会反复自动添加照片，用户可查看保留的作品。

使用 ScreenCaptureKit 的系统授权流程，录制期间系统显示录屏指示。仅处理画面，不采集或保存音频，不规避受保护内容或系统限制。录屏素材不上传服务器。后台模式用于正在进行的屏幕采集、完成本地处理和系统允许的任务调度。

### 多图拼接

在“多图拼接”选择 2–20 张图片，进入编辑页，调整顺序、裁剪、间距或背景后生成。预览结果，点击保存或系统分享。使用系统照片选择器，仅获取主动选中的图片；向相册写入时才使用添加照片权限。

### 调休闹钟

在“调休闹钟”创建规则并授予 AlarmKit 授权。重复方式支持法定工作日、每天、自选星期及单日例外。在“年度安排”查看随包年度信息，并可手动下载更新。

所有闹钟时间使用北京时间（Asia/Shanghai）。已下载数据及已成功排程的闹钟可离线使用。最多预排未来 90 天内最近 64 次；用户打开 App、停止闹钟以及系统允许的后台刷新会尝试补齐，不宣称无限期离线补排。缺少某年度安排时，界面显示缺失，不猜测该年法定工作日。

审核现场响铃可创建“每天”的短时规则；法定休息日跳过和周末补班规则可在年度数据中查看。不要通过更改整个设备日期制造假验证。测试结束后删除测试闹钟。请勿将 App 隐藏或设置单独 Face ID／密码锁，系统可能限制此类 App 的闹钟。

年度文件为公开 HTTPS JSON，数据来源记录在每个年度文件中；客户端校验版本及 SHA-256，失败继续使用已有有效数据。下载只更新日历数据，不下载执行代码或改变 App 功能。GitHub Pages 可能记录必要的请求日志，隐私政策有说明。

## English review notes

ScrollStitch (卷轴) is a free iPhone utility for scrolling screenshots, image collages, and workday alarms based on China's published holiday calendar. It requires iOS 27 or later. No account, ads, in-app purchases, subscriptions, or paid feature unlocks are used. The launch territory is China mainland.

The three tabs are Scrolling Capture (滚动截图), Collage (多图拼接), and Workday Alarms (调休闹钟). The submission includes all three features and a WidgetKit control extension; internal operator tools are disabled.

For scrolling capture, follow the in-app guide to add the 卷轴 and next-page controls to Control Center. Open content you are permitted to capture, tap the capture control, and accept Apple's system screen-sharing prompt. Wait for the system overlays to dismiss before scrolling on one axis. Use the next-page control to pause/resume across pages. Finish using the Live Activity controls or the capture control again. Images are reconstructed locally and added to Photos with permission. The app never records audio or uploads captured content. It does not bypass protected content or system recording restrictions.

For collages, select 2–20 images through the system photo picker, edit their order/crop/spacing/background, generate a result, then save or share it. Only selected images are read; saving uses add-only Photos permission.

For alarms, create a rule on the alarm tab and allow AlarmKit. To observe an immediate alert, use a daily rule a few minutes in the future, then remove it after testing. The holiday data screen shows bundled years and provides a manual update action. All alarm times use Asia/Shanghai, even while traveling. The app schedules up to the next 64 occurrences within a 90-day horizon, displays the system-confirmed coverage, and attempts replenishment when reopened, after stopping an alarm, and during permitted background refresh. It does not promise indefinite offline replenishment. Missing calendar years are shown instead of inferred. Hiding or locking the app may prevent system alarms.

Holiday updates contain JSON data only, with version and hash verification. They do not deliver executable code. Existing valid data remains usable if a request fails. GitHub Pages may retain network request information for security, as disclosed in the privacy policy.
