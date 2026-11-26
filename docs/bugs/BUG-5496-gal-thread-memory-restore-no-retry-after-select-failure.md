## BUG-5496 · Galgame 记忆的文本线程一次选择失败后本会话不再恢复
- **报告**：2026-11-23（用户：GitHub #4290 / 反馈 7vGmtj4A1t，《魔法少女ノ魔女裁判》Unity + Naninovel JIT hook；冷启动附着后记忆的台词线程不自动恢复，游戏已在对话中再附着则 1–3 秒内恢复）。
- **真实性**：✅ 真 bug（代码路径确认；反馈现场的事件日志未附，是否正是本条触发未实测）。`fushi/lib/src/mining/gal_hook_session_controller.dart` `_maybeRestoreTextThread`：发起 `selectTextThread` **之前**就把 `_textThreadMemoryApplied` 置 true，回调里 `selected == false` 时直接 `return`、不复位；之后每次线程目录 / 行数变动再进 `_maybeRestoreTextThread` 都在 `if (_textThreadMemoryApplied || ...) return;` 处退出，本会话再也不恢复。冷启动时 JIT hook 线程刚登记、native helper 侧尚未接受选择正是 `selectTextThread` 返回 false 的窗口。`_maybeAutoSelectEngineExactThread` 同样先置位，失败后会堵死记忆恢复。
  - 反馈里另一个可能原因（候选线程须出满 `_textThreadRestoreMinLines = 3` 行才恢复，现场那条线程上线时 `observedLines=1`）是设计门限，不改。
- **[x] ① 已修复** — 两条自动选择路径在 native 拒绝（`selected == false`）时把恢复状态复位到发起前（记忆恢复：`_textThreadMemoryApplied = false`；引擎精确接管：发起前无选择时还原 `_textThreadMemoryApplied` 原值），让下一次目录 / 行数变动重试；用户在飞期间亲选过线程、或引擎源已换（停止 / 降级 / 重新附着）时不动。
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_hook_session_controller_test.dart`「a remembered thread is restored again after native rejects the first select」：假引擎第一次 `selectTextThread` 返回 false，之后照常出行，断言再次发起选择并最终恢复到记忆线程、记 `text.thread_memory_restored`、记忆不被改写。
- **备注**：未在真机原始路径（冷启动附着该 Unity 游戏）复测；修复后若仍不恢复，需看事件日志确认是不是 3 行门限未满足。
