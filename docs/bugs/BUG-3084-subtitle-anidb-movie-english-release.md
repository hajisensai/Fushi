## BUG-3084 · AniDB 主源电影无 tmdb/imdb 时 OpenSubtitles 英文发布名被拒（核查别名是否带英文名）
- **报告**：2026-10-09（#2007 合入后的审查：怀疑 AniDB 的英文 / 罗马音标题没有进入比对用的别名集）
- **真实性**：❌ 未复现：数据已经传到比对处，不需要改代码。沿真实路径逐段核查：
  - AniDB 资料构造 `_SelectedTitles` 时（`packages/fushi_engine/lib/media/video/metadata/anidb_video_metadata_provider.dart:1073-1076`），主标题之外的**全部**语言标题都进 `aliases`，包括 `en` official、`x-jat` main、synonym、short。anime XML 和标题包两路先经 `_mergedTitles`（`:1028`）合并。
  - `_mapAnime`（`:705`）和 `_catalogWork`（`:798`）都原样带出这些别名。
  - 合并 TMDB 补充资料时，`mergeVideoMetadataWorks` 对 aliases 取并集（`video_metadata_merge.dart:57-60`），别名不会变少。
  - 刮削完成后的路径是：`VideoScrapedWorkNotice(metadata:)`（`video_source_scrape_coordinator.dart:1117`）→ `scrapedSubtitleTargets` → `scrapedMediaReference`（`fushi/lib/src/media/video/subtitle/scraped_subtitle_targets.dart`）。最后一步把 `metadata.aliases` 原样放进 `VideoMediaReference.aliases`，`checkSubtitleWork` 再用它组 `targetTitles`。

  所以在 `!confirmed` 分支里，英文发布名能不能被收，取决于两点：AniDB 是否真有这个英文 / 罗马音标题，以及发布名归一后是否和它相等。AniDB 没有英文名、或者发布名用了别的译名时被拒，是「没有证据就不收」的设计结果，不是数据没传进来。按约定不勾 ① ②。
- **[ ] ① 无需修复** — 数据链路完整，没有改代码。
- **[ ] ② 回归测试（未复现条目，不计勾选；随 `f59868a07a` 提交）** — 补了用例把这条链路钉住，防止以后被悄悄截断：
  - `fushi/test/media/video/metadata/anidb_video_metadata_provider_test.dart` 的 `BUG-3084` 用例：用真实 `AniDbVideoMetadataProvider` 处理一部电影，标题包里有 `en` official 和 `x-jat` main。经 `scrapedMediaReference` 后，别名里有英文名和罗马音名，没有 tmdb/imdb；`checkSubtitleWork` 收下英文发布名 `Your.Name.1080p.BluRay.x264-SPARKS.en.srt`。
  - `subtitle_work_identity_test.dart` 补了一条纯判据用例。
- **备注**：以后如果要放宽「AniDB 没有英文名」的情况，应该走 AniDB → TMDB 映射补一个 tmdb id（属于 id 证据），而不是放松标题判据。
