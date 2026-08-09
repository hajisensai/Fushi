## BUG-1466 · Re Zero 罗马字标题无法通过 TMDB 严格识别
- **报告**：2026-08-09（用户：）
- **真实性**：✅ 真 bug。实际失败 run 记录为 `No candidate passed title, type, year and season gates`。TMDB 作品 65942 的普通详情只给一个 85 集 Season 1，而正确的第 3 季 16 集位于 alternate episode group；旧 resolver 只检查普通 seasons，因此拒绝了正确作品。
- **[x] ① 已修复** — `video_metadata_provider.dart:60-72` 增加 episode-group 能力；`video_metadata_resolver.dart:281-306` 在普通季校验失败后按本地季号/集数解析 group；`tmdb_video_metadata_provider.dart:228-339` 选择 TMDB season-type group，并把 group 内顺序映射成 S03E01-E16；协调器在 `video_source_scrape_coordinator.dart:390` 传入本地集数。
- **[x] ② 已加自动化测试** — `video_metadata_provider_contract_test.dart` 覆盖 85 集主季 + 16 集 S03 group 映射；`video_metadata_resolver_test.dart` 覆盖严格门通过并保存 `episodeGroupId`。
- **备注**：对齐 MoviePilot 的 TMDB canonical episode skeleton，不放宽标题精确匹配，也不跨主源回退。
