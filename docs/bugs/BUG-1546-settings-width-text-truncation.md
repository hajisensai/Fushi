## BUG-1546 · 设置页限宽与描述/集标题截断显示不全
- **报告**：2026-08-11（用户：设置项「字幕遮蔽」等描述被单行省略截断；「视频、小说等设置被限制了宽度」；合集详情选集卡片集标题单行截断）
- **真实性**：✅ 真 bug（三处独立根因，均沿真实代码路径复现）
  1. **设置行说明文字单行省略**：`fushi/lib/src/utils/components/settings_shared.dart:1954`（`_SettingsLabel`）——BUG-1184 把 `subtitleMaxLines` 默认放开为 null（不钳行数）时**保留了 `overflow: TextOverflow.ellipsis`**；引擎对「ellipsis 非空 + maxLines 为空」的段落按**单行**布局（dart:ui `ParagraphStyle.ellipsis` 语义），于是全部走 schema 的设置行说明（字幕遮蔽等）被钳成一行省略号。变异实测确认：还原旧写法后段落高度恒为 16px（单行）。
  2. **视频设置侧栏限宽**：`fushi/lib/src/pages/implementations/video_fushi/side_panel.part.dart:98`——`_videoSidePanelWidth(_VideoSidePanelKind.settings)` 硬编码固定 560，桌面大窗口下设置内容挤成窄条（说明文字更容易换行/显示不全）。阅读器内设置弹窗 `fushi/lib/src/pages/implementations/fushi_settings_page.dart:36` 同族硬编码 `maxWidth: 560`，与兄弟快捷设置弹窗（900）不同宽。
  3. **选集卡片集标题单行截断**：`fushi/lib/src/pages/implementations/media_collection_detail_page.dart:2158`——集卡标题 `maxLines: 1`，无刮削集名时标题是整条发布文件名（VCB-Studio 类 80+ 字符），单行省略后集号/规格全被吃掉。
- **[x] ① 已修复** — commit（见本分支）：
  - `_SettingsLabel`：ellipsis 只与有限行数成对出现（`overflow: subtitleMaxLines == null ? null : TextOverflow.ellipsis`），默认整段换行；显式有限值行为不变（BUG-1184 逃生口保留）。
  - 新增 `fushiQuickSettingsPanelWidth(double)`（`platform_utils.dart`）：窗口宽度取半、clamp 560..900；视频设置侧栏改走它（窄窗零变化，≥1120 逻辑宽起放宽，1800 封顶 900）；`FushiSettingsDialogPage` 的 560 对齐 `kFushiSettingsDialogMaxWidth`（900）。
  - 集卡标题 `maxLines: 1 → 2`（128 卡高下「两行标题+两行简介+状态行」仍在 Spacer 余量内，widget 测试断言无溢出）。
- **[x] ② 已加自动化测试** —（均已做变异实测：反向替换后对应断言精确变红）
  - `fushi/test/settings/settings_row_subtitle_wrap_test.dart`：长说明默认多行渲染（几何行高判据）；显式 `subtitleMaxLines:2` 仍恰好两行截断。
  - `fushi/test/utils/quick_settings_panel_width_test.dart`：宽度函数 clamp 契约 + 源码守卫（settings 分支必须调用自适应函数，回退硬编码 560 即红）。
  - `fushi/test/pages/collection_episode_cards_test.dart`：新增「超长文件名标题两行换行显示」用例（行高判据 + 无 RenderFlex 溢出）。
- **备注**：与 BUG-1184 是同一条 `_SettingsLabel` 的接力——1184 放开行数上限、1546 修掉放开后残留的单行 ellipsis 布局语义。
