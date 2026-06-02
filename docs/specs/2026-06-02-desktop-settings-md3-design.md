# 桌面端设置 MD3 打磨设计（方案 B）

- 日期：2026-06-02
- 范围：Windows/Linux 桌面 **Material** 路径的设置页（list-detail 两栏）
- 不在范围：macOS（保持 `CupertinoSettingsRenderer` 原样）、iOS、Android 紧凑布局行为
- 触发来源：用户给出一张 macOS 风格「主题编辑器」参考图，要求按 MD3 重做桌面端 UI

## 背景与核心判断

该参考图的「主题编辑器」**不存在于 Hibiki 代码库**（`跟随光标`/`液态玻璃`/`重设为默认值` 等串在 Dart 与 17 个 i18n 文件中均无），是另一 App（疑似旧 ttu 系）的截图。

Hibiki 桌面设置**当前已是 MD3 官方对 8-11 个分组推荐的 list-detail（Pattern A）**：
- `settings_home_page.dart`：`LayoutBuilder` ≥720 走 `_buildWideLayout` = 固定 280px 侧栏 + 1px `VerticalDivider` + `Expanded` 详情；选择保持在窗格内（`pushRoutes:false`）。
- 外层 `DesktopContentLayout(kind: settings)` 将内容限宽 **760px 居中**，expanded 外边距 24。
- 渲染器：`MaterialSettingsRenderer`（非 Cupertino）/ `CupertinoSettingsRenderer`（macOS/iOS）。

参考图的「右对齐两列表单 + 底部撤销/重做/重设/关闭栏」是 **macOS 习惯，违背 MD3**（MD3 用 `ListTile`+trailing 控件、分隔线分组、设置实时生效、无底部确认栏）。因此本设计**不照搬参考图**，而是把已正确的 list-detail 结构打磨成地道 MD3。

权威依据（MD3）：导航/列表窗格用 `surfaceContainer`、详情窗格用 `surface`，且色调跨断点不变；列表选中态为内缩圆角高亮（`secondaryContainer`）；详情为弹性主区；expanded 边距/栏间距 24dp；不使用已废弃的 navigation drawer。

## 真实差距与改动（方案 B = ①②③④⑤）

### ① 两栏色调区分
- 现状：侧栏与详情共用 `surface`，仅一条发丝线分隔，视觉很平。
- 改动：`settings_home_page._buildWideLayout` 给**导航窗格**加背景 `scheme.surfaceContainerLow`（对应 `tokens.surfaces.group`），详情窗格保持 `surface`。
- 约束：**仅 Material 路径生效**（`!isCupertinoPlatform(context)` 时才上背景）；Cupertino 路径保持原样。保留 1px `VerticalDivider`（此时分隔的是两种不同色调）。

### ② 选中项改圆角胶囊
- 现状：`HibikiListItem` 选中态是贴边满宽纯色矩形（`AnimatedContainer(color: secondaryContainer)`）。
- 改动：选中高亮改为**内缩 + 圆角**——水平外边距 `tokens.spacing.gap`，圆角 `tokens.radii.group`(12)，填充色仍为 `tokens.surfaces.selected`(`secondaryContainer`)。这是 MD3 通用正确的列表选中态。
- 影响面：`HibikiListItem` 是共享组件，多处使用 `selected:true`。作为**默认行为变更**统一处理；以 `md3_design_system_static_test` 与相关 golden 测试为回归网，必要时更新 golden。
- InkWell 水波纹需同步裁成同一圆角（`borderRadius` / `customBorder`），避免方角水波溢出圆角高亮。

### ③ 去掉误导性 chevron
- 现状：`MaterialSettingsRenderer.buildDestinationList` 每项 `trailing: Icon(chevron_right)`，但 master-detail（`pushRoutes:false`）点击不 push。
- 改动：`trailing: pushRoutes ? const Icon(Icons.chevron_right) : null`——仅窄屏 push 模式保留 chevron。与最近提交 `96d1c540e`/`5d629eb7d`（移除误导 chevron）同向。

### ④ 加宽详情区
- 现状：`desktopContentMaxWidth(settings)=760` → 280 侧栏后详情仅 ~480。
- 改动：`platform_utils.dart` 中 settings 上限 **760→960**，详情区涨到 ~680，更平衡的桌面观感。
- 断点一致性核验：cap 960、宽屏触发 720；窗口 ≥960 → 内容 960 居中 → 两栏(280+~680)；800 → 内容 800 → 两栏(280+~520)；700 → 内容 700 <720 → 单栏 push（chevron 出现）。链路自洽。
- 影响：所有 `DesktopContentKind.settings` 消费点（settings 页 + 任何复用 settings kind 的对话框）；需多测。

### ⑤ 栏间距对齐 24
- 现状：`DesktopContentLayout` expanded 外边距已 24；窗格内列表 padding = `tokens.spacing.page`(16)。
- 改动（轻量）：给详情窗格内容增加贴近分隔线一侧的水平内缩，使分隔线两侧有约 24 的呼吸感；不改全局 `spacing.page` token（避免波及移动端）。

## 明确不做（参考图里的 macOS 习惯，非 MD3）
- 底部「撤销/重做/重设为默认值/关闭」操作栏（与 Hibiki 实时生效模型冲突）。
- 右对齐两列表单行（MD3 用 leading 标签 + trailing 控件）。
- 去掉侧栏图标（MD3 导航列表保留图标助扫描）。

## 涉及文件
- `hibiki/lib/src/settings/settings_home_page.dart`（① 窗格背景，Material 门控）
- `hibiki/lib/src/utils/components/hibiki_material_components.dart`（② `HibikiListItem` 选中圆角胶囊 + 水波裁剪）
- `hibiki/lib/src/settings/material_settings_renderer.dart`（③ chevron 门控；⑤ 详情内缩）
- `hibiki/lib/src/utils/misc/platform_utils.dart`（④ settings cap 760→960）

## 验证
- `dart format .` + `flutter test`（项目 Flutter 3.44.0 工具链）；重点跑 `test/settings/md3_design_system_static_test.dart`、`test/pages/*md3*`、`test/goldens/`（选中圆角会改 golden，确认后更新）。
- 设备验证：Windows 桌面打开设置页，核对两栏色调差、选中圆角胶囊、无 chevron、详情更宽；macOS 走 Cupertino 应无变化。留证据。
- 不涉及 Android 资源/manifest/Gradle，免 `assembleRelease`。

## 风险
- `HibikiListItem` 选中态是全局共享 → 圆角化会波及所有选中列表（书架/词典/统计等）。这是有意的 MD3 统一，但需 golden 全过确认无意外。
- ④ 影响所有 settings-kind 消费点；若有以 760 为前提的布局假设需一并核对。
