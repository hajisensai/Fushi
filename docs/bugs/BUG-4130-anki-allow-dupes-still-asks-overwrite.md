## BUG-4130 · 勾了「允许重复」，点已制卡 ✓ 仍弹覆写 / 新增选择框
- **报告**：2026-10-29（用户：kanjieater，GitHub issue #2633 经 fushi-bot 转为应用内反馈 E0sdqm4h-F；Android S25U，v3.0.0）
- **真实性**：✅ 真 bug。app 内点 ✓ 的宿主编排收口 `fushi/lib/src/anki/anki_mined_card_action_sheet.dart` `runAnkiMinedCardAction`（修前 943 行起）不读 `AnkiSettings.allowDupes`，有命中就弹 `showAnkiMinedCardActionSheet`；设置说明写的是「添加卡片时跳过重复检查」，用户开了仍被拦。popup.js 里唯一读 `window.allowDupes` 的分支只在「没有桥」的退化宿主里，且 Dart 从未注入这个全局，是死判据。
- **[x] ① 已修复** — `runAnkiMinedCardAction` 开头读 `repo.loadSettings().allowDupes`，开着就直接 `mineNew()`（调用方已带 `AnkiMiningPayload.withAllowDuplicate`），不反查、不弹框；✓ 显示不变。两条 app 内车道（`base_source_page.dart` / `dictionary_page_mixin.dart`）都走这一处。
- **[x] ② 已加自动化测试** — `fushi/test/pages/anki_mined_card_action_sheet_widget_test.dart`「允许重复：点 ✓ 直接新增，不反查、不弹选择框」与「不允许重复：有命中照旧弹选择框」。
- **备注**：app 外裸窗 / 浏览器扩展的页内面板（popup.js `runInPageMinedCardAction`）和「最新可改」✓⤺ 原地覆写这两条没改：前者宿主侧拿不到同步的 Anki 设置（弹窗注入只读 AppModel），后者是用户主动的「改上一张」功能。真机未复测。
