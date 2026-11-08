## BUG-4243 · 服务端复习状态的笔记数不随写入刷新
- **报告**：2026-11-08（服务端 Fushi 复习端到端测试：WebUI / `GET /api/admin/srs` 显示 11 条笔记，库里实际 13 条）
- **真实性**：✅ 真 bug。
  - 根因：`packages/fushi_server/lib/src/server_srs.dart` 的 `ServerSrsProfile.noteCount` 只在 `applyConfig` 发现 profile 时从同步位置里各设备报的数（`srsListRemoteProfiles` → `info.noteCount`，设备上次发布时的数）赋一次，库打开后再也不更新。服务端自己写库（AnkiConnect / 互联制卡）、设备再同步进来，`toJson` 的 `notes`（`:240`）和远程复习握手的 profile 列表（`:363`）都停在旧数。
- **[x] ① 已修复** — 每轮同步成功后按服务端这份库重数（`_round()` 成功分支 `noteCount = await s.userNoteCount()`，`server_srs.dart:171`；服务端写库和设备写入都会触发一轮）；库开着时 `applyConfig` 不再用设备报的旧数覆盖（`:495`）。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/server_srs_test.dart`「note count follows the served store after server writes and device uploads」：真 SrsStorage + 本机互联目录，服务端加卡、设备加卡同步、重新套用配置后数都对。去掉修复行该用例失败（Expected 1, Actual 0）。
- **备注**：重建服务端后在模拟器环境复测：AnkiConnect `addNote` 后 `GET /api/admin/srs` 的 `notes` 从 14 变 15，与 AnkiConnect `findNotes` 数一致。
