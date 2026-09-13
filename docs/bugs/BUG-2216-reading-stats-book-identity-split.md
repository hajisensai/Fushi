## BUG-2216 · 删书/同名书时按书统计分裂成两条同名条目
- **报告**：2026-09-06（用户：审查「小说统计是否会出现异常」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/stats/stat_facts.dart:158-171`（legacy 阅读日行按 title 反查库表：`bookByTitle` 同名后者覆盖前者 → 一本书的历史错贴给另一本；反查失败 → `mediaKey=''` 独立成组）+ `reading_statistics_page.dart:316-323` / `stat_period_detail_sheet.dart:121-137` 裸按 `identityKey` 分组——视频域走了 `stat_shared.dart:244-307` 的 unique-title 吸收而阅读域没有。删书（不删段）后同一本书在按书列表 / 时段明细里裂成两条同名条目；库里同名两本时 legacy 行贴到后一本。
- **[x] ① 已修复** — 阅读域复用视频域同一套 `groupStatRowsByIdentity` 契约：新增 `groupStatFactsByIdentity`（`stat_shared.dart`），阅读统计页「按书」与时段明细 sheet 都走它（legacy 无身份行在行宇宙里唯一身份组占用该 title 且不在 `ambiguousTitles` 时并入，否则独立成无身份组）；`stat_facts.dart` 新增 `uniqueBookKeyByTitle` / `ambiguousBookTitles`，`loadStatFacts` 与三处页面反查表都只收「库里恰好一本」的 title，同名 ≥2 本不贴给任意一本；`StatPeriodDetailResolvers.ambiguousTitlesOf` 把库表同名否决传进 sheet，删除键取组内 legacy 行的 title。 提交：`bef9747e30`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reading_stat_identity_test.dart`（同名两本各有身份不合并 / 删书后重导 legacy 行并入唯一身份组 / 歧义独立成组 / 库表同名否决 / 组序）+ `fushi/test/database/study_segments_test.dart`「legacy 阅读行反查库表身份：恰好一本 → 补 bookKey；同名两本 → 身份留空」。
- **备注**：
