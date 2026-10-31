## BUG-3887 · 推荐词典下载 / 词典自动更新切到后台就停
- **报告**：2026-10-31（用户：「the recommended dicts download just doesnt work in the bg when you switch apps / Which is annoying for a 9 gig download」「包括自动更新，后台也会被停止下载」）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/models/dictionary_download_controller.dart` `DictionaryDownloadController.run`：词典链路是唯一没向 `downloadKeepAliveHub` 领租约的下载来源）
- **[x] ① 已修复** — `DictionaryDownloadController` 构造时领 `dictionary` 租约，`run` 期间（下载 + 导入两段）按 phase / message / progress 上报保活通知，finally 里撤（分支 `pr/dict-bg-download`）
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_download_controller_test.dart`「BUG-3887 后台保活」组
- **备注**：iOS 侧 `createDownloadKeepAlive()` 仍是 no-op（系统不给前台服务；后台续跑要换 `URLSession` background 配置，属另一项工作），本修复只覆盖 Android。

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
