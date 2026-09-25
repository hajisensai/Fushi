## BUG-2677 · 自动模式下校准采集被误报为没有台词
- **报告**：2026-09-25（用户：游戏已附着、台词正常获取，但在对话校准里采集样本，提示「当前没有可采集的台词」）
- **真实性**：✅ 真 bug，既有问题。日志显示档案模式为 `auto`。工作台在自动模式下也显示校准入口（`gal_attached_lookup_workbench.dart` 注释写明自动模式也要能准备样本），但 `GalAttachedTextController.canCaptureCalibrationSample` 和 `_calibrationCaptureSnapshot` 要求 `calibrationManuallyEnabled`（只有「仅校准层」模式成立），`applyMeasuredCalibration` 又要求 `canCalibrate`，同样只在该模式成立。所有拒绝都映射到 `sourceNotReady`，界面显示成「没有台词」。另外，Fushi 在前台时，native 的握手检查先于 `targetBackground` 判断，状态可能停在 `input_shield_rehandshake_pending`，同样会被拒绝。`applyMeasuredCalibration` 的成功判定写的是 `shieldHandshakePending`，但 native 上报的原因是 `input_shield_rehandshake_pending`，握手中应用会被误判为失败。
- **[x] ① 已修复** — `39aad348ea`：新增 `sampleCalibrationEnabled`（自动或仅校准层模式），截图采集和应用测好的档案都用它；需要在游戏上点击确认的实时校准仍然只在「仅校准层」模式下可用。查词层已隐藏且处于待握手状态时允许采集。有台词但查词层未就绪时，改报新的 `surfaceNotReady`，显示对应提示并写日志。应用成功判定补上 native 实际上报的原因。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_attached_text_controller_test.dart`：自动模式可采集、可应用，实时校准仍被拒；关闭和仅原生几何模式不可采集；隐藏的待握手状态可采集，握手不可用时拒绝。`fushi/test/pages/gal_lookup_samples_dialog_test.dart`：`surfaceNotReady` 显示新提示，不再显示「没有台词」。
- **备注**：未实机复验，需用户在自动模式下重新采集确认。
