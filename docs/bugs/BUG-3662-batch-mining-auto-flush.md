## BUG-3662 · batch-mining-auto-flush
- **报告**：2026-10-16（用户：反馈 _eqP_ypmq8，macOS——开启批量制卡后在阅读器制卡，回到「待发卡片」显示没有待发卡片）
- **真实性**：✅ 真 bug。入队没问题：`PendingMiningAnkiRepository.mineEntry`（`fushi/lib/src/anki/pending_mining/pending_mining_anki_repository.dart` 约 104 行）读 `batchMiningEnabled` 后冻结进 `pending_mine_queue`。但自动补发 `fushi/lib/main.dart` 的 `_flushPendingMines()` → `repo.flush()`（触发点：`didChangeAppLifecycleState(resumed)`、启动后第一帧、`PendingMineRelay.arrivals`）**全程不读这个开关**，`_flushAll` 把可发的行逐张送进 Anki 并出队。桌面上切到别的程序再切回 Fushi 就是一次 `resumed`，所以只要 AnkiConnect 连得上，攒下的卡在用户去看之前就被发走，「待发卡片」计数为 0——与开关文案「制卡先存在本机，之后一次性发送到 Anki」矛盾。
- **[x] ① 已修复** — `flush` / `flushOne` 在非 `interactive` 且批量模式开启时直接返回 `skipped`（判据与入队同读 `inner.loadSettings()`），修在仓库层，三个自动触发点与「直接制卡成功后顺手补发」一并覆盖；「全部发送」与控制通道走 `interactive: true`，照常发送。
- **[x] ② 已加自动化测试** — `fushi/test/anki/pending_mining_anki_repository_test.dart`：「批量模式：自动补发（非交互）不发送，用户点「全部发送」才发」「非批量模式：自动补发照常发送」。
- **备注**：本机作为「接收其他设备的卡片」落地设备且开着批量制卡时，转来的卡同样等用户点「全部发送」，批量语义统一为「点了才发」。
