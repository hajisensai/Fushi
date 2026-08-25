## BUG-1866 · 公共索引器重解析非要联网重搜，搜不中就把活资源误报 notFound
- **报告**：2026-08-25（用户：Windows 2.2.1-debug.12346）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/download/video_download_pipeline_service.dart:1481`（修复前）——`_resolvePayload()` 在任务行没落磁链时，**先**拿 `job.resourceTitle`（完整发布名）回索引器全文重搜找回候选，搜不中才落到 BUG-1784 的离线兜底。

  用户原始报错：
  ```
  ExternalProviderFailure(provider=nyaa:nyaa.si, operation=resolve, kind=notFound): selected resource is no longer available
  ```
  抛点 `fushi/lib/src/media/video/download/video_resource_registry.dart:116`。

  nyaa 对 `[Airota&VCB-Studio] Gekijouban Hibike! Euphonium Chikai no Finale / 劇場版 響け! ユーフォニアム ~誓いのフィナーレ~ 10-bit 1080p HEVC BDRip [MOVIE]` 这种整串**必然**搜不中；更糟的是 `preferredNyaaSearchQueries()` 会把这串当 romanized 候选、**挤掉**媒体自己的罗马字别名。于是每次重启/重试都要先把一个还活着的资源报成 notFound，再被兜底捞回来。

  取证：生产库 `video_download_jobs.job_id=89656a4f…` 现存的 `magnet_uri` 里空格是 `+`、`&` 是 `%26`，即 `Uri.encodeQueryComponent` 的产物——只有兜底函数这么拼（`NyaaTorrent.magnet` 用 `Uri.encodeComponent`，空格是 `%20`）。说明这条路径在真机上反复走。

  私有 Torznab 没有兜底，同样情况会直接失败到底。

- **[x] ① 已修复** — `d8e89d7eb4`：公共索引器（nyaa/apibay/knaben）的 payload 就是「info hash + 该索引器固定 tracker 集」拼出来的磁链，是**任务行已有数据的纯函数**，压根不需要网络。把它从「重搜失败后的兜底」提到**联网之前**，这条误报就没有产生的余地了。`_recoverPublicMagnetPayload` 随之改名 `_publicIndexerMagnetPayload`（它不再是「恢复」，而是主路径）。

  等价性：nyaa provider 的 `resolve()` 返回 `NyaaTorrent.magnet` = 同一 hash + `kNyaaTrackers`；apibay/knaben 走 `buildPublicVideoIndexMagnet()` = 同一 hash + `kPublicVideoIndexTrackers`。离线拼出来的与联网重搜拿到的只差 `dn` 显示名的编码，BT 语义相同。只认 40 位 v1 hash：BT v2 的 64 位 hash 要走 `urn:btmh:`，拿它拼 `btih` 只会得到一个谁也认不出的磁链，宁可退回重搜。真正必须重搜的只剩私有 Torznab（`.torrent` 走临时凭据 URL，不落库），其失败语义原样保留。

- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart`：
  `public indexer job resolves offline without touching the network (BUG-1866)` — 存量任务行没磁链 + 索引器**彻底不可达**（`failSearch` 直接抛），断言任务照样进 `download`、`last_error` 为空，且 `searchCalls == 0` / `resolveCalls == 0`（一次网络都不打）。

  变异实测：删掉离线优先块 → 本条与 BUG-1784 的存量行用例同时红。还原以 sha256 校验。
- **备注**：`_resolvePayload` 给 Torznab 重搜时仍把完整发布名当 query 传（会挤掉 media 别名），本次未动——Torznab 是精确索引，发布名通常能中，且没有已知故障样本。真出现 Torznab 找不回，改的应该是 query 选择而不是再加一层兜底。
