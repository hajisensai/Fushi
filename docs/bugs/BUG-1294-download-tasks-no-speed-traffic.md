## BUG-1294 · 下载任务行无速度与流量显示
- **报告**：2026-07-31（用户：内置引擎「没有进度、流量显示」）
- **真实性**：✅ 真 bug（缺失链断在抽象层）。native `ht_list_torrents` 一直导出
  `down_rate/up_rate/uploaded/downloaded/num_peers`
  （`native/hibiki_torrent/hibiki_torrent_ffi.cpp:659-711`），Dart FFI
  `HtTorrentStatus` 也全解析（`packages/hibiki_torrent/lib/src/embedded_torrent_engine.dart:231-235`），
  但 `EmbeddedTorrentBackend._toSnapshot`（`embedded_torrent_backend.dart` 旧
  `:154-164`）投影到 `TorrentSnapshot` 时整体丢弃——`TorrentSnapshot`
  （`torrent_backend.dart` 旧 `:7-16`）压根没有这些字段；qb 侧
  `parseQbTorrentInfos` 同样没解析 `dlspeed/upspeed`。服务层只发布
  `Map<String, double>` 百分比、20s 一 tick，UI 任务行只有一个进度环 +
  百分比，速度/流量从未进过 UI。
- **[x] ① 已修复** —
  - `TorrentSnapshot` 补 `downRateBps/upRateBps/downloadedBytes/uploadedBytes/numPeers`
    （缺省 0，向后兼容）；内置/qb 两后端各自填充。
  - `AnimeDownloadService` 新增 `downloadStats`（planId → `DownloadTaskStats`，
    值相等性去抖）；轮询周期自适应：内置引擎 + 有活跃下载时 3s
    （`resolvePollInterval` 纯函数；外接 qb 保持 20s——每 tick 都是全新
    WebUI 登录，提频会放大 qb 认证失败计数，见 BUG-1295）。
  - 任务行订阅 `downloadStats`，显示 `37% · ↓ 1.0 MB/s · ↑ 2.0 KB/s · 4.0 KB`
    （`HibikiByteFormat`，纯数字/符号，零新增 i18n key）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/torrent/anime_download_service_progress_test.dart`：stats
    发布/清空与 progress 键集合一致；`resolvePollInterval` 决策表。
  - `hibiki/test/torrent/qbittorrent_client_test.dart`：qb 速度/流量/peer
    字段解析 + 缺省安全 0。
- **备注**：外接 qb 此前同样没有速度显示（用户可开 qb 自带 WebUI 兜底），
  本修复两后端同时受益。
