## BUG-3902 · 桌面键盘「上一句」几乎总退化成回退 3 秒
- **报告**：2026-10-31（用户：应用内反馈 zNlCBVuISX，Windows，扩展源视频；手机按钮 / 电脑双击左侧正常）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_player_controller.dart` `prevSeekDecisionFor`（原判据 `gapMs = pos - cues[prev].startMs`）：键盘入口 `videoPrevSubtitleDegradesFarCue(keyboard) == true` 走 TODO-085「上一句太远就回退 seekSeconds 秒」，但「远」量的是上一句**起点**到当前位置 = 上一句时长 + 句间隙 + 当前句已播时长，普通连续对话也恒 > 3s，于是 Ctrl+← 几乎总退成 3 秒时间 seek；按钮 / 双击 / 手柄走 `degradeFarCueToTimeSeek: false`，所以正常。
- **[x] ① 已修复** — 判据改为「上一句**结束**到当前语境起点的静默」：落在上一句的下一句里时取该句起点（当前句已播多久与上一句远不远无关），落在 gap 里取当前位置。TODO-085 的远句退化保留（长静默 / 转场仍回退 3 秒）。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_test.dart`（`prevSeekDecisionFor` 组：连续对话不退化、当前句前长静默仍退化、锚定偏前落点、阈值边界改为按静默计）。
- **备注**：同条反馈的「字幕延迟按系列记忆」是需求，未做，交回产品拍板。
