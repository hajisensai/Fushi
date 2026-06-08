## BUG-141 · 查词弹窗下次查词滚动位置未重置
- **报告**：2026-06-08（用户：查词弹窗的滚动位置在下次查词的时候没重置）
- **真实性**：✅ 真 bug。沿真实代码路径定位：BUG-080/BUG-094 后查词弹窗会保留一个常驻 warm `DictionaryPopupWebView`，每次查词只通过 `didUpdateWidget()` / `_pushResults()` 把新的 `lookupEntries` 注入同一个 DOM。`_pushResults()` 对不同查询调用 `window.renderPopup()` 替换内容，但没有先清掉 `window.scrollY` / `documentElement.scrollTop` / `body.scrollTop`，所以用户把上一次结果滚到底部后，下一次查词会继承旧 WebView 的滚动位置。根因：`hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:363`。
- **[x] ① 已修复**：新查词渲染前执行 `window.__hoshiResetPopupScroll()`，同时把 `window`、`document.documentElement`、`document.body` 三处滚动位置归零；同一查询的加载更多仍走 `window.updatePopupIncremental()`，保留当前位置。
- **[x] ② 已加自动化测试**：`hibiki/test/pages/dictionary_popup_webview_test.dart` 增加滚动生命周期源码守卫，锁定非加载更多路径必须在 `window.renderPopup()` 前重置滚动，加载更多路径仍不得跳回顶部。
- **备注**：真实 WebView 滚动行为归设备/集成验证；本轮完成了可稳定落地的注入脚本契约测试，并通过目标 Flutter 测试。
