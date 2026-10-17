## BUG-3493 · 复习牌组列表：子牌组名字被行首图标与整格缩进挤没、空默认牌组删不掉又常驻
- **报告**：2026-10-17（用户：应用内反馈，Android 手机截图 360dp 宽；另一条反馈「default 牌组无法删除」）
- **真实性**：✅ 真 bug（名字被挤没）+ 设计如此（默认牌组不可删）。根因：
  - `fushi/lib/src/pages/implementations/srs/srs_deck_list_page.dart` `_DeckRow.build` 的 `leading`：每深一层右移 `tokens.spacing.card`（16）再画 40dp 的 `FushiListLeadingIcon`，加上行首 16 间距；行尾三色计数（3×32 + 间距）与 ⋯ 菜单固定约 176dp。360dp 屏上名字列只剩约 120dp − 层级占宽：二级被截成「JP-…」，三级起宽度归零只剩数字。
  - 默认牌组：`packages/fushi_engine/lib/srs/srs_db_store.dart` `deleteDeck` 对 `defaultDeckId` 抛 `StateError`（制卡 / 导入 / 删牌组移卡 / apkg 导出 id=1 都拿它兜底），列表菜单因此不给删除项——这是对的（Anki 同样不许删 id=1 的默认牌组），但它空着时仍常驻列表顶部。
- **[x] ① 已修复** — 行首去掉图标，层级改为每层 10dp 的细竖线（`SrsDeckIndentGuides`，最深一条有学习 / 到期卡时用主色）；默认牌组照 Anki `hide_default_deck`：没有卡、没有子牌组、且不是唯一顶层牌组时不在列表显示（`srsVisibleDecks`，`fushi/lib/src/srs/srs_providers.dart`），仍不可删。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_pages_test.dart`：「空的默认牌组在有别的顶层牌组时隐藏」（真库：有卡 / 有子牌组时照常显示）、「手机宽度下多级子牌组的名字仍有宽度，行首不放图标」（360dp，五级牌组每层名字宽 > 60、缩进宽度契约、计数列右缘各层对齐）。
- **备注**：同 PR 还加了复习卡面音频自动播放（反馈 wJd6qNLrhV，功能请求，不算 bug）。
