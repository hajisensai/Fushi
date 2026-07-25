## BUG-1072 · galgame 手动补录把干净原件降级成 loopback 混音
- **报告**：2026-07-25（用户：屋上の百合霊さん 制卡音频「能不能从游戏的语音重播按钮拿，更准确」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:1117` `finishLineRecapture()`：收束补录窗口时**无条件**写 `backend: 'system_loopback'` + `clearResourceId: true`，且 `startLineRecapture()` 只判断“当前源不是 loopback 就临时开一路 loopback”，全程不看引擎资源层是否可用。

  后果与用户意图相反：hook 资源层正常（`rawVoiceReady`）时，该行本已配到**引擎原始语音原件**（混音前、无 BGM/SE、与游戏归档字节一致）；用户点浮窗 ⏺「重播并录音」并在游戏里重播后，收束逻辑把这份原件 `clearResourceId` 丢弃，替换成补录窗口录到的**系统混音**。补录越补越差。

  次生缺陷（同一根因的另一面）：`startLineRecapture()` 在 loopback 起不来时直接 `return false`，即使引擎资源层可用、用户重播本可产出原件，也整个拒绝开窗口。

- **[x] ① 已修复** — `finishLineRecapture()` 收束时**先**查补录窗口内新落盘的资源（新增 `EngineHookGalAudioSource.findVoiceResourceSince()` + 纯函数 `pickVoiceResourceSince()`，只认 `since` 之后落盘、排除 BGM/SE），命中即以 `backend: 'game_resource'` + `resourceId` 锁定该行（并清 `_manualRecaptureLines` / `_lineVoiceCache` 防混音切片抢先、清 `_pendingResourceMatches` 防延迟时间戳匹配改回去），取不到才回退原 loopback 路径；`startLineRecapture()` 在 loopback 不可用但 `rawVoiceReady` 为真时仍放行开窗口。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_hook_line_latency_recapture_test.dart`：新增「补录窗口内重播出的原始语音原件优先于 loopback 混音（不再把干净原件降级）」，断言 `game_resource` / `matched` / `resourceId` 正确、`grabRecentCalls` 不再增加（不冻结混音）、`debugIsManualRecapture` 为 false，且制卡向资源层要字节；原「补录绑定 loopback」用例保留，守住无资源时的降级行为。`hibiki/test/mining/galgame_paired_voice_test.dart`：新增 `pickVoiceResourceSince` 纯函数 4 例（取窗口内最新、旧资源不借用、BGM/SE 与非法命名排除、textseq 原件命中）——纯函数因此可在 Linux CI 单测，不依赖 Windows dump 目录。
- **备注**：本 bug 属 PR #394（`worktree-gal-overlay-replay-latency`，draft）自身引入的设计倒置，在同一分支修正。
  与之相关的**上游事实**（另案，见交接）：用户样本《屋上の百合霊さんフルコーラス》为 Will/AdvHD 系引擎（`.xfl` 归档 + `vorbis.acm`），exe x86，imports 只有 `MSACM32.dll` / `WINMM.dll` / `ole32.dll` / `GDI32.dll` —— **不含 dsound / XAudio2**，现有通用音频采集对它全部落空，只能降级 loopback。该引擎的资源级支持需在 `hajisensai/hibiki-hook` 另开一引擎一任务。
