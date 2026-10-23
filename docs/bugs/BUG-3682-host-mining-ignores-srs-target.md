## BUG-3682 · 互联主机替对端制卡仍写 Anki，不遵守 Fushi 复习挖词目标
- **报告**：2026-10-23（任务 O 补测试时发现：PR #2464 声称主机侧远程制卡遵守 SRS 目标）
- **真实性**：✅ 真 bug。#2464 加了 `hostMiningAnkiRepositoryProvider`（`fushi/lib/src/anki/anki_view_model.dart`）与 `AppModel.hostMiningAnkiRepository` getter，main.dart 也注入了委托，但 getter **没有任何调用方**：`_AppModelRemoteLookupService`（`fushi/lib/src/models/app_model.dart`）的 `mineEntry` / `_withForwardedMiningContext`（`mineForwarded` + `prepareForwardedSourceNote`）/ `readSourceNote` / `patchSourceNote` / `isDuplicate` / `openWordInAnki` / `mineImmersion` 仍直接 `_appModel.platformServices.createAnkiRepository()`。主机挖词目标是 Fushi 复习时，浏览器扩展与已配对对端「制卡到主机」的卡仍写进主机已弃用的 Anki，查重 / 回到出处也查的是 Anki。
- **[x] ① 已修复** — 上述七处改读 `_appModel.hostMiningAnkiRepository`；note type 编辑 / 媒体去重仍有意走裸 Anki（对端在配置主机的 Anki 本身）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/host_mining_target_test.dart`：真 ProviderContainer + main.dart 同形接线，经 `createRemoteMiningService()` 驱动；目标 = 复习时 mineEntry / mineForwarded 落复习、不写 Anki，查重与出处先读复习；目标 = Anki 或模块关时行为与原来一致。变异实测：还原 app_model.dart 后复习组用例变红。
- **备注**：无 UI 改动，不需设备复测。
