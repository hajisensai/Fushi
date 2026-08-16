## BUG-1696 · 番剧订阅：当集 Jimaku 字幕还没上传就整条不下载，生肉早于字幕导致订阅长期不动
- **报告**：2026-08-17（用户：「订阅后没全部下载完成」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/torrent/anime_download_subscription.dart:574-577`（修前）：
  ```dart
  if (current.jimakuEntryId != null && subtitles.isEmpty) {
    pendingError = 'subtitle not available for episode $episode ...';
    await planStore.delete(id);
    continue;   // ← 整条不下
  }
  ```
  生肉普遍早于字幕数小时到数天，所以「发现新一集时字幕还没上传」是**常态**而非异常。旧实现在这一刻把计划删掉并跳过；`processedEpisodes` 不推进，下一轮重新发现、重新扑空。用户视角就是「绑了 Jimaku 条目的订阅永远不下东西」。
  第二层根因：即便下载了，`subtitleStatus` 也落 `subtitleNone`，等于宣告「这一集永远没字幕」；而 `subtitleUnavailable` 在全仓**没有任何重试通道**（`_tickOnce` 只处理 `statusDownloading` 的计划），首次反查恰好发生在下载刚完成、字幕最可能还没上传的那一刻。
- **[x] ① 已修复** — 三步：
  1. 去掉 delete+continue 门，照常下片；`pendingError` 保留（任务行仍告诉用户「这集字幕还没到，下完再试」）。
  2. `subtitleStatus` 从两态改三态：取到 → `resolved`；没取到但绑了条目 → **`pending`**（交给下载完成时按包内真实文件名反查，即 BUG-1206 的强判据，比按标题猜集号更准）；没绑条目 → `none`。
  3. 新增 backoff 重试：`AnimeDownloadPlan.subtitleRetryBackoff`（15min / 1h / 4h / 12h / 24h 后停）+ 纯函数判据 `shouldRetrySubtitles(nowMs)` + `AnimeDownloadService._retrySubtitlesFor`，挂在 `_tickOnce` 尾部，复用同一次 `listTorrents` 与同一条 per-plan 串行边界。尝试计数在**发起前**记，否则 resolver 每次抛异常就永远停在 attempts=0、backoff 退化成每轮都打。
  存量计划缺 `subtitleAttempts` 字段 → 回落 0 → 下一轮 tick 立刻获得一次重试机会，正好把被旧逻辑卡住的那批救回来。
- **[x] ② 已加自动化测试** — `fushi/test/torrent/anime_download_plan_test.dart` 的 `BUG-1696 shouldRetrySubtitles` 组（6 条：状态准入 / 无来源不重试 / 老计划立刻可重试 / 间隔边界 / 用完就停 / JSON 进出与缺字段回落）；`fushi/test/torrent/anime_download_subscription_test.dart` 把原「missing selected subtitle keeps the episode pending」改成断言新契约（照常下片 + `subtitlePending` + 保留 `jimakuEntryId`）。
- **备注**：用户明确选择了「先下片，字幕后台补」这一档，而非「保留门槛但做成开关」。
