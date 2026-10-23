## BUG-3665 · tmdb-parent-series-year-leaks
- **报告**：2026-10-23（用户：「怎么没让我决策的，又说没刮削出来」→「全部根本性修复，然后pr」）
- **真实性**：✅ 真 bug。AniDB 身份的续作季 / 剧场版年份显示成 TMDB 剧本体首播年（響け！2/3 → 2015、Re:ゼロ 第四季 → 2016、哆啦A梦剧场版 → 1979）。根因：AniDB 只有目录摘要时主源 `year` 为空；`_tmdbLookupFromMapping` 经 Fribb 拉的是整部 TMDB 剧（不看 `season.tmdb`），`video_metadata_merge.dart` `supplementVideoMetadata` 以 `primary.year ?? supplement.year` 补空，剧本体的 year / premiered / endDate / status / 集数季数全部漏进这一部分。
- **[x] ① 已修复** — `supplementVideoMetadata` 新增 `supplementPart`：补充源是整部剧时这些本体级标量不补空，年份 / 首播日改取对应季（`VideoMetadataSupplementPart`）；协调器 `_tmdbSupplementPart` 按 Fribb 行判定（剧场版挂在剧下 / 季号≠1 / 集偏移>0，且补充源就是映射的那部剧）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_metadata_merge_test.dart`（parent-series supplement does not leak series-level scalars）；`fushi/test/media/video/metadata/offline_identity_coordinator_test.dart`（sequel season takes its own TMDB season year；变异实测：不传 supplementPart 即红）。
- **备注**：同批还有 BUG-3662（CLI candidates 只过滤不搜）。本机数据已用 CLI 手工改绑修复。
