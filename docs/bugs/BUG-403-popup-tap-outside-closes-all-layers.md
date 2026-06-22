## BUG-403 · 点查词弹窗外面一次关掉整个嵌套栈（应只关最顶层一层）

- **报告**：2026-06-22（用户：）
- **真实性**：✅ 真 bug。根因在「点弹窗外」的接线层而非关栈原语本身。逐层关原语 `BaseSourcePageState.dismissTopPopup()`（`hibiki/lib/src/pages/base_source_page.dart:574`，`_dismissPopupAt(_lastVisiblePopupIndex)` 只关最顶层、保留父层；光标 B/Esc 已在用，见 `reader_hibiki_page.dart:662`）早已存在；`_dismissPopupAt(index)`（:497）天然分流——`index>0` 只 `dismissAt(index)` + `onDictionaryStackChanged()`（保留父层），`index==0` 才清栈 + `onAllPopupsDismissed()`（会话收尾）。但三处「点外」入口都直接调清整栈的会话级路径：
  - reader：barrier `onTap`（`base_source_page.dart:335`）与弹窗 `onTapOutside`（:425）都调 `clearDictionaryResult()`（:289 = `_dismissPopupAt(0)`，reader 覆写 :1811 还清 `_lookupCue`/句缓存/收藏并触发会话收尾）。
  - video：`_onDismissBarrierTap`（`video_hibiki_page.dart:2127`）末尾 `_popNestedPopupAt(0)`（index<=0 隐藏热槽 + 丢全部子层 → `stackEmpty` → 恢复播放/清草稿）。
  - mixin（视频/首页查词共用）：`buildNestedPopupLayer` 的 `onTapOutside: () => onPop(0)`（`dictionary_page_mixin.dart:340`）写死 index 0。

  结果：嵌套查词（在弹窗里再查词）状态下点弹窗外面，本应逐层退回父层，却一次清空整栈并触发会话收尾。
- **[x] ① 已修复** — 只改「点外」接线，**不动** `clearDictionaryResult` 本体（仍被 X 关闭 / 返回键 / `onDictionaryDismiss` / 「从本句播放」等会话级路径用）：
  - reader：`base_source_page.dart` barrier `onTap`（:335）与弹窗 `onTapOutside`（:425）从 `clearDictionaryResult` 改为 `dismissTopPopup`（:574 现成，`index>=0` 守卫，仅热槽 `_lastVisiblePopupIndex=-1` 时安全 no-op）。
  - video：`video_hibiki_page.dart` `_onDismissBarrierTap`（:2127）`_popNestedPopupAt(0)` 改 `_popNestedPopupAt(_topVisiblePopupIndex)`（:2099 = `_popup.lastVisibleIndex`，与同文件返回键 :2318 同款语义）。
  - mixin：`dictionary_page_mixin.dart` `onTapOutside`（:340）`onPop(0)` 改 `onPop(controller.lastVisibleIndex)`（`dictionary_popup_controller.dart:112`；-1 时 `dismissAt(-1)` 安全 no-op）。

  逐层关到最后一层（index 0）时自然落到清栈分支，触发会话收尾（reader `onAllPopupsDismissed` / video 恢复播放+清草稿+收回焦点）。BUG-072 续播、热槽保留、草稿/收尾「仅 index 0」三条不变。提交哈希：`6c1fbf152`（含本 doc 哈希回填的后继提交见分支 HEAD）。
- **[x] ② 已加自动化测试** — 行为测试 `hibiki/test/pages/popup_tap_outside_layer_test.dart`：用 `debugPopupStack` 构造两层可见栈，模拟 barrier `onTap` / 弹窗 `onTapOutside` → 断言栈 2→1 保留父层、`onAllPopupsDismissed` 未触发；再点一次 → 栈空 + 会话收尾触发；撤修复（直接调 `clearDictionaryResult`）应一次清空（红）。源码扫描守卫扩展 `hibiki/test/pages/dictionary_child_popup_close_guard_test.dart`：断言「点外」四处路径（base barrier `onTap` / base `onTapOutside` / mixin `onTapOutside` / video `_onDismissBarrierTap`）调逐层关原语（`dismissTopPopup` / `lastVisibleIndex` / `_topVisiblePopupIndex`），不再写死 `clearDictionaryResult` / `onPop(0)` / `_popNestedPopupAt(0)`。
- **备注**：嵌套弹窗的真实渲染/点击坐标命中是 WebView 产物，widget 测试照不到几何；逐层关行为本身（栈深度 + 会话收尾）已由 `debugPopupStack` 行为测试在 Dart 层覆盖。最终交互（在弹窗内查词→点外→退回父词、再点外→关）建议真机/模拟器肉眼确认一次。
