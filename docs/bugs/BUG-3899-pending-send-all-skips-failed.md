## BUG-3899 · 待发卡片「全部发送」跳过失败卡，提示 0/0/0
- **报告**：2026-10-29（用户：反馈 NYjj59uzBY，Android + AnkiDroid，700 张失败卡）
- **真实性**：✅ 真 bug。`fushi/lib/src/anki/pending_mining/pending_mining_anki_repository.dart:289`（基线 896d45a9b2）`_flushAll` 只遍历 `_store.sendable()`（`pending` / `sending`，不含 `failed`），`remaining` 也只数 `sendable`；队列里全是失败卡时「全部发送」一张不发，报「已发送 0、失败 0、剩余 0」，与列表矛盾，只能逐张重试。AnkiMobile 路径 `_startAnkiMobileSend` 同样只把 `sending` 退回 `pending`。
- **[x] ① 已修复** — `flush(interactive: true)`（用户点「全部发送」/ 控制通道 `anki pending send`）连 `failed` 一起重试：`PendingMineStore.sendableIncludingFailed()`（排除已交给落地设备的卡，BUG-2778 同口径）；遇不可达就停，没轮到的失败卡保持 `failed` 与原错误。AnkiMobile 的「全部发送」把失败卡退回 `pending` 再拉起。自动补发（回前台 / 启动 / 制卡成功顺带）仍不碰失败卡。提交 d633c28275（PR pr/fb-mining）。
- **[x] ② 已加自动化测试** — `fushi/test/anki/pending_mining_anki_repository_test.dart`（三条「反馈 NYjj59uzBY」用例：全部发送重试失败卡、报告与列表一致、自动补发不碰；不可达时没轮到的保持 failed；AnkiMobile 拉起失败卡）。
- **备注**：AnkiDroid「Unknown URL content://…」本身的根因（provider 不在 / 用户已改用 Fushi SRS）缺日志，未查；「批量删除待发卡」是功能请求，不在本条。
