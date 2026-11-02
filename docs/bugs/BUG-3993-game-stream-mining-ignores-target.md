## BUG-3993 · game-stream-mining-ignores-target
- **报告**：2026-11-02（用户：samutw，AYN Thor 接收端串流 Windows 主机，制卡提示「The host failed to add the card; check Anki on the host」）
- **真实性**：✅ 真 bug。主机挖词目标是 Fushi 复习（`srs_mining_target_install_default = srs`）、未配 Anki 牌组；AnkiConnect 本身在线。根因 `fushi/lib/src/models/app_model.dart` `createGameStreamMiningAdapter` 用裸 `platformServices.createAnkiRepository()`，不像互联转发 / 浏览器扩展那样走遵守挖词目标的 `hostMiningAnkiRepository`，于是每张串流卡都发往没配置的 Anki 而失败。叠加 `fushi/lib/src/sync/game_stream_mining.dart` 只在 `failureReason` 非空时记日志，后端拒卡（原因在 `MineOutcome.errorDetail`）时主机日志一片空白。
- **[x] ① 已修复** — 适配器改用 `hostMiningAnkiRepository`；后端拒卡时把 `outcome.result` + `errorDetail` 记进 `GameStream.mine` 日志（分支 `fix/game-stream-mining-target`）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/game_stream_mining_test.dart`（后端拒卡记日志带原因）+ `fushi/test/build/game_stream_mining_target_guard_test.dart`（适配器必须用主机制卡仓库）。
- **备注**：接收端仍把后端拒卡显示成通用 `host_error` 文案；主机日志现在有真实原因。
