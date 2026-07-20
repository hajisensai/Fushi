## BUG-950 · galgame hook 会话重启后旧行串入新会话且新文本被当重复静默丢弃
- **报告**：2026-07-21（PR#295 落地审查 H1，fable5 沿代码路径核验）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:1247-1289`：`_pollHookedText` 循环体内 `await grabUtterance` / `_cacheLoopbackForLine` 挂起期间发生 stop/重启后未复检 `engine != _engineSource`——旧会话行经 `receivedAt` 混过 `isLineInCurrentSession` 串入新会话；且 :1289 把新会话已重置的 `_lastTextSeq` 覆写成旧大 cursor，新会话后续文本被判 duplicate 静默全丢。
- **[ ] ① 未修复** — 修法方向：await 归来后复检 generation/engine 一致再落行与写 cursor。
- **[ ] ② 未加自动化测试** — 可在 controller 单测中模拟挂起期间重启断言不串行、cursor 不倒灌。
- **备注**：Windows-only 功能，随真机验收轮处理。
