## BUG-4128 · 查词页结果区点 ✓ / ☆ / ↗ 静默无反应，没句子的旧卡覆写不了
- **报告**：2026-10-26 / 2026-11-03（应用内反馈 pcBy9h7D3_、-xJWu33WgJ，Windows；后者在 3.3.0-debug.23080 + Lapis 上复报「查词结果区制的卡 Sentence 为空，未解决」。截图：搜索框整句「働き手として専用できるような状態に置く」，結果区「専用」词条已是 ✓ 状态——就是 BUG-3216 原报告里那张修复前制的卡）
- **真实性**：✅ 真 bug。BUG-3216 只给结果区的「+」（`onMineEntry`）和「覆写最新卡」（`onUpdateEntry`）补了源文本例句；卡**已存在**时点 ✓ 走的是另一条桥：
  - `fushi/lib/src/pages/implementations/popup_settings_injection.dart:1286` 对所有 app 内弹窗注入 `__fushiMinedCardActionNative = true`，popup.js（`assets/popup/popup.js` `hasNativeMinedCardAction`）据此把 ✓ 交给宿主 `minedCardAction` 桥、不画页内面板；
  - `fushi/lib/src/pages/implementations/home_dictionary_page.dart:1947` 结果区 `DictionaryPopupWebView` 从没接 `onMinedCardAction`，`dictionary_popup_webview.dart:3347` 桥于是回空 `MinePopupResult`：不弹「覆写 / 新增 / 查看」操作单，什么都不做。
  - 结果：修复前制的那张没句子的卡，在结果区永远覆写不了，用户看到的一直是「没有句子」。同一处还漏接了 `onOpenInAnki`（↗）、`onFavoriteEntry` / `onFavoriteCheck`（☆）、`onOpenAdvancedMining`（高级制卡按钮不出现）、`onQueueOverwrite`，☆ / ↗ 同样点了静默无反应。浮层各层（`DictionaryPageMixin.buildNestedPopupLayer`）全都接了。
- **[x] ① 已修复** — 结果区补齐与浮层同一套回调：✓ 操作单经 `onMinedCardAction(_withSourceSentence(fields))`（覆写 / 新增重复卡都带源文本那一句），`onQueueOverwrite` 同口径；↗ / ☆ 直接接 mixin 的 `onOpenInAnki` / `onFavoriteEntry` / `onFavoriteCheck`；高级制卡入口抽成 `DictionaryPageMixin.advancedMiningOpenerFor(webViewKey)`，浮层与结果区共用（确认后回点该 WebView 的「+」，仍经 `onMineEntry` 补句）。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/dictionary_webview_mined_card_action_wiring_guard_test.dart`：扫 `lib/` 下每个 `DictionaryPopupWebView(...)` 调用，凡接了 `onMineEntry` 的必须同时接 `onMinedCardAction` / `onOpenInAnki` / `onFavoriteEntry` / `onFavoriteCheck`；并断言结果区 ✓ 路径带源文本例句。修复前源码上红（实测报 home_dictionary_page 缺 4 个回调）。
- **备注**：未在真机复测（本轮无 GUI 验证）。用户手里那张旧卡需要在结果区点 ✓ →「覆写」才会补上句子。
