## BUG-956 · galgame 制卡串行队列异常毒化后所有后续制卡永久挂起
- **报告**：2026-07-21（PR#295 落地审查 M4，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:727-746` + `gal_hook_mining_coordinator.dart:115-136`：串行队列 `_tail = _tail.then(...)` 无 `catchError` 归位，catch 块自身抛出即毒化队列，后续所有制卡 `await` 永久挂起。
- **[ ] ① 未修复** — 修法方向：`_tail` 链尾接 `catchError` 归位为已完成 Future。
- **[ ] ② 未加自动化测试** — 单测：入队任务抛出后再入队新任务断言仍执行。
- **备注**：全仓同模式（whenComplete 自等/链毒化）值得一并审计，见 PR#291 备忘。
