## BUG-330 · 视频mpv高级『额外mpv选项』标题文本显示不全
- **报告**：2026-06-19（用户：）· TODO-561
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_quick_settings_sheet.dart`（修复前 mpv「高级」段把标题 `t.video_setting_mpv_raw`（「额外 mpv 选项（每行 key=value）」）挂在 `TextField` 的 `InputDecoration.labelText` 上。Material 浮动 label 恒为单行 + ellipsis，在窄右 pane / 高 UI scale 下整段被截断显示不全。
- **[x] ① 已修复** — commit `87fbc28f6`：把标题从 `InputDecoration.labelText` 拆出，改成 `TextField` 上方独立的 `Text(t.video_setting_mpv_raw, style: titleSmall)`（可换行、完整显示），输入框去掉 `labelText` 不再走单行浮动 label；`helperText` 已有 `helperMaxLines: 4` 不截断。修复在 `video_quick_settings_sheet.dart:1175-1198`（标题 Text 在 `:1179`）。
- **[x] ② 已加自动化测试** — commit `87fbc28f6`：`hibiki/test/pages/video_quick_settings_sheet_test.dart:593-668` 新增 5 个用例：① 标题是独立 Text 而非 `InputDecorator` 后代（labelText 路径），且 `RenderParagraph.didExceedMaxLines == false`；②③④ 在 320px/scale1.5、360px/scale2.0、420px/scale2.0 三种窄 pane + 高缩放下标题完整可读不截断；⑤ 源码守卫禁止再出现 `labelText: t.video_setting_mpv_raw`。撤源码修复后这 5 例转红（其余 62 例仍绿），守卫有效对症。
- **备注**：标题不全是浮动 label 单行 + ellipsis 的固有行为，非缩放计算 bug；改为独立 Text 后从结构上消除单行约束。`flutter analyze` 0 问题，`flutter test test/pages/video_quick_settings_sheet_test.dart` 67 例全绿。真机/真设备复测待用户。
