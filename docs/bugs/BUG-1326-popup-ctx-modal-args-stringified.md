## BUG-1326 · 调整上下文回点制卡永远点第一个词条

- **报告**：2026-08-01（用户：视频里点「上下句」调整后点制卡没反应）
- **真实性**：✅ 真 bug。根因 `hibiki/assets/popup/popup.js:2862`（修复前）：

  ```js
  window.flutter_inappwebview.callHandler(
      'openSentenceContextModal',
      JSON.stringify({ entryIndex: idx, matched: matched }));
  ```

  这是 popup.js 里**唯一**一处把 `callHandler` 参数 `JSON.stringify` 的调用（其余
  `duplicateCheck` / `setSentenceContext` / `favoriteEntry` … 全部原样传对象），而宿主
  handler 只认 Map（`dictionary_popup_webview.dart:1870` 的 `args[0] is Map`）。参数落成
  String → 整个 `if` 不进 → `entryIndex` 恒退化成 `0`、`matched` 恒为空：

  - 「确认制卡」经 `mineEntryByIndex(0)` 永远去点**第一个词条**的 `.mine-button`。用户在第
    2、3 个词条上点「调整上下文」，确认后自己那条毫无变化 = 「没反应」（而第一个词条可能
    被莫名制了一张卡，或弹出它的已制卡操作单）。
  - 对话框里「当前句」中查到的词不高亮（`matched` 为空，`SentenceContextDialog` 退化）。

  既有守卫 `test/pages/sentence_context_modal_guard_test.dart` 只 `contains('entryIndex')`
  字符串扫描，抓不到参数被包了一层 —— 典型的源码扫描假绿。

- **[x] ① 已修复** — popup.js **三镜像**（`hibiki/assets/popup/popup.js`、
  `hibiki/assets/browser_extension/vendor/popup.js`、`tools/browser-extension/vendor/popup.js`）
  改为原样传 `{ entryIndex, matched }` 对象；宿主侧新增纯函数 `decodeBridgeMap`
  （`dictionary_popup_webview.dart`）兼容 Map 与 JSON 字符串两种形态，使用户浏览器里**未同步
  更新的老扩展 vendor 副本**也不会再静默退化。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/lookup_dismiss_barrier_dialog_test.dart`：
  `decodeBridgeMap` 三形态单测（对象 / JSON 串 / null·非法串·数组）+ 三镜像源码守卫（正则
  钉死「不得 stringify」且「必须传对象字面量」）。
- **备注**：与 BUG-1327（同一操作路径上的主因：根 Overlay barrier 吃掉对话框点击）同 PR 修复。
