## BUG-3993 · subtitle-batch-mixed-versions
- **报告**：2026-11-02（用户：同一合集整季批量下载字幕，第 1 集是 Nekomoe 的 `.ass`，第 2 集起是 Netflix `ja[cc].srt`）
- **真实性**：✅ 真 bug。Jimaku 条目 12217（Grow Up Show）实测：Nekomoe 只有第 1 集（`[JPN]` 认作 ja），Netflix ja[cc] 有 1–13 集，shincaps / NanakoRaws 的 ass/srt 文件名不带语言标记（认作未知语言）。根因在 `fushi/lib/src/media/video/subtitle/subtitle_episode_matching.dart` `chooseSubtitleForEpisode`：每集**独立**按「语言权重 → 文件名字母序」取首个，整批没有版本一致性约束；第 1 集 `[Nekomoe…` 字母序先于 `グロウ…` 赢了，其余集只剩 Netflix 是 ja → 同季混排。番剧下载落位 `matchJimakuFilesToVideoNames`（`fushi/lib/src/media/torrent/anime_download_matching.dart`）同形。
- **[x] ① 已修复** — 新增 `SubtitleEpisodeIndex.preferConsistentVersion`：按整批目标集给版本排名（语言 → 覆盖目标集数 → ASS/SSA 先于 SRT → 稳定序），每集按版本排名重排，判据不变；首选版本缺的集由次选版本补。合集批量 `runSubtitleBatch` 用版本卡同一键 `subtitleVersionKeyOf`，番剧下载用 `jimakuVersionKeyOf`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_batch_test.dart`「整批版本一致（Jimaku 12217 实测形状）」4 条；`fushi/test/torrent/anime_download_matching_test.dart`「整包落在同一字幕版本」。
- **备注**：语言偏好仍排第一位。本例 shincaps/NanakoRaws 文件名不带语言标记，自动只会整季选 Netflix srt（一致，但不是 ass）；要整季 ass 在合集面板「偏好版本」选 shincaps ASS。`[CHS, JPN]` 这种逗号列表括号不被 `detectSubtitleLanguage` 识别，未在本次改。
