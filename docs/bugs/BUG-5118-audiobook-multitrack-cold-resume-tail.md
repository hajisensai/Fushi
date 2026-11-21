## BUG-5118 · audiobook-multitrack-cold-resume-tail
- **报告**：2026-11-22（外部审计 HBK-AUDIT-036，Codex 2026-11-21 PR 审查，源自 PR #3846）
- **真实性**：✅ 真 bug。多文件有声书冷启动 `AudiobookPlayerController.load()`（`fushi/lib/src/media/audiobook/audiobook_controller.dart:1358`，修前 :1345）恢复存档时调 `splitGlobalMs(savedMs, _fileDurationsMs, lastFileDurationMs: _knownLastFileDurationMs)`；但 `_knownLastFileDurationMs`（:1041）要求 `_player.currentIndex == 末文件` 且 just_audio 已报时长，load 刚 `setAudioSource(preload: false)` 时恒为 null，于是末文件上界退回 cue 估算（末句 `endMs`）。存档落在末句之后的片尾静音 / 音乐里时被夹回末句，重开跳回末句。PR #3846（BUG-5006）只修了「已在播末文件时拖进度条」这条路径。新加测试在修前红：`currentFilePosition.positionMs` 期望 60000 实得 8000。
- **[x] ① 已修复** — load 用 `splitGlobalMs(..., clampLastFile: false)` 保留目标文件与文件内偏移；上界改在平台首次激活报出该文件真实时长时施加：`_updateCurrentCue` 的 `ActivationRestoreTick.unreachable` 分支（:2409）显式 seek 到该文件真实末尾，不再把越界位置交给平台自行处置。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_multifile_global_position_test.dart` 组「cold start resumes into the last file tail (HBK-AUDIT-036)」：纯函数拆分、冷启动片尾存档（load 后与首次激活后都在文件 1 的 60000）、越界存档在平台报出真实时长后夹到 100000。
- **备注**：真机验证未做（冷启动片尾续播需真实多文件书）。
