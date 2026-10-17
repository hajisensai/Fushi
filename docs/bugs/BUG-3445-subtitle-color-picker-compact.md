## BUG-3445 · 手机字幕取色器被裁且描边关不掉、全局设置缺颜色项
- **报告**：2026-10-15（用户：应用内反馈 PM-iIH9G0b，vivo V2339FA 384x853dp，带截图）
- **真实性**：✅ 三条都属实。
  1. **取色器被裁（换不了色系、深色部分看不到）**：`fushi/lib/src/media/video/video_settings_actions.dart:546`（旧）
     把包内 `ColorPicker`（色板写死 300x300，`third_party/flutter_colorpicker/lib/src/colorpicker.dart:281`）直接塞进
     `SingleChildScrollView`。视频全屏横屏 853x384 时对话框内容区只剩约 100dp：色板被裁成一条（下半部偏深色被截掉），
     下面的色相条（换色系）与 Hex 输入完全不可见；色板自己吃掉竖向拖动，滚动视图也滚不下去。同款写法还在
     `overlay_color_setting_item.dart` / `lapis_style_editor_page.dart` / `dict_style_visual_editor.dart`。
  2. **描边关不掉**：`video_settings_actions.dart:572`（旧）`_pickSubtitleColor` 关闭对话框时**无条件** `onCommit`，
     而描边色的 commit 会把 `outlineThickness` 从 0 顶到 2（`:634`）——用户把描边粗细滑到 0 后只要再打开描边颜色看一眼，
     描边就被悄悄重新打开；对话框也没有「无描边」出口（数据模型里 `outlineThickness == 0` 即无描边）。背景色同理会把透明度从 0 顶到 0.6。
  3. **全局设置里没有字幕颜色项**：`fushi/lib/src/settings/settings_schema_video.dart` 里四个颜色行
     （文字 / 阴影 / 描边 / 背景）自 `5ae99dd7d5`（2026-07-21 面板改 schema 投影）起就放在 `video.section.session`
     并以 `visible: videoHostVisible` 门控，只在播放页面板出现——**不是被删了，是从来没进过全局设置页**。
     但它们的 builder 无 host 时本就走「拖动预览态 + 直接落 pref」，全局页字幕分区顶部也有实时样式预览，门控没有必要。
- **[x] ① 已修复** — 见本分支提交（`fix(video): adaptive subtitle color picker, no-outline action, global color rows`）：
  新增 `fushi/lib/src/utils/components/fushi_dialog_color_picker.dart`（`FushiDialogColorPicker`）按对话框内容区约束反推
  色板尺寸（竖排压缩色板高度；横屏矮屏改用包内横排布局：色板左、色相条 + Hex 右），矮屏省掉 hero 图标；四处对话框调用全部换用。
  `_pickSubtitleColor` 只在真的选过色时 commit，描边对话框加「无描边」（粗细归 0、保留颜色）。四个颜色行移入全局可见的
  `video.section.subtitles`（id / VideoPlacement 不变，播放页面板投影不变），加 `searchTitle` 进全局搜索。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_color_dialog_compact_test.dart`（384x853 与 853x384
  下取色器 `maxScrollExtent == 0`、色板 / 色相条 / Hex 输入全在可见区、无溢出；「无描边」写穿 host 与无 host 的 pref；
  不选色点「完成」不 commit）；`fushi/test/pages/video_settings_schema_guard_test.dart`（颜色行全局可见、不 host 门控、进搜索）。
  变异实测：退回旧布局（固定 300x300）横屏用例 `maxScrollExtent` 为 251 → 红；只禁用横排布局为 23 → 红。
  补充（PR 审查）：同一用例补跑 Apple 设计系统（sheet 内容区最宽 472，低于旧的「横排需 ≥480」门槛）横屏 → 原实现退回竖排、`maxScrollExtent` 为 5 → 红；改为「竖排压缩 / 横排二选一、取一屏放得下且色板面积更大者」后转绿。
- **备注**：未在真机复测（反馈机型为 vivo 横屏全屏播放）；widget 测试按反馈机逻辑尺寸与 DPR 2.81 复现。
