## BUG-4966 · 有声书刚打开时拖进度条拖不动，要先播一下才能拖
- **报告**：2026-11-21（应用内反馈 ymMpf0raAu 的附带诉求；拍板台 ymMpf0raAu 要求单独开 bug）
- **真实性**：待复现（代码路径上高度可疑，未在设备上复现）。疑似根因：`AudiobookController.load` 用 `preload: false` 设源（`fushi/lib/src/media/audiobook/audiobook_controller.dart:1293` 一带），平台要到第一次 play 才真正载入，此前 `_player.duration` 为 null；拖进度条走 `seekGlobalMs` / `seekMs` → `_seekWithinFile`，在 `audiobook_controller.dart:1789` 的 `if (dur == null || dur.inMilliseconds <= 0) return;` 直接早退，物理 seek 不下发、位置不变，表现为「拖不动」。播过一次后时长就绪，之后正常。修法方向：未激活时把拖动目标记成激活落点（与 BUG-3496 的 `_activationRestoreTarget` / `initialPosition` 同一条路，时长未知时按 cue 估算的文件时长夹取），而不是丢弃；需先在 Windows（media_kit）与 Android 各复现一次确认。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — 可落在 controller 单测：preload:false、未 play 时 seekGlobalMs 后 position / 首次 play 的落点应为拖动目标。
- **备注**：拍板台 ymMpf0raAu 的主体（书籍模式跳转记录进按钮布局）已在同一 PR 完成；本条单独跟踪。
