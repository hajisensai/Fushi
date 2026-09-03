## BUG-1858 · 设置页输入框宽度三套并存：下载设置 480 / 在线服务 560 / 其余撑满
- **报告**：2026-08-25（用户：截图「设置 → 在线服务 → 字幕来源」，「这里和别的输入框宽度不一样，修复一下，顺便统一一下这方面的代码」）
- **真实性**：✅ 真 bug。同一个设置分区里并存三种输入框宽度，实测（widget 测试量真实几何，pane 2400）：
  - `fushi/lib/src/pages/implementations/torrent_settings_section.dart:223` `_kFieldMaxWidth = 480` —— 下载设置的输入框自己 `Align(centerLeft) + ConstrainedBox(480)`，而同一列的开关 / 分段按钮吃满内容宽度；
  - 同文件 `:695` / `video_external_provider_settings_section.dart:912` —— 两段正文再各自收进 `kTorrentSettingsContentMaxWidth = 560`；
  - 对照 `fushi/lib/src/settings/settings_schema_fields.dart:131` → `AdaptiveSettingsTextField`（`AdaptiveSettingsRow(controlBelow) + Align(centerLeft)`）**不限宽**，实测 pane 2400 下宽 **2368**。
  用户截图那一页（`settings_schema_services.dart:46`「字幕来源」）就同时挂着两种：上半段是 560 的 `VideoExternalProviderSettingsSection`，往下「元数据刮削」的 `SettingsTextItem` 是撑满的，一页之内两条右边界。
- **[x] ① 已修复** — 用户 2026-08-25 拍板「统一放开成撑满」。删掉全部三层局部限宽，设置页只剩一条规则：与普通设置行共用同一条 16px 左右基线、正文吃满剩下的宽度。
  - 新增唯一原语 `SettingsFormField`（`fushi/lib/src/utils/components/settings_shared.dart`），宽度契约写在类文档上；下载设置 `_text` 与在线服务 `_field` 两处私有 helper 都改为委托它，`isDense + OutlineInputBorder + helperMaxLines: 3` 的 decoration 也收归一处。
  - `TorrentSettingsSection`：删 `_kFieldMaxWidth`、删 `constrainWidth` 参数与「560 居中」分支（两个调用点本就都传 `false`，`true` 是死路径），`horizontalPadding` 恒 0，build 只剩 `Padding(rowHorizontal) + SizedBox(infinity)`。
  - `VideoExternalProviderSettingsSection`：`_constrainSectionWidth` → `_alignSectionBaseline`，去掉 `Align + ConstrainedBox(560)`，保留 16px 基线。
  - 提交：见本轮 commit。
- **[x] ② 已加自动化测试** —
  - `fushi/test/pages/torrent_settings_field_width_test.dart`（重写）：宽窄两个 pane 各断言「内容容器 = pane − 2×16、左边缘 = 16、每个输入框与容器同宽同左边缘、开关行不越界」。变异实测：把 `ConstrainedBox(maxWidth: 560)` 加回 build 尾部 → 红。
  - `fushi/test/settings/video_external_provider_settings_section_test.dart`：BUG-1747 那条的 `width <= 561` 改为 `width == 1400 - 2*16` + 左边缘 16。变异实测：把 560 加回 `_alignSectionBaseline` → 红。
  - `fushi/test/pages/downloads_page_resize_inset_guard_test.dart` / `module_top_settings_tabs_guard_test.dart`：`constrainWidth: false` 锚点随参数删除搬到「无参调用 + 组件源码里没有 `BoxConstraints(maxWidth:`」。变异实测：加回限宽 → 源码守卫红。
- **备注**：BUG-1084（4K 下输入框被拉到三千像素）与 BUG-1278（下载设置左右间距和其他设置不一样）的限宽结论被本次用户决策显式推翻——限宽只加在了那两段上，反而制造了不一致。要再引入宽度上限，只能加在 `SettingsFormField` / `AdaptiveSettingsTextField` 这一层（全 app 一处），不能各段自设。
