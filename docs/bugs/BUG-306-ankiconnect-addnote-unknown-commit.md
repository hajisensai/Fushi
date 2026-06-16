## BUG-306 · AnkiConnect addNote 响应断开后 popup 先失败再后验成功
- **报告**：2026-06-16（用户：TODO-448「导出卡片的时候会先失败，再成功」）
- **真实性**：✅ 真 bug。沿真实代码路径定位到 `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` 的 `addNote` response-phase connection reset 会被当作普通失败上抛，`packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart` 没有在请求可能已送达时按 Anki 真实状态对账；同时 `hibiki/assets/popup/popup.js` 对失败/不确定的 `mineEntry` 结果仍安排 1s 后 `duplicateCheck`，若 Anki 实际已建卡，就会把用户刚看到的失败后验改成已制卡。
- **[x] ① 已修复** — 本提交：AnkiConnect 请求加 `Connection: close` 降低 stale socket；`addNote` response-phase 连接断开改成显式 unknown-commit 异常，不盲重试；repository 仅在 `allowDupes=false` 且制卡前首字段查重确认无重复时做一次 `findNotes` 对账，唯一命中才返回 `MineOutcome.success(noteId)`，无命中/多命中/允许重复都返回明确不确定失败；popup 不再对失败/不确定结果安排 delayed duplicateCheck。
- **[x] ② 已加自动化测试** — `packages/hibiki_anki/test/ankiconnect_service_test.dart` 覆盖短连接请求头与 response-phase reset 分类；`packages/hibiki_anki/test/ankiconnect_commit_unknown_test.dart` 覆盖唯一命中转 success(noteId)、无命中/多命中/allowDupes=true 不冒充成功；`hibiki/test/utils/misc/popup_asset_behavior_test.js` 覆盖失败/不确定结果不再 delayed duplicateCheck 改成功。
- **备注**：不新增 APKG 功能，不改 AnkiDroid 行为；不确定结果仍提示用户检查 Anki 后再重试。
