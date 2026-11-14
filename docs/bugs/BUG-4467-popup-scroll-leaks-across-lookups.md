## BUG-4467 · 查词弹窗滚动位跨查词残留（app 外 / galgame 根 iframe；同词缓存命中）
- **报告**：2026-11-11（用户：「上一次查词滚动了一段，下一次还是那段」；怀疑弹窗一直重建）
- **真实性**：✅ 真 bug（沿代码路径确认，两条独立路径）。
  1. app 外查词窗 / galgame 内嵌查词：TODO-1095 让根 iframe（固定 id `global-lookup-root`）跨查词、跨关窗常驻，但 `fushi/assets/popup/global_lookup_host.js` 的 `beginLookup`、根卡 renderJs、`renderPopup` 都不归零文档滚动——BUG-141 的 `__fushiResetPopupScroll` 只写在 in-app 注入块（`dictionary_popup_webview.dart` `_inAppStaticExtrasJs`）。同词命中缓存时 `renderPayload` 判 contentChanged=false 连重渲染都没有，原样停在上次位置；换词也只靠浏览器夹紧。
  2. app 内热槽：同一个词再查且本地缓存命中时拿回**同一个** `DictionarySearchResult` 实例，宿主同一帧里 复位→beginTop→fillResult，`DictionaryPopupWebView.didUpdateWidget` 只按结果身份判（`oldWidget.result != widget.result`）→ 不推送、不归零；`refreshCurrentResult` 也按身份判「已渲染」让宿主立刻翻出旧滚动位。根因：「新查词会话」靠结果身份推断，控制器的会话代次从没传给 WebView。
  - 「一直重建」不成立：顶层换词复用同一把 GlobalKey 的热槽 WebView，没有冷建；观感来自「就绪才显示」模式的 屏外→占位卡→淡入（有意设计，是否改成原地换内容属 UI 取舍）。
- **[x] ① 已修复** — popup.js 定义唯一的 `window.__fushiResetPopupScroll`（含停滚轮缓动、清 pending），in-app 删掉 Dart 那份重复定义；`global_lookup_host.js` 抽 `resetRealmScroll`，`beginLookup`（新会话唯一边界）与停驻 realm 复位共用；控制器给每个查词会话发全局唯一 `DictionaryPopupEntry.lookupSession`，经 `DictionaryPopupLayer` 传给 `DictionaryPopupWebView`，同结果新会话（非占位）全量重推、`isLoadMore` / `refreshCurrentResult` 都按会话判。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/global_lookup_host_test.mjs` #48（同词 / 换词 beginLookup 归零、嵌套子卡不动父卡、旧文档兜底；修复前红）；`fushi/test/pages/popup_pending_scroll_restore_test.js` #6（真执行 popup.js 的归零）；`dictionary_popup_push_dedup_test.dart`「lookup session」组；`dictionary_popup_controller_test.dart` lookupSession 唯一性。
- **备注**：真实 WebView / 真机 galgame 复测未做（本轮只读审查 + node / widget 测试）。
