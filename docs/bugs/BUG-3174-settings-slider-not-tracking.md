## BUG-3174 · 设置数值滑条拖动不跟手松手才变
- **报告**：2026-10-09（Android 用户反馈 wBdELVtnhz：设置里有数值拉条的设置项，条不会即时有动画反应，松手后才变；截图为 视频 › 字幕 › 字号）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/settings_shared.dart` 的 `_KeyboardSlider` 是无状态的，滑块位置完全取调用方传入的 `value`；设置 schema 渲染器 `fushi/lib/src/settings/settings_schema_widgets.dart` 的 `_slider()` 非 commitOnRelease 分支也只在 `item.onChanged` await 完、`refresh()` 后才用 `item.value` 重读。字幕外观（字号 / 阴影 / 背景不透明度…）这类滑条拖动中只调 `previewVideoSubtitleStyle`（`fushi/lib/src/media/video/video_settings_actions.dart`，全局设置页无 host 时只写 draft、不 refresh），`item.value` 读的仍是已落盘旧值 → 整段拖动里滑块钉在原地，松手 `commitVideoSubtitleStyle` 落盘后才跳过去；写库是异步的滑条同样滞后。
- **[x] ① 已修复** — 共享组件层：`_KeyboardSlider` 改为有状态，拖动中的值放在本 State 直接画，松手后保留到调用方的 `value` 真的变了再交还（无回弹）。设置 schema 层：所有滑条统一走有状态载体（原 `_CommitOnReleaseSlider` 扩展为两种提交语义共用），读数 / label 也随拖动实时变化。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/ui_hit_area_consistency_test.dart`「设置滑条拖动跟手」：调用方拖动中不写回 value，断言 Slider 的 value 已跟手变化、松手触发 onChangeEnd。
- **备注**：同一条反馈的「字幕预览拉到最大仍然重叠」：当前 develop（含 #2001 / BUG-3080）在 384 宽、字号 48 下的预览像素截图未见重叠（PR 附图）；反馈构建 `2.10.0-debug.18353` 早于还是晚于 #2001 无法从版本号判定，见 PR「待定」。
