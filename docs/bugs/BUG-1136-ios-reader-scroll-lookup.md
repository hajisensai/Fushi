## BUG-1136 · iPhone 阅读滑动被误判为点词查词
- **报告**：2026-07-27（用户：Codex 会话）
- **真实性**：✅ 真 bug。根因在
  `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:827-913,934-968`：
  `_gestureEnd` 只用按下点与松手点的最终 `dx/dy` 判定 tap，且
  `ReaderSettings.tapSlopPx` 原为 28 CSS px。WKWebView 若没有提供代码所预期的
  PointerMove 序列，TouchMove 只取消图片长按、不取消查词候选；手指已经移出并形成
  滚动后，只要松手回到起点 28px 内，仍会走 `selectText` 触发查词。
- **[x] ① 已修复** — 提交 `8edaf3c7b`。
  - 新增 `gestureExceededTapSlop`，在 `touchmove` 与 `pointermove` 两条真实输入通道
    上累计整段轨迹；一旦越过轻点半径，本次手势永久归为 pan，松手回到起点也不能
    重新变成 tap。
  - 轻点半径从 28px 收紧为 10px 径向距离：保留自然手指抖动，但不再把短促滚动和
    惯性 flick 包进查词点击框。翻页的 44/22px 距离与速度判据不变。
- **[x] ② 已加自动化测试** —
  `hibiki/test/reader/reader_paged_touch_swipe_behavior_test.js` 直接执行生产注入脚本，
  新增 WKWebView 风格的纯 TouchEvent 回归：手指移出 16px 后松手回到起点 3px 内，
  必须 0 次查词；修复前稳定得到 `taps=[203]`，修复后为空。同时保留约 7px 自然
  抖动仍查词、分页长滑翻页、连续模式竖滑不翻页等既有断言。
- **备注**：JS 行为测试与 Flutter 定向测试通过后，仍需 iOS 模拟器/真机沿用户原始
  “正文连续滑动阅读”路径复测手感；未完成设备门前不宣称真机已修好。
