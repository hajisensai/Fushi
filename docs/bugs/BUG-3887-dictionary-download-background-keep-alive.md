## BUG-3887 · 推荐词典下载 / 词典自动更新切到后台就停（Android + iOS）
- **报告**：2026-10-31（用户：「the recommended dicts download just doesnt work in the bg when you switch apps / Which is annoying for a 9 gig download」「包括自动更新，后台也会被停止下载」）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/models/dictionary_download_controller.dart` `DictionaryDownloadController.run`：词典链路是唯一没向 `downloadKeepAliveHub` 领租约的下载来源）
- **[x] ① 已修复** — `DictionaryDownloadController` 构造时领 `dictionary` 租约，`run` 期间（下载 + 导入两段）按 phase / message / progress 上报保活通知，finally 里撤（分支 `pr/dict-bg-download`）
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_download_controller_test.dart`「BUG-3887 后台保活」组
- **[x] ③ iOS** — 词典包传输改走系统后台 `URLSession`（`fushi/ios/Runner/FushiBackgroundDownload.swift` + `fushi/lib/src/platform/mobile/ios_background_download.dart`，经 `fushi_dictionary` 新钩子 `dictionaryDownloadTransport` 接入）；保活通道补上 iOS 原生侧（`beginBackgroundTask`）。测试 `fushi/test/platform/ios_background_download_test.dart` + 模拟器真链路 `fushi/integration_test/ios_background_download_itest.dart`（宿主脚本 `fushi/tool/ios_background_download_host.sh`）。
- **备注**：iOS 后台会话有三处与 dio 链路不同，均已处理并写在代码注释里：① 后台会话无限等网络、不会自己超时 → 前台看门狗补与 dio 同额的连接 / 卡死预算（不在前台时暂停），镜像回退照常；② 代理装不上 `findProxy` → 按全应用代理裁决翻译成会话配置（自动=系统、直连、手动 host:port），带认证的手动代理表达不了，逐次退回 dio；③ 进程被系统回收后上一进程的任务成了孤儿 → 新进程建会话即取消、唤醒交付的孤儿文件直接丢弃。下载完成后的**导入**仍需 app 回到前台才能跑完（系统唤醒只给几十秒）。

### 根因

推荐词典下载、词典页手动更新、启动 check-due 自动更新三条流程都经
`DictionaryDownloadController.run` 跑在主 isolate（dio 下载 + `Isolate.run` 里的 native 导入），
没有任何原生组件托底。漫画卷 / 视频 torrent / 发现页直链 / 互联拉片都已经经
`downloadKeepAliveHub.lease(...)` 挂 Android `DownloadKeepAliveService`（dataSync 前台服务），
唯独词典没挂——用户一切走，进程即被冻结或回收，大词典包（数 GB）下载必断。

### 修复

在 controller 这一处挂（三条流程全覆盖，不在各调用点各挂一份）：
- 第一次上报发生在 `run` 置 downloading 时——用户点下载 / app 启动自动更新，都在前台，满足 Android 12+「前台才能拉起前台服务」；
- 导入阶段也保活：native 导入「导新 → 删旧 → publish」，中途被杀会停在删旧之后；
- 导入阶段进度报不确定（`progress` 停在下载结束值，不可信）；
- finally 先复位再 `stop()`，复位触发的监听因 `isBusy == false` 不再上报，避免撤完又被拉起。

### iOS

iOS 没有前台服务，`beginBackgroundTask` 只多给约半分钟，进程内的 dio socket 一挂起就停。
唯一能让几 GB 下载在 app 挂起期间推进的是系统后台 `URLSession`：传输在系统守护进程里跑，
下完把 app 唤醒到后台交付文件（`handleEventsForBackgroundURLSession`）。

接入点放在 `fushi_dictionary` 的传输层钩子 `dictionaryDownloadTransport`（与
`dictionaryDioFactory` 同一套装配方向），候选镜像循环、失败归因、「取消不算失败」都不动——
原生结局一律翻译成与 dio 同类型的 `DioError`。三条流程（推荐词典、手动更新、自动更新）
都经 `DictionaryDownloader.download`，一处接入全覆盖。
