## BUG-4246 · 保存到列表里默认牌组出现两次
- **报告**：2026-11-08（服务端 Fushi 复习端到端测试：「保存到」同时列出「Fushi review · Default / Default deck」和「Fushi review · Default · Default」）
- **真实性**：✅ 真 bug。
  - 根因：`POST /api/mine/targets` 的回包（`packages/fushi_server/lib/src/remote_mining_host.dart` `miningTargets()`）每份复习 profile 只给 `decks` 全名列表，不说哪个是不点名时落进的牌组；手机 `mineToServerTargetOptions`（`fushi/lib/src/sync/mine_to_server_target_picker.dart`）于是先列「默认牌组」，再把同一个牌组按名字列一遍。
- **[x] ① 已修复** — 回包每份 profile 加 `defaultDeck`（配置的制卡牌组，不在了 / 没配 = 库的默认牌组，与 `resolveSrsMiningDestination` 同口径；`remote_mining_host.dart:410-420`，契约注释 `packages/fushi_engine/lib/sync/remote_mining_target.dart`）；手机按它跳过重复项（`mine_to_server_target_picker.dart:105-110`）。老主机不报该字段时照旧全列。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/server_srs_mining_test.dart`（mining_decks 用例里断言两份 profile 的 `defaultDeck`：配置的牌组 / 库默认牌组）；`fushi/test/sync/fushi_remote_mining_client_target_test.dart`「the review default deck is listed once when the host reports it」。
- **备注**：Anki 一栏同样有「默认牌组」+ 各牌组，回包不报 Anki 默认牌组，未改。之前明确选了那个牌组名的用户，对话框里不再有对应项高亮，选择本身仍有效。
