## BUG-3414 · 歌词模式倍速键点击时文字折行跳动
- **报告**：2026-10-14（用户：iOS 竖排歌词模式录屏，点底栏「1.5×」倍速键时按钮在跳）
- **真实性**：✅ 真 bug。录屏逐帧：松手、倍速面板弹出的那 ~4 帧里「1.5×」被挤成「1.5 / ×」两行，随后恢复一行。根因 `fushi/lib/src/utils/components/glass/fushi_expressive.dart` `_RenderFushiSqueeze._widths`：M3E 标准按钮组的按压弹簧 `FushiSpring` 是 `AnimationController.unbounded`，松手回弹冲到 0 以下；`_widths` 只跳过 `p == 0`，负进度让刚松手的按钮宽度 = 基准宽 ×(1 + 0.15p) < 固有宽。工具条外套 `FittedBox`，按钮恰好按固有宽排，少 1.6px 文字就折行（widget 探针：静止 104.4 → 回弹最低 102.8，up7~up14 共 8 帧两行）。另一条同源路径：按下相邻的睡眠定时键时，倍速键按 M3E 设计让出宽度，标签同样折行。
- **[x] ① 已修复** — `_widths` 把按压进度钳到 ≥ 0（所有 M3E 按钮组受益：回弹不再把按钮挤窄）；歌词模式 MD3 `_SpeedButton` 的标签包 `FittedBox(scaleDown)` + `maxLines: 1`，被邻居挤压时缩字而不折行。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_speed_button_press_layout_test.dart`（逐帧断言松手回弹时按钮不窄于静止宽、标签不折行；按下邻居时标签不折行）。还原修复后两条均红（第 7 帧挤窄 / 第 1 帧折行）。
- **备注**：同一录屏里倍速面板本身与背景歌词无位移，只有按钮在跳。
