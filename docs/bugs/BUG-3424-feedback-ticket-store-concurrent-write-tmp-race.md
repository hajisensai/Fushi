## BUG-3424 · feedback-ticket-store-concurrent-write-tmp-race
- **报告**：2026-10-15（用户：合并批次复盘时点名的 develop 偶发红）
- **真实性**：✅ 真 bug。`fushi/lib/src/feedback/feedback_store.dart:201-215`（修前）`FeedbackTicketStore.write` 固定写 `<文件>.tmp` 再 rename，没有串行化：打开详情时的「已读」落盘与「从本机移除」（`FeedbackService.forget` → `_persist`）并发时，先完成的那次把 `.tmp` rename 走，后一次 rename 抛 `PathNotFoundException`（CI run 38623761442 / 38577812956，`feedback_pages_test.dart`「横屏宽屏左列表右详情分栏，移除后退回占位」）。测试的同步点也拿错：`settleIo(() => f.tickets.isEmpty)` 在 `forget` 改完内存时即成立，落盘还没写完测试就收尾删临时目录。
- **[x] ① 已修复** — 同一文件路径的写入按调用顺序串行（静态 `_writeTails`，按路径而非实例），最后一次调用为准；测试同步点改成 `forget` 返回后才发生的右栏退场（`FeedbackDetailPage` 消失）。提交：待提交
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_service_test.dart`「同一清单并发写入：依次落盘不互相挪走临时文件，最后一次调用为准」（20 次并发写；变异实测：还原成修前实现即红）。
- **备注**：
