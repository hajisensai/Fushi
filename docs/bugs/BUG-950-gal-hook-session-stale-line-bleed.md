## BUG-950 · galgame hook 会话重启后旧行串入新会话且新文本被当重复静默丢弃
- **报告**：2026-07-21（PR#295 落地审查 H1，fable5 沿代码路径核验）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:1247-1289`：`_pollHookedText` 循环体内 `await grabUtterance` / `_cacheLoopbackForLine` 挂起期间发生 stop/重启后未复检 `engine != _engineSource`——旧会话行经 `receivedAt` 混过 `isLineInCurrentSession` 串入新会话；且 :1289 把新会话已重置的 `_lastTextSeq` 覆写成旧大 cursor，新会话后续文本被判 duplicate 静默全丢。
- **[x] ① 已修复** — `_pollHookedText` 循环内 grabUtterance/grabClipNear/_cacheLoopbackForLine 的 await 归来后、推进 `cursor` 之前，加 `if (engine != _engineSource) return;` 复检：期间发生 stop/重启则当前迭代属旧会话，立即收手，绝不推进 cursor（因此循环末尾 `if (cursor > _lastTextSeq) _lastTextSeq = cursor;` 也不会把新会话已重置的 seq 倒灌成旧大值）。
- **[x] ② 已加自动化测试** — 源码守卫 `test/mining/gal_hook_session_controller_test.dart` 的 `_bug950Guard`：断言循环末尾 cursor 推进点紧邻前存在 `engine != _engineSource` 复检 + BUG-950 标记（跨异步 gap + 私有 `_lastTextSeq` 的时序 bug 无法确定性注入，行为验证留真机轮，守卫防复检被误删）。
- **备注**：Windows-only 功能，行为面随真机验收轮最终确认。
