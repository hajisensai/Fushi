## BUG-2084 · 工作台渐进折叠只看缓冲区尾巴，同句两次重绘之间被其它线程插队就断链
- **报告**：2026-09-03（SGRE 窗口模式真机：SGRE exact 线程先出半句、再出整句，两条之间 WideCharToMultiByte 线程喷了几条 `normalrubytextruby…` 系统串；工作台里半句与整句各留一条，且配到同一份 game_resource 语音）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/texthooker_service.dart` `appendLine` 的回吞循环只取 `_entries.last`，`tail.textThreadKey != textThreadKey` 即 `break`——只要别的线程（并行 hook / 系统串）在同一句的两次快照之间插了一条，折叠就不发生。BUG-2067 修的是折叠**之后**列表分词缓存不刷新，这条是折叠**本身**没触发。
- **[x] ① 已修复** — 回吞改为「向前找同端点（source / sourceLabel / textThreadKey 三段全等）的最近一条」（`_lastIndexOfEndpoint`，回看上限 32 条），命中后 `removeAt` 该条、其它端点的行原地保留；折叠判据（前/后缀、`kMinFoldableLength`、排版刷新）与身份/语音继承规则不变（本提交）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/texthooker_progressive_fold_test.dart`：半句 → 3 条系统串线程 → 整句，结果整句回吞到最早那条（id 不跳）、系统串三条原地保留；隔着别的线程的两句无关台词仍不折（本提交）。
- **备注**：真机看到的「ねぇね」只有 3 字，按 `kMinFoldableLength = 4` 的「过短不折」规则本来就不参与折叠——那是防「任何长句都可能以短语开头」的既定规则，不在本条内。
