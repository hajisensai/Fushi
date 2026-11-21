## BUG-5031 · 下载中心两集并发时先下完那集的默认字幕静默丢失（在线源 client 只有一个当前流槽位）
- **报告**：2026-11-20（来源：路线图 #3722 c47 的 video-15，回到代码复核成立）
- **真实性**：✅ 真 bug。根因（基准 `origin/develop@7745effa2e` + c31/c33/c42）：`fushi/lib/src/media/video/online/anime_source_video_client.dart` 只有一个「当前流」槽位（`_currentVideo` / `_currentEpisodeId` / `_defaultSubtitleLanguage`），`downloadRemoteVideo` 每跑一集就覆盖它；一批下载共用一个 `copyForDownload()` 副本（`anime_source_library.dart` `startAnimeEpisodeDownloads`），批内串行，但用户在下载中心「继续 / 重试」另一集时管理器拿同一个 run 闭包并发跑。先下完的那集收尾 `registerDownloaded → _downloadDefaultSubtitle` 调 `defaultSubtitleFileName(id)`，槽位已被后开跑的那集占着，`_currentEpisodeId != id` → 返回 null → 不下字幕、不报错。`getRemoteVideoSubtitle` 更是完全无视 `id`，读到的就是别一集的流。
- **[x] ① 已修复** — 按集 id 存选中的流与当时的默认字幕语言（`_chosenByEpisode` + `_recordChosen`），带 id 的入口（`getRemoteVideoSubtitle` / `defaultSubtitleFileName` / `freshSubtitleAudio`）一律按 id 查；保留「最近一次」槽只给不带 id 的 `httpHeaderFields` 与线路菜单高亮。分支 `pr/remote-stream-timeouts-resume`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/online/anime_source_video_client_test.dart`「两集交错下载：先下完的那集收尾仍拿得到自己的默认字幕」：第一集下完后第二集再取流，断言第一集的默认字幕文件名与实际下载的字幕 URL 都是第一集的（修前文件名为 null）。
- **备注**：未在真机下载中心实测并发两集（本轮所有者定不做设备验证）。
