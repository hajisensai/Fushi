## BUG-2756 · 收藏夹里的收藏词只有词形，没有释义和上下文
- **报告**：2026-09-28（用户：「收藏夹里单词真的只是单词，没释义和上下文。」附截图：收藏词 normie 的详情只有词形和书名）
- **真实性**：✅ 真 bug，两段根因：
  - 释义为空：`fushi/assets/popup/popup.js` 的 `createFavoriteButton` 只把 `{expression, reading}`
    交给 `favoriteEntry` 桥，Dart 侧 `onFavoriteFromPopup` / `onFavoriteEntry`
    （`fushi/lib/src/pages/base_source_page.dart`、`dictionary_page_mixin.dart`）取
    `fields['glossary'] ?? ''` 恒为空；app 外覆盖窗（`lookup/overlay_stat_source.dart`）写死 `glossary: ''`。
  - 上下文为空：`favorite_words` 表（`packages/fushi_core/lib/src/database/tables.dart`）只有
    词形 / 读音 / 释义 / 归属书，根本没有原句与定位列，收藏那一刻宿主手上的查词句被丢掉。
- **[x] ① 已修复** — commit `870c6b5148c`：
  - popup.js 收藏时按词典分段取纯文本释义快照（`favoriteGlossaryText`，与制卡同一过滤：隐藏词典 /
    重定向条目不进）随桥带回；覆盖窗桥透传释义与捕获句。
  - schema v114：`favorite_words` 加 `sentence` + `section_index` / `norm_char_offset` /
    `norm_char_length`（与收藏句同口径的锚点）。宿主经 `favoriteLookupContext` 提供上下文：阅读器
    = 当前句 + 选区时刻章号 + 句子章内范围；视频 = 查词字幕句 + 集下标 + cue 起点 / 时长。
  - 收藏夹：词行在词形下显示原句、副标题显示释义首段；详情显示读音 / 释义 / 原句；带锚点的词行
    可跳回原文、播原句音频（音频匹配用原句而不是词形）。同步 wire 可选带上原句。
- **[x] ② 已加自动化测试** — `fushi/test/database/migration_v114_favorite_word_context_test.dart`（迁移 +
  新列读写）、`fushi/test/pages/favorite_words_in_collections_test.dart`（列表行显示原句、详情显示
  释义与原句、分类筛选）、`fushi/test/lookup/overlay_stat_source_test.dart`（覆盖窗带释义与原句）。
- **备注**：存量收藏词没有记过上下文，不回填，仍只显示词形与（若有）释义。真机未复测。
