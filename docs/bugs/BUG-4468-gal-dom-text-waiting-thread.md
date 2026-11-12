## BUG-4468 · TyranoScript DOM 正文在线时工作台仍显示等待选择台词线程
- **报告**：2026-11-11（用户：「没有线程但是有文字和音频」——yurialice（TyranoScript/Electron）工作台满屏 `tyrano_dom` 行、部分带 DOM 语音，状态卡却停在「等待选择台词线程 · 尚未选择线程」，句级音轨面板被「需选线程」卡替掉）
- **真实性**：✅ 真 bug。`galWorkbenchReadiness`（`fushi/lib/src/pages/implementations/game_shared.dart`）只按「有引擎源 && 未选线程」判 `waitingForThread`；TyranoScript DOM 源在线时（`GalHookSessionController.tyranoDomTextOnline`）正文与语音由 DOM 源按句给出、根本不读 LunaHook 文本道，判据却没把它算进去。`shouldPromptGalCaptureSetup` 同一缺口，会在 DOM 在线时仍弹选线程设置。
- **[x] ① 已修复** — 会话控制器新增 `requiresTextThreadSelection`（= `hasEngineSource && !tyranoDomTextOnline`），两个判据改吃它（参数改名 `requiresTextThread`），工作台 / 游戏库状态条 / 自动弹窗三处调用点统一；DOM 第一句正文翻转该判据时 `notifyListeners()`，工作台立即刷新。
- **[x] ② 已加自动化测试** — `fushi/test/pages/game_shared_readiness_test.dart`（DOM 正文在线 → listening、不弹选线程）；`fushi/test/mining/gal_hook_session_controller_test.dart`「DOM 正文在线后不再要求选台词线程，并通知工作台刷新」。
- **备注**：线程下拉框本身仍列 LunaHook 观测到的线程（DOM 在线时引擎文本道照常观测、只是不作正文），未改。
