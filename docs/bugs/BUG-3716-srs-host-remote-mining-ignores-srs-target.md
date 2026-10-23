## BUG-3716 · 互联主机替其它设备制卡时无视「制卡目标 = Fushi 复习」
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：互联主机替其它设备制卡时，无视「制卡目标 = Fushi 复习」的设置。
- **真实性**：✅ 真 bug。根因：`app_model.dart` 的 `_AppModelRemoteLookupService.mineEntry / mineForwarded / readSourceNote / patchSourceNote` 直接用 `platformServices.createAnkiRepository()`，不看制卡目标；修复改走 `hostMiningAnkiRepositoryProvider`（`anki_view_model.dart`）。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[ ] ② 未加自动化测试** — 无专门测试
- **备注**：配线层改动，待补测试。
