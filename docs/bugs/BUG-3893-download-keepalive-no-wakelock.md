## BUG-3893 · download-keepalive-no-wakelock
- **报告**：2026-10-26（应用内反馈 nLXqmvv5Fy，vivo V2463A / Android 16，3.0.0：「息屏状态下不会继续下载，只有在屏幕亮的时候才会继续下载」）
- **真实性**：✅ 真 bug（根因 `fushi/android/app/src/main/java/app/fushi/reader/DownloadKeepAliveService.java` `onStartCommand`：只 `startForeground`（dataSync）把进程提为前台优先级，全文件不持 PARTIAL_WAKE_LOCK / WifiLock；前台服务不阻止 CPU 休眠，息屏后主 isolate 的下载循环停摆。该服务经 `downloadKeepAliveHub` 覆盖 discovery 直链 / 内置 torrent 视频任务 / 漫画 / 互联 / 词典 / 更新包全部下载来源，反馈人 3.0.0 已含 BUG-2714 的保活服务）
- **[x] ① 已修复** — 新增 `DownloadKeepAliveLocks`（PARTIAL_WAKE_LOCK + Wi-Fi 锁，非引用计数、acquire/release 幂等），服务进前台后拿锁，`stopNow` / `onDestroy` 放锁（Android 15 dataSync `onTimeout` 经 `stopNow`）（分支 pr/fb-download-wakelock）
- **[x] ② 已加自动化测试** — JVM 单测 `fushi/android/app/src/test/kotlin/app/fushi/reader/DownloadKeepAliveLocksTest.kt`（幂等 / 重叠停止路径只放一次）+ 接线守卫 `fushi/test/android/download_keep_alive_wake_lock_guard_test.dart`
- **备注**：未真机息屏长跑验证。反馈里「常驻通知显示下载进度」已由 BUG-2714 的保活通知覆盖；「OCR 进度通知」是新需求，未做。外接 qBittorrent 任务不挂保活（字节在 qB 进程里下），不受影响。
