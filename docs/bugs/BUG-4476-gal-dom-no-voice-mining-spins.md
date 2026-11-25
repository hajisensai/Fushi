## BUG-4476 · TyranoScript 无语音行制卡时浮窗制卡按钮长时间转圈
- **报告**：2026-11-11（用户：「点制卡按钮以后会卡住」「制卡按钮一直在制卡状态」，那一句没有语音；yurialice（TyranoScript/Electron）+ 游戏内查词实测排版路线）
- **真实性**：✅ 真 bug（部分）。本机 `%TEMP%\hibiki_glookup.log`：无语音行每次 `mineEntry` 到回复都要 1.6–1.7s。其中一次（12:35:08 → 12:35:17）用了 9s，结果恰好在游戏窗口转到后台的那一刻返回。已确认的根因：`fushi/lib/src/mining/gal_hook_session_controller.dart` 的 `_captureAudioBytesNow` 不理会 DOM 语音仲裁的「这句无语音」定论。它照样进 `_waitForPairedResourceAudio`：domOwned 行的 resourceId 一直是 null，于是空等完整个资源等待窗（默认 1.2s），然后再走 PCM / Loopback 兜底链。而制卡动图采样（`sampleWindowAnimationFrames` 的 `targetDuration`）要等本句音频有结论才收口，所以浮窗按钮一直转。
- **[x] ① 已修复** — 新增 `_tyranoDomLineHasNoVoice`：DOM 管辖的行，语音组 events / inFlight / resourceIds 都为空时，制卡取音直接返回 null（记 `audio.dom_no_voice`），行状态保持 unavailable。语音组找不到（已淘汰 / 文档重载）时不下结论，仍走原有链路。
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_hook_session_controller_test.dart`「DOM 已定论无语音：制卡取音立即返回，不空等资源窗、不走兜底链」（资源等待窗设为 30s，5s 内必须返回）。
- **备注**：9s 那一次只有 1.2s 能用这个根因解释。剩下的时间结束在游戏转后台的那一刻，很像窗口截图（WGC，每帧最多等 1.5s 新帧）在等一个静止不重绘的 Electron 全屏窗口出帧。日志里没有截图诊断，**未证实**；需要复现时同时记下截图诊断，再单独定根因。
