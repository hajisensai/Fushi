## BUG-3422 · anime-download-seed-year-suffix
- **报告**：2026-10-16（用户反馈 4Np5-EyJgE：番剧下载搜不到已刮削的条目）
- **真实性**：✅ 真 bug。`media_collection_detail_page.dart` `_openDownloadDialog`（未绑 anilistId 时）与 `_downloadRelation` 把合集名/关系边标题原样当搜番词预填；刮削合集名带年份后缀 `FX戦士くるみちゃん (2026)`，AniList 按整串匹配返回 0 条。根因 `anime_download_dialog.dart` initState 的 `_animeQueryCtrl.text = seedQuery`。
- **[x] ① 已修复** — 预填前经 `animeSearchSeedQuery` 剥掉尾部 `(YYYY)` / `（YYYY）` / `[YYYY]`（中间的年份、纯年份保持原样）。提交见提交记录（Feedback: 4Np5-EyJgE）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/anime_download_dialog_initial_context_test.dart`（widget 预填 + 纯函数边界）。
- **备注**：同批 iFzLzVLYAd 已由 d8830baef6（BUG-3328）修复，本条不涉及。
