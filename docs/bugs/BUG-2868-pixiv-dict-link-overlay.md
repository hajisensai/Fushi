## BUG-2868 · app 外查词窗（含 galgame 内嵌卡）点词典外链没反应
- **报告**：2026-10-01（用户：galgame 游戏内查词卡里 Pixiv Light 词条「pixivで読む」点了跳转不了，附截图）
- **真实性**：✅ 真 bug。popup.js 对 http(s) 链接一律 `preventDefault` 后 `callHandler('openLink', url)`（`fushi/assets/popup/popup.js` `openExternalLink`，结构化内容 `<a>` 与 MDX 原始 HTML 锚点 `handleGlossaryAnchorClick` 两条路径都走它）。只有 app 内弹窗（`dictionary_popup_webview.dart`）注册了 `openLink`；app 外查词窗（Ctrl+D 全局查词、galgame 游戏内查词卡、悬浮字幕点词共用 `GlobalLookupController._onJsMessage`，`fushi/lib/src/lookup/global_lookup_controller.dart`）没有这个分支，消息被静默丢弃 → 点外链毫无反应。所有词典的外链都受影响，Pixiv 只是最常见的（每条词条都有「pixivで読む」）。
  - 同卡里的父条目链接「←ハニートースト」是 `?query=ハニートースト`（MarvNC/pixiv-yomitan `addParentInfo.ts`），走 `onLinkClick` 嵌套查词，`_onJsMessage` 有分支；代码路径上未发现问题，本次未真机复现其失败。
- **[x] ① 已修复** — 新增共享实现 `fushi/lib/src/utils/misc/dictionary_external_link.dart`（`openDictionaryExternalLink`：只放行带 host 的 http/https，`externalApplication` 交系统浏览器，异常不外漏）；`_onJsMessage` 补 `openLink` 分支；app 内弹窗的私有 `_openExternalLink`（原先放行任意 scheme）改用同一实现。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/dictionary_external_link_test.dart`：URL 判据（Pixiv 日文/空格路径放行、`javascript:`/`file:`/`?query=`/`entry://` 拒绝）、launcher 调用与异常收口，以及 popup.js ↔ 两个宿主 `openLink` 接线的源码守卫。
- **备注**：未在真游戏里点链接复测（本机无该游戏会话）；`openLink` 消息经原生 `global_lookup_window.cpp` 的 WebView2 桥原样转进 Dart，不需改原生层。
