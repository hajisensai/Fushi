## BUG-929 · ASS 缺失字体在 Windows 上与 mpv 回退不一致
- **报告**：2026-07-20（用户：本机播放列表实测）
- **真实性**：✅ 真 bug。样例 ASS 指定未安装的 `A-OTF Shin Maru Go Pr6N DB`；mpv/libass DirectWrite 日文字形实际回退 `Microsoft YaHei UI`，Hibiki 却从 `Yu Gothic` 开始，且 Skia 缺失字体字形相对 libass/FreeType 继续偏小，导致字号、字宽、描边占比和视觉颜色面积均不一致。根因见 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:334`、`:365`、`:1433`、`:1729`。
- **[x] ① 已修复** — Windows ASS 缺失字体链先选 `Microsoft YaHei UI` / `Microsoft YaHei`，渲染与 cell/em 度量共用该链；仅对 Windows“作者字体确实缺失”的路径补 libass 实测栅格尺寸校准（横向字号 1.09、纵向 1.055），已安装作者字体和其他平台保持原逻辑。本提交。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_ass_mpv_fallback_test.dart` 直接复刻用户样例的 65 字号、白色正文、`#D93F61` 描边、2.5 字距和 3px Outline，守卫 Windows 回退顺序、字号/纵向缩放与颜色/描边；定向测试 2/2 通过，定向 analyze 无问题。
- **备注**：用同一 ASS 在 1920×1080 黑底帧实测：mpv 像素框 `157×56`；Hibiki 修改前 `141×46`，修改后 `158×56`。Windows 真应用 runner `win-itest-20260720-051637-b69db471` 通过，权威 Flutter 帧位于 `.codex-test/windows-itest/win-itest-20260720-051637-b69db471/screenshots/ass-mpv-fallback-after.png`。ASS 原始主色/描边色解析本来正确，本修复通过对齐字形、字号和宽高恢复与 mpv 相同的颜色面积观感。
