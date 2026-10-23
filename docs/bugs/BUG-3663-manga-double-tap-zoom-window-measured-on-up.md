## BUG-3663 · 漫画双击缩放很难触发，总是切出悬浮栏（只有快速三击偶尔成功）
- **报告**：2026-10-21（用户：应用内反馈 IDF2uWUvlf，iOS 3.0.0+19763 iPhone 402x874@3；「Difficulty With Double Tap Zoom」）
- **真实性**：✅ 真 bug，Android 同样受影响（同一份页内 JS）。`fushi/lib/src/media/manga/manga_overlay_html.dart:2381-2401`（develop 329a739431）：双击只在第二击**松手**时判（`_consumeDoubleTap` 比较两次松手时间 ≤ DBL_MS=300ms），而第一击挂起的 onTapEmpty 定时器也是从第一击松手起算 300ms。第二击按住约 100ms，等于留给「松手→再按下」的间隔只剩约 200ms；稍慢一点，定时器在手指还按着时就发出 onTapEmpty（切悬浮栏），第二击松手又被当成新的第一击——缩放落空。快速三击时第二、三击凑成一对，所以偶尔能放大。Android `GestureDetector` 的 DOUBLE_TAP_TIMEOUT 是「第一击松手 → 第二击按下」。
- **[x] ① 已修复** — 新增 `_armDoubleTapOnDown`，在 pointerdown 时判：挂起的空白单击仍在窗口内且第二击离第一击不超过 DBL_SLOP，就当场取消挂起的 onTapEmpty 并武装双击，`_consumeDoubleTap` 松手时见武装即缩放（原「两次松手」判据保留）。查词 / 热区翻页仍零延迟。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_zoomed_tap_zone_js_test.dart`（跑生成文档里的真实 `_onTap` / `_armDoubleTapOnDown`）：第二击按下在窗口内、松手超窗仍缩放且不发 onTapEmpty；离得太远不算双击；按下晚于窗口各算单击。
- **备注**：未在 iOS 真机复测手感。
