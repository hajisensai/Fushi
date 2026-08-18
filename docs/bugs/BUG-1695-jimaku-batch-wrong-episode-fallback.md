## BUG-1695 · 合集批量字幕：集号一条都对不上时静默取第一个文件，整季挂同一个错字幕
- **报告**：2026-08-17（用户：字幕自动下载准确率优化）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/jimaku_batch.dart:112`（修前）
  `final List<JimakuFile> pool = matching.isNotEmpty ? matching : text;`
  ——集号一个都没命中就退回**全体文本字幕取第一个**。两种高频形状直接中招：
  ① 条目按**绝对集号**编号（S2 是 13-24）而本地是 01-12 → 每一集都拿到第 13 集的字幕；
  ② 条目只有一个未编号文件（剧场版 / 整季单文件）→ 12 集全部落同一个文件。
  两种情况状态都显示 `done`，用户不看播放根本发现不了。
  同一个判据在 `anime_download_matching.dart:matchJimakuFilesToVideoNames` 里的答案是**相反**的（「双方都有集号却没配上 ⇒ 不配」）。同一问题两份互相矛盾的实现，本身就是根因。
  次因：批量走 `listFiles(id, episode: n)`，服务端那道过滤是**文件名启发式**，把「字幕侧到底有哪些集号」这个事实遮住了，于是根本判不出集号冲突。
- **[x] ① 已修复** — 抽出全仓唯一判据 `fushi/lib/src/media/video/jimaku_matching.dart`：`JimakuEpisodeIndex`（从 torrent 域搬来，原处 re-export 保持导入方不变）+ `chooseJimakuFileForEpisode`。分三种「没配上」：`episodeConflict`（字幕侧有集号但没这一集）/ `ambiguousUnnumbered`（未编号但目标不止一个）/ `none`。`soleTarget` 是 `required` 而非有默认值——默认值就是本 bug 的形状。批量改为**整批只列一次文件**（不带 `episode=`），请求数从 targets×entries 降到 entries，且冲突判定变成事实而非服务端猜测。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/jimaku_batch_test.dart`：`pickBestSubtitleFile` 组三条新判据用例 + `runJimakuBatch` 两条端到端回归（整季未编号字幕不得被全批共用、绝对集号 13-24 撞本地 01-12 全部 noMatch），并断言「一个错字幕都不许落盘」与「整批只列一次」。
- **备注**：`matchJimakuFilesToVideoNames` 的精确命中分支也改为委托同一原语，它多出来的 1v1 兜底（还要看视频侧集号）保留在原处。
