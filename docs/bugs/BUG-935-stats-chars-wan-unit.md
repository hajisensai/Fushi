## BUG-935 · 阅读统计字符数汇总缺万单位
- **报告**：2026-07-20（用户：mamit / Novel Club）
- **真实性**：✅ 真 bug。阅读统计页把字符数除以 10000 后交给 i18n `stat_format_chars_wan` 补单位（`hibiki/lib/src/pages/implementations/reading_statistics_page.dart:316-321` `_formatChars`），但 12 种非 CJK 语言的译文（含英文，`hibiki/lib/i18n/strings.i18n.json:428` `"$n characters"`）漏掉了「万」倍率标记；图表坐标轴却硬编码「$x万」（`hibiki/lib/src/pages/implementations/stat_charts.dart:34`）。于是英文界面下 192000 字被渲染成「19.2 characters」而非「19.2万 characters」，与坐标轴不一致。KPI 条（今日/本周/日均，`reading_statistics_page.dart:492/497/504`）和日时段图上方的月/总计汇总（`reading_statistics_page.dart:620`）同源共病。仅 zh-CN(万字)/zh-HK(萬字)/ja(万字)/ko(만자) 原本正确。
- **[x] ① 已修复** — 在 12 种非 CJK 语言（en/ar/de/es/fr/id/it/nl/pt-BR/ru/th/tr/vi）的 `stat_format_chars_wan` 值里把「$n …」补成「$n万 …」，与坐标轴的硬编码「万」对齐；CJK 四语言各自用 万/萬/만 表达万位（不动）。改源 json 后 `dart run slang` 重生 `strings.g.dart`。提交见本分支。
- **[x] ② 已加自动化测试** — `hibiki/test/i18n/stat_chars_wan_unit_guard_test.dart`：扫 17 个 slang 源文件，断言每种语言的 `stat_format_chars_wan` 值都含万位标记（万/萬/만），防任一语言再漏倍率单位回潮。`flutter test --no-pub test/i18n/` 全绿。
- **备注**：值 string 本身合法，只缺倍率 token；未新增/删除 i18n key，故按值编辑而非 `i18n_sync.dart`（后者管 key 集增删）。
