## BUG-4347 · 字幕版本视图文件名被截断，看不出版本差异
- **报告**：2026-11-07（用户：开发者自提，反馈 UMW99yDWTE「显示不完，我选什么」；OnePlus 横屏 792x363）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/subtitle_version_group_list.dart:284-290`（修前）文件行标题 `Text(maxLines: 2, overflow: fade)` + `titleMaxLines: 2`，同一集两份文件前缀相同、区分版本的段在末尾，横屏手机上两条都截在「...HEVC-10bit AAC」。同类的文件视图 `subtitle_search_panel.dart:1745-1763`（修前）按 TODO-673 只放宽到 3 行，窄屏照样切掉末尾——同一规则两份实现、各自一个行数上限，是同一个 bug 的两个副本。
- **[x] ① 已修复** — 新增 `SubtitleFileNameText`（`fushi/lib/src/pages/implementations/subtitle_file_name_text.dart`）作为字幕候选文件名的唯一显示规则：完整软换行、不限行；自身重置 `DefaultTextStyle` 的 maxLines / overflow，不依赖调用点的 `titleMaxLines`。版本视图文件行与文件视图结果行都改用它（`titleMaxLines: null`）。两处都在可滚动 ListView 里，换行只让行变高，不溢出。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_version_group_list_test.dart`「BUG-4347 版本视图文件行完整显示文件名」：792 宽下两份前缀相同的长文件名，断言 RenderParagraph `maxLines == null`、`didExceedMaxLines == false`、行数 > 2（超过旧上限）、无溢出异常；`fushi/test/pages/jimaku_dialog_scroll_test.dart` TODO-673 用例改为在 RenderParagraph 上断言不限行、未截断。
- **备注**：另一种做法「多版本共享前缀时只突出差异段」属 UX 取舍，未做，留待拍板。
