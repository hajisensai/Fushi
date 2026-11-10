## BUG-4370 · 视频源扩展（Torrentio）给的磁链被当本地文件打开，无限加载
- **报告**：2026-11-09（应用内反馈 xAeextyOV1，Windows 3.3.0+24434）
- **真实性**：✅ 真 bug。反馈日志：`VideoFushi.playerError Cannot open file '~\AppData\Local\Temp\magnet:?xt=urn:btih:…&index=0': Invalid argument`，随后 `VideoFushi.mediaNeverOpened network stream never opened within 45000ms`。
  根因：Aniyomi 的 Torrentio 扩展给的候选是 `magnet:` 链接（Aniyomi 靠外挂 TorrServer 把它转成本地 http 流，本宿主没有这一层）。
  `fushi/lib/src/media/video/online/anime_source_video_client.dart:404/411`（develop 17d2964e12）选流不看形态、把磁链原样当 `streamUrl` 交给播放页；
  播放器 `fushi/lib/src/media/video/video_player_controller.dart:88` `mediaUriForVideoPath` 把非 http(s) 一律当本地路径包成 file URI，磁链变成「当前目录下的同名文件」，libmpv 打不开，页面空转 45 秒。
  整片下载 `anime_source_video_client.dart:582/593` 同样把磁链交给 HTTP 下载器。
- **[x] ① 已修复**（209a0445fd）— 磁链在 client 层就被识别（`isMagnetUri`，`packages/fushi_engine/lib/media/torrent/magnet_utils.dart`）：默认选流优先可串流候选；选中的若是磁链（只有磁链 / 用户钉住磁链线路），取流与整片下载都抛 `AnimeSourceTorrentVideoException`（带磁链 + 作品名·集名标题），不再交给播放器 / HTTP 下载器。播放页失败态说明原因（`video_online_stream_torrent`），并给「用种子下载」入口：打开下载中心「添加任务」框预填磁链与标题（`ManualDownloadTaskDialog.initialMagnet` / `initialTitle`），走 schema-v78 下载管线（或互联 host）。iOS 合规：入口只在 `StoreRestrictedCapability.downloads.isAvailable` 时出现（iOS 上视频源宿主本身也不装配）。
- **[x] ② 已加自动化测试**（043a4e9b10）— `fushi/test/media/video/online/anime_source_video_client_test.dart`（「种子（磁链）候选走下载管线」组）、`fushi/test/media/torrent/magnet_utils_test.dart`（`isMagnetUri`）、`fushi/test/pages/manual_download_task_dialog_initial_magnet_test.dart`（预填 widget 测试 + 播放页源码守卫）。
- **备注**：测试未在本分支运行（统一在合并后验证）；未做真机复测。批量整片下载（作品页「下载」多集）遇到磁链候选会如实失败（下载中心任务显示原因），不自动转种子任务；Aniyomi 磁链的 `index=` 文件下标原样保留在磁链里，下载管线目前按整颗种子下载（磁链无 metainfo，`selectedFileIndexes` 要求 .torrent）。
