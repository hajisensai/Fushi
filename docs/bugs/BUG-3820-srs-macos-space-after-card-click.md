## BUG-3820 · macOS 点过卡面后空格不翻面（键盘桥可被卡片脚本截走 + 加取证）
- **报告**：2026-10-27（用户：应用内反馈 OO3O-3ljda，macOS 3.0.1-debug.20797，导入的 Lapis 模板，正面点一下后空格无反应）
- **真实性**：⚠️ 部分确认（缺 macOS 真机，根因未定论）。
  - 已确认的路径：macOS 上点进卡面后 WKWebView 持有 first responder，Flutter 收不到按键（`reader_fushi/caret.part.dart:63` 同一事实），空格只剩页内键盘桥（`webview_key_bridge.dart` 生成、`srs_card_face.dart` `_injectBridge` 注入）。截图显示点按切出了悬浮顶栏（`_onCardTapEmpty`），没有查词弹窗（排除 `guardBridgeToken` 吞键）。
  - 已确认的结构缺口（`fushi/lib/src/focus/webview_key_bridge.dart:186` 修前 + `srs_card_face.dart` `onLoadStop`）：桥挂在 `document` 捕获阶段，并且在 `onLoadStop` 里**晚于**首张卡的 `__fushiSrsSetCard`（`_sync.shellLoaded()` 先发）才注入。卡片模板脚本挂在 `window` 捕获阶段、或比桥更早注册的 keydown 监听调了 `stopPropagation`，桥就收不到空格——卡片模板是不受宿主控制的第三方脚本（Lapis 等）。这是否就是 OO3O-3ljda 的成因**未验证**（手头没有那份 Lapis 模板）。
- **[x] ① 已修复（结构性加固 + 取证）** —
  - 键盘桥写进卡面外壳 `<head>`（`srsCardShellHtml` 的 `bridgeScript`，先于一切卡片内容执行），并挂在 `window` 捕获阶段（`webViewKeyBridgeScript(listenOnWindow: true)`，SRS 卡面专用，阅读器 / 漫画等其它宿主不变）：DOM 派发的第一站，卡片脚本的监听全在它之后。`onLoadStop` 的重放只刷新键表。
  - 取证：外壳加 `kSrsCardKeyDiagScript`——空格 / Enter 在页面里按下却没被桥接走时，松开那刻经 `onSrsKeyDiag` 报原因（`editable` / `composing` / `missed`），记 `SrsWebCardFace.keyNotBridged`（每面卡封顶 5 条）；复习页记 Flutter 焦点离开 / 回到本页与窗口视图焦点变化（`SrsReviewPage.focus`，每页封顶 12 条）。下一次反馈据此能分清：键没进 WebView（只有焦点日志）/ 进了页面但被放行（keyNotBridged）/ 桥接走了却没翻面（两者都没有）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_card_autoplay_gate_harness.mjs`（经 `srs_card_autoplay_gate_test.dart` 调起）真 Chrome：生产外壳 + 卡片脚本在 `window` / `document` 捕获阶段 `stopImmediatePropagation`，CDP 投递真实空格，断言桥仍把 `Space` 交回宿主。变异：桥改回挂 `document`（仍在 `<head>`）→ 红，且取证脚本如期报出 `{"code":"Space","reason":"missed"}`；还原后绿。
- **备注**：未在 macOS 真机复测原始路径。若用户升级后仍复现，看日志里 `SrsWebCardFace.keyNotBridged` / `SrsReviewPage.focus`：都没有 = 空格根本没进 WKWebView（first responder 在别处），需要 macOS 原生侧（`makeFirstResponder`）或嵌入层排查。
  另：桥本来就拦卡面上的 Enter / 空格（修前挂 document 捕获、命中即 preventDefault，卡面里聚焦按钮按 Enter 也不会激活），行为未变；Chrome harness 里原「Enter 激活按钮 = 键盘手势」那条之前没装桥才成立，改用桥不拦的 `a` 键验证键盘手势。
