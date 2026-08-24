## BUG-1800 · SGRE 内嵌查词短按 Shift 在轮询间隙被漏掉
- **报告**：2026-08-24（用户：SGRE 已注入但无法触发内嵌查词）
- **真实性**：✅ 真 bug。真实 SGRE 会话中 helper、IPC、Luna 已知线程和字形几何均已就绪（`lookup_diag=0x00200003`），鼠标位于已捕获字形矩形内时短按 Shift，`lookup_hit_count` 仍保持 0。根因是 `native/galgame_hook/hook/adapters/sgre_lookup.inc:325` 只读取 `GetAsyncKeyState(VK_SHIFT)` 的当前按下高位；完整落在 HookWorker 两次 16 ms 轮询之间的按下/释放会被永久漏掉。
- **[x] ① 已修复** — `native/galgame_hook/hook/adapters/sgre_lookup.h:44` 同时消费 `GetAsyncKeyState` 的高位按下状态和低位“自上次调用后按过”状态，且保持长按只提交一次（本提交）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/sgre_adapter_test.cpp:124` 覆盖长按边沿、轮询间隙内完成的短按和空状态指针；定向 CTest 通过（本提交）。
- **备注**：首个失败边界是 lookup hit 提交；本轮不改文本、音频、弹卡或制卡状态机。
