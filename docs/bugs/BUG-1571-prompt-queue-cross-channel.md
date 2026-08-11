## BUG-1571 · 双通道同步弹窗单飞槽跨通道丢候选
- **报告**：2026-08-12（用户：互联/同步深审计 P1-5）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/deletion_prompt.dart:285`（`if (dialogOpen) return false;`，`shouldPrompt` 直接判掉且**不** `_markDismissed`）与 `fushi/lib/src/sync/sync_conflict_prompter.dart:25`（同款）。
  触发路径：`fushi/lib/src/sync/sync_auto_trigger.dart:394` 的双通道 sweep **逐通道**调 `onReport` → `fushi/lib/src/models/app_model.dart:571` `presentSyncPrompts` → 同一个 prompter 的 `present()` 在同一次 sweep 内被调两次。云通道的 barrier 弹窗还开着时，互联通道那批候选被单飞位判掉并**静默丢弃**——既不 snooze、也不重排、也不推进基线，就是没了。
  删除确认那侧后果更重：它与「删除墓碑消费基线」推进复合——被挡下的那批候选在下一轮若已落在基线之下（另一批候选先被复核过、基线被推到更高水位），那批删除**永远不再出现**。
- **[x] ① 已修复** — `fushi/lib/src/sync/sync_conflict_prompter.dart` 新增 `PromptQueue` mixin（串行队列 `enqueuePrompt`），`SyncConflictPrompter` 与 `DeletionPromptPrompter` 都 `with PromptQueue`，`present()` 改为把真正的呈现逻辑 `_presentNow()` 排到队尾：后到的那批在前一个弹窗关闭后接着弹，一条也不丢。单飞位 `dialogOpen` 与既有 snooze 语义原样保留（队列已保证 `_presentNow` 跑到时 `dialogOpen == false`）。队列对异常免疫（一个弹窗炸了不卡死后续），异常仍从 `present()` 返回的 future 抛给调用方。提交 `e53681ead0`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/prompt_queue_cross_channel_test.dart`（4 条）：两通道先后 present → 关掉第一批后第二批**仍然弹出**；第二批被取消时只推进第一批的基线水位；前一个弹窗抛异常不断链；两个 prompter 都 `isA<PromptQueue>()`（类型检查，不是源码扫描）。变异实测：把 `present()` 里的 `enqueuePrompt(...)` 换成直接调 `_presentNow(...)`（还原旧行为）→ 3 条红。
- **备注**：与 BUG-1552（自动 sweep 逐通道异常隔离）是同一处双通道结构上的两个不同缺口：1552 管「一条通道抛异常不拖垮另一条」，本条管「一条通道的弹窗不吞掉另一条的候选」。
