## BUG-3703 · jimaku-movie-subtitle-search-429
- **报告**：2026-10-23（用户：哆啦A梦剧场版 25「のび太のワンニャン時空伝」没自动下载字幕，播放页手动搜索报「字幕搜索失败（HTTP 429）」）
- **真实性**：✅ 真 bug，用本机 Jimaku key 对真 API 复现，三个根因叠加：
  1. 扇出打穿配额：Jimaku 每 key 25 次请求一个窗口（`x-ratelimit-limit: 25`）；回退词「Doraemon」搜出 62 个条目，`fushi/lib/src/media/video/jimaku_subtitle_provider.dart` 的 `search` 对每条再列 1~2 次文件，第一个 429 就让整次搜索作废（手动面板的 HTTP 429）。
  2. 「映画」前缀零命中：TMDB 日文标题「映画ドラえもん のび太のワンニャン時空伝」在 Jimaku 模糊搜索零结果，去掉前缀即命中条目 3592。
  3. 只刮了 TMDB 的动画电影被判真人：`scraped_subtitle_targets.dart` 的 `identityDiscoveryCategory` 无 AniDB/AniList id → movie，provider 只发 `anime=false`，动画条目永远搜不到（自动补字幕失败）。另：「Doraemon Movie 25」的 25 被当集号当成 S01E25 发出。
- **[x] ① 已修复** — 引擎 `jimaku_client.dart` 新增 `jimakuQueryVariants`（去剧场版前缀变体）、`pickJimakuEntriesForTitles`（按标题相关度最多列 3 个条目）、`JimakuAnimeFilter.liveActionFirst`（movie/tv 先真人、空了再动画）；app 与 fushi_server 两份 Jimaku provider 都接上；电影条目列文件不带集号；后续条目限流时返回部分结果。单文件电影的补字幕目标与播放页工作台不再带文件名里的「集号」。CLI 补 `video sub-fetch` / `sub-search` / `sub-get`（与刮削后自动补同一个服务）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/jimaku_subtitle_provider_rate_limit_test.dart`（62 条目只列 ≤3 次文件且选中 3592、前缀变体、TMDB-only 电影两档、部分限流 / 首条限流）、`fushi/test/media/video/scraped_subtitle_targets_test.dart`（单文件电影不带集号）。
- **备注**：修复后用真 key 对真 Jimaku 实测：自动补路径 7 次请求、面板路径 4 次请求，均拿到两条日语字幕。新 CLI 路由未在运行中的 app 上实跑（本机装的是旧版，需新版 app 才有这几条路由）。
