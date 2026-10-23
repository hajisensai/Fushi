## BUG-3663 · movie-keyword-single-file-scraped-as-tv
- **报告**：2026-10-23（用户：「怎么没让我决策的，又说没刮削出来」→「全部根本性修复，然后pr」）
- **真实性**：✅ 真 bug。`[Fabre-RAW] Doraemon Movie 01 (1980) [1080p].mkv` 被按剧集刮削，自动绑到 TMDB TV「ドラえもん」(1979)；同批 Movie 25 / 30 也绑错，17 部进待确认。根因：Rust 文件名引擎解出 `episode=1, isMovieHint=true`，但 `packages/fushi_engine/lib/media/video/video_filename_parser.dart` 的 `VideoNameInfo` 丢了 `isMovieHint`，`video_source_scrape_coordinator.dart` 的 `_manualMediaKind` 与 `_resolveWork` 都只看 `parsed.episode != null` 判 tv。按 tv 搜，类型门失效，「Doraemon」唯一命中 TV 本体。
- **[x] ① 已修复** — `VideoNameInfo` 带上 `isMovieHint`；协调器两处形态判据收成 `_looksEpisodic`：多集作品是剧，单文件解出集号但带电影关键词时判电影（与下载整理器 `video_download_organizer.dart` 同一判据）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_source_scrape_provider_override_test.dart`（single-file work with a movie keyword is searched as a movie；变异实测：去掉 `!isMovieHint` 即红）。
- **备注**：同批还有 BUG-3662（CLI candidates 只过滤不搜）。本机数据已用 CLI 手工改绑修复。
