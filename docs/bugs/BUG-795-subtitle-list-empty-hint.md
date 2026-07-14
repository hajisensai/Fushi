## BUG-795 · 字幕列表收藏/已选档结果为空误显示未加载字幕
- **报告**：2026-07-14（用户：截图 SweetSub Oniichan ha Oshimai! 06，右侧字幕列表「收藏」档 0 句时显示「未加载字幕」，但画面明明有字幕）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_jump_panel.dart:533`：build 里 `cues.isEmpty || visibleIndexes.isEmpty ? _buildEmpty(cs)`，把「字幕本体一条都没有（真未加载）」与「字幕已加载但当前过滤档（收藏/已选）筛出 0 条」混为一谈，两者都走 `_buildEmpty`→`widget.emptyHint`（`video_subtitle_list_empty` = "未加载字幕"）。用户处于收藏档 + 0 收藏，`cues` 非空但 `visibleIndexes` 空 → 误报未加载。
- **[x] ① 已修复** — 提交 `3df8a3dca`。`_buildEmpty` 增 `cuesLoaded` 参数（`cues.isNotEmpty`），新增 `_emptyHintForFilter`：真未加载（`!cuesLoaded`）或「全部」档（全量映射，空只可能因 cues 空）仍用 `emptyHint`；收藏档为空 → `video_subtitle_filter_favorites_empty`（"暂无收藏的句子"），已选档为空 → `video_subtitle_filter_selected_empty`（"还未选择句子"）。两 i18n key 经 `tool/i18n_sync.dart` 加入 17 语言并 `dart run slang` 重生成。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_jump_panel_test.dart`：BUG-795 三例（收藏档为空显示 favorites-empty 且不显示 emptyHint；已选档为空显示 selected-empty；全部档 cues 真空仍显示 emptyHint）。撤修复验证：前两例变红，第三例保持绿。
- **备注**：「全部」档无需专属空文案——`VideoSubtitleListFilter.all` 是 cues 全量映射，筛出 0 条当且仅当 cues 本身为空（真未加载），emptyHint 正确。
