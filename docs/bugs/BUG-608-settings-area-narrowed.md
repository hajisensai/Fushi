## BUG-608 · 设置部分区域宽度变窄回归
- **报告**：2026-07-08（用户：TODO-1321）
- **真实性**：✅ 真 bug。书内快捷设置面板（`ReaderQuickSettingsSheet`）宽/窄 master-detail 里，
  「导航」(location) 与「有声书」(audiobook) 子页是 bespoke widget，只吃外层 pane 的横向 padding；
  而「布局 / 阅读控制 / 查词」子页经 `MaterialSettingsRenderer.buildDetailContent(shrinkWrap: true)` 渲染，
  该方法无条件套 `detailHorizontalInsets`（左 page+gap、右 page）。因外层 `SingleChildScrollView` 已提供
  `widePrimaryPadding`/`narrowPadding` 横向留白，schema 子页被**双重缩进**，比导航/有声书子页每侧窄约
  24/16px（`4602c6fff` 把左缩进 page→page+gap 后放大了差距）。Cupertino 渲染器的 `buildDetailContent`
  本就无横向内边距，故此回归仅 Material（Android/桌面）可见。
  - 根因：`hibiki/lib/src/settings/material_settings_renderer.dart:122` `buildDetailContent`
    嵌入场景仍自带横向缩进（对比 `cupertino_settings_renderer.dart:104` 无横向缩进）。
  - 触发点：`hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart` `_buildSettingsDestinationContent`
    在已有横向 padding 的 pane 内调用它。
- **[x] ① 已修复** — 给 `buildDetailContent` 加 `insetHorizontally`（默认 true，保留主页 master-detail /
  全屏详情 / 弹窗行为不变）；嵌入 pane 时传 `insetHorizontally: false`，让渲染器只保留纵向内边距、把横向留白
  交给外层（对齐 Cupertino）。书内快捷设置的 schema 投影传 false，并把主题选择器卡 / 编辑书籍CSS 行的
  `detailHorizontalInsets` 包装去掉（它们原本只为对齐那层双缩进）。结果：导航/布局/阅读控制/查词/有声书
  五个子页统一到 pane 的宽版宽度，BUG-545/546/573 的「等宽」不变。提交：见本轮 commit（含 TODO-1321）。
  - `hibiki/lib/src/settings/settings_renderer.dart`（接口加参数）
  - `hibiki/lib/src/settings/material_settings_renderer.dart`（横向缩进受 `insetHorizontally` 门控）
  - `hibiki/lib/src/settings/cupertino_settings_renderer.dart`（接受参数，no-op）
  - `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`（投影传 false + 主题/CSS 卡裸放）
- **[x] ② 已加自动化测试** —
  - `hibiki/test/settings/reader_settings_area_width_parity_test.dart`（行为：`insetHorizontally:false` 的
    详情正文铺满 pane 宽、且比 `insetHorizontally:true` 更宽；源码守卫：渲染器横向缩进受门控 + 面板投影传
    false + 面板不再各自套 detailHorizontalInsets）。
  - `hibiki/test/settings/reader_layout_theme_card_width_test.dart`（BUG-546 更新为统一宽度模型：主题卡裸放）。
  - `hibiki/test/settings/reader_layout_css_editor_row_width_test.dart`（BUG-573 更新为统一宽度模型：CSS 行裸放）。
- **备注**：主 app 设置页（`SettingsHomePage`）各 destination 走非 shrinkWrap 的 `buildDetailContent`，
  本就统一满宽，不受影响；真机/桌面视觉验收（设置各区恢复宽）交用户。
