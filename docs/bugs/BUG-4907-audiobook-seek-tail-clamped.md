## BUG-4907 · 有声书进度条拖到末尾（片尾）拖不进去，被夹回末句结束
- **报告**：2026-11-20（用户：应用内反馈 sGoT-tNpkx，截图进度条显示「3:43 / -0:31」，末尾一段拖不到）
- **真实性**：✅ 真 bug。进度条总长 [`totalDuration`] 对末文件取 `max(cue 估算, _player.duration)`（`fushi/lib/src/media/audiobook/audiobook_controller.dart:1009` 修前 1009-1025），但拖动走的 `seekGlobalMs` → `splitGlobalMs`（修前 :1098）把文件内偏移夹到 `_fileDurationsMs[last]`；而 `_fileDurationsMs` 由 `_rebuildFileDurations`（:1560 附近）按 cue 的末句 `endMs` 推算，比真实音频短（片尾静音 / 音乐不在 cue 里）。显示口径与 seek 口径不一致，拖进片尾段一律被夹回末句结束。
- **[x] ① 已修复** — 新增 `_knownLastFileDurationMs`（正在播末文件且 just_audio 已给出时长时的真实时长）与 `_lastFileSpanMs`（末文件跨度 = 估算与真实取大），`totalDuration`、`splitGlobalMs(lastFileDurationMs:)`、`seekGlobalMs` 与 `load()` 恢复位置统一用这一个口径。前序文件仍用 cue 估算（持久化的全书毫秒按它编码，不变）；多文件书在非末文件时总长 = cue 估算之和（修前是 `max(sum, 当前文件真实长)`，等价）。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/audiobook/audiobook_multifile_global_position_test.dart` 的 `drag into the tail beyond the last cue (BUG-4907)` 组：`splitGlobalMs` 纯函数边界；单文件书（cue 到 10s、真实 100s）`seekGlobalMs(95000)` 落到 95000；双文件书在末文件时 `totalDuration` = 10000 + 100000 且 `seekGlobalMs(70000)` 落到文件 1 的 60000。
- **备注**：属播放类修复，未做真机复测（按本机规则不派真机验证）。
