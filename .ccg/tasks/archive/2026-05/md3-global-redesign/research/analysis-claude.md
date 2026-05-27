# Hibiki 全局 MD3 改造分析报告（分析员 B）

## Files Found

- `.ccg/tasks/md3-global-redesign/requirements.md`：任务把 Seal 9 张参考图提炼为大标题、tonal card、28dp sheet/dialog、primary section label、chip/format card 选中态等目标。
- `.ccg/tasks/md3-global-redesign/plan.md`：当前计划偏向 tokens + ThemeData + shared components 的集中式改造。
- `hibiki/lib/src/utils/components/hibiki_design_tokens.dart:28`：已把 group/card/menu/dialog/sheet 半径、primary/primaryContainer、pageTitle/sectionLabel 收进 token。
- `hibiki/lib/src/models/theme_notifier.dart:249`：已启用 `useMaterial3` 并补 Card/BottomSheet/FAB/Chip/Button/Divider 等 ThemeData 基础。
- `hibiki/lib/src/utils/components/hibiki_material_components.dart:5`：`HibikiCard` 是全局卡片壳，dirty diff 已把默认 border 改成 `BorderSide.none`。
- `hibiki/lib/src/settings/material_settings_renderer.dart:10`：schema 驱动设置页入口，已改 section title 使用 token。
- `hibiki/lib/src/utils/components/settings_shared.dart:8`：手写设置页共享组件，dirty diff 加了 token section header、group radius、`AdaptiveSettingsTextField`。
- `hibiki/test/settings/md3_design_system_static_test.dart:6`：已有字符串型静态守卫，覆盖若干已迁移 shared component 和旧 primitive 禁用项。
- `hibiki/lib/src/utils/adaptive/adaptive_navigation.dart:47`：Material app bar 仍只是普通 `AppBar` 包装，未承载 Seal 式页面大标题语法。
- `hibiki/lib/src/utils/adaptive/adaptive_widgets.dart:148`：`adaptiveModalSheet` 默认并显式传 `showDragHandle: false`，会抵消 ThemeData 的 drag handle 目标。
- `hibiki/lib/src/utils/components/hibiki_bottom_sheet.dart:21`：现有 bottom sheet 内容只是 `ListView` + `HibikiListItem`，没有 title/subtitle/section/action frame。
- `hibiki/lib/src/pages/implementations/dictionary_popup_native.dart:116`：native popup dictionary 仍是自绘紧凑列表、4dp tag、硬编码字号。
- `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:229`：reader history tag chips 仍用 4dp 小圆角和硬编码 9px 字号。
- `hibiki/lib/src/pages/implementations/media_item_edit_dialog_page.dart:78`：media edit/import 类 dialog 仍有直接 `TextField`，尚未归入新的 field shell。
- `hibiki/lib/src/media/audiobook/book_import_dialog.dart:147`：book import dialog 仍有直接 `TextField` + `OutlineInputBorder`。
- `hibiki/lib/src/pages/implementations/tag_filter_sheet.dart:127`：tag filter sheet 直接使用 `FilterChip`，未抽象出 Seal 风格 chip/selected fill 规则。

## Dependencies

```
Seal reference grammar
  -> HibikiDesignTokens
    -> ThemeNotifier ThemeData component themes
    -> HibikiCard / HibikiListItem / HibikiEditorPanel / HibikiPopupSurface
    -> SettingsSectionHeader / AdaptiveSettingsSection / AdaptiveSettingsTextField
      -> material_settings_renderer schema pages
      -> hand-written settings pages
      -> reader quick settings sheet

ThemeNotifier bottomSheetTheme
  -> showModalBottomSheet only when caller does not force showDragHandle=false
  -> adaptiveModalSheet currently forces false by default
  -> HibikiBottomSheet lacks MD3 sheet frame even if theme shape applies

adaptiveAppBar
  -> home/settings/history/statistics/tag pages
  -> ordinary AppBar title
  -> does not consume tokens.type.pageTitle

md3_design_system_static_test
  -> guards selected files by string search
  -> cannot prove runtime ThemeData shapes, focused states, bottom sheet handle, or selected chip colors
```

## Seal MD3 视觉语法

从 9 张 Seal 图看，目标不是“把圆角加大”这么浅：

- 页面结构：顶部是 icon-only app chrome，主标题在内容区左对齐，字号接近 headline/display；普通小 AppBar 标题会明显偏旧。
- Surface 层级：页面背景干净，卡片/列表组用 tonal container 区分，不靠重 border；选中态使用 primaryContainer/secondaryContainer 的填充。
- 弹层：底部 sheet 有 28dp 顶部圆角、drag handle、居中 icon/标题/副标题、primary 色 section title、底部双按钮 action row。
- 列表：列表项高度 56-72dp，图文列表强调缩略图、标题、副标题和 trailing menu；选择态 checkbox/radio 是填充色，不只是默认控件。
- 表单和 chips：OutlinedTextField 有 floating label；chips 是 8dp 圆角、横向/Wrap 排布，选中态用浅色填充；format option 是可选卡片网格。
- 深色：不是简单反色，surfaceContainer 层级、选中填充、preview card 都要有明确 dark mapping。

## Patterns

- `hibiki/lib/src/utils/components/hibiki_design_tokens.dart:28-55`：半径 token 已能表达 Seal 的 12dp card/group、28dp dialog/sheet，这是合理基础。
- `hibiki/lib/src/utils/components/hibiki_design_tokens.dart:101-142`：`pageTitle` 与 `sectionLabel(primary)` 已存在，但目前大部分页面还没消费 `pageTitle`。
- `hibiki/lib/src/models/theme_notifier.dart:249-379`：ThemeData 集中配置 Card、BottomSheet、FAB、Chip、Button、Divider，方向正确，能给 built-in Material 组件兜底。
- `hibiki/lib/src/utils/components/hibiki_material_components.dart:31-49`：`HibikiCard` 默认无 border、保留显式 `borderColor`，是兼容迁移的正确做法。
- `hibiki/lib/src/settings/material_settings_renderer.dart:143-164`：schema settings section 使用 token section title + HibikiCard，符合全局化方向。
- `hibiki/lib/src/utils/components/settings_shared.dart:108-120`：手写 settings section 已改成 token radius，但 Material 分支仍用 `surfaceContainerLowest`，和 token `surfaces.group = surfaceContainerLow` 不一致。
- `hibiki/lib/src/utils/components/settings_shared.dart:600-657`：新增 `AdaptiveSettingsTextField` 是必要抽象，但当前 fixed outline side 不会随 focus/error/disabled 状态变化。
- `hibiki/test/settings/md3_design_system_static_test.dart:167-301`：已有旧 primitive 禁用表，适合继续扩展，但不能代替 Widget/theme 测试。

## Critical

### C1. `adaptiveModalSheet` 会让全局 BottomSheetTheme 的 drag handle 目标失效

- 证据：`hibiki/lib/src/utils/adaptive/adaptive_widgets.dart:148-164` 默认 `showDragHandle = false`，并把这个 false 传给 `showModalBottomSheet`。
- 影响：即使 `theme_notifier.dart:336-342` 设置了 `BottomSheetThemeData(showDragHandle: true, shape: 28dp)`，走 `adaptiveModalSheet` 的 sheet 仍不会显示 Seal 参考图里的 handle。这会让“所有底部弹窗”目标直接落空。
- 建议：让 wrapper 参数改为 nullable 并默认交给 theme，或 Material 分支默认 true；同时补 Widget test 打开 sheet 后断言 drag handle 存在、top shape 半径为 28。

### C2. Dirty diff 混入阅读器分页/同步等非 MD3 行为改动，回归风险不应归入本任务

- 证据：`hibiki/lib/src/reader/reader_pagination_scripts.dart` 增加 char offset restore；`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 修改 `_readerBottomReserve`、宽度变化恢复逻辑和 `_syncPageSize()` 调用；`hibiki/lib/src/pages/base_source_page.dart` 增加 close 后 auto sync；`CLAUDE.md` 增加 ADB 点击规则。
- 影响：这些都是真实行为变化，不是视觉改造。阅读器恢复、分页、关闭媒体后的同步 side effect 都是高敏感路径，混在 MD3 diff 里会让审查和回滚困难。
- 建议：从 MD3 任务拆出独立修复任务和测试证据；如果暂时保留 dirty diff，review.md 必须明确它们不是 MD3 验收范围，且需要 reader restore / close media sync 回归测试。

## Warning

### W1. 仍缺页面级 MD3 scaffold，大量页面会停留在旧 AppBar 小标题语法

- 证据：`adaptiveAppBar` 的 Material 分支只是 `AppBar(title: title)`（`hibiki/lib/src/utils/adaptive/adaptive_navigation.dart:66-72`）；`material_settings_renderer.dart:30-32`、`:85-86` 也直接用 AppBar；`home_page.dart:267-285` 大部分 tab 仍走 `adaptiveAppBar`。
- 影响：Seal 的大标题在内容区，不是小 AppBar 标题。只改 ThemeData 不会让 settings、statistics、tag management、collections 等页面获得 Seal 风格的首屏层级。
- 建议：新增 `HibikiPageScaffold`/`AdaptiveMd3Scaffold`，Material 分支提供 in-content `tokens.type.pageTitle`、可选 icon-only top actions、统一 list padding；reader/fullscreen/diagnostic 页面可列入 allowlist。

### W2. Bottom sheet 内容缺少 frame 抽象，无法表达 section/title/action 语法

- 证据：`HibikiBottomSheet` 只是 `ListView.builder` + `HibikiListItem`（`hibiki/lib/src/utils/components/hibiki_bottom_sheet.dart:60-88`）。
- 影响：Theme 只能给外壳圆角，不能提供 Seal 图 2/4 的 title/subtitle、primary section label、chip groups、底部双按钮 action row。
- 建议：新增 `HibikiModalSheetFrame(title, subtitle, icon, sections, actions)`，让 tag filter、download/config、history detail 这类 sheet 统一接入。

### W3. `AdaptiveSettingsTextField` 是正确方向，但当前实现绕过了 ThemeData 的状态边框

- 证据：`settings_shared.dart:627-653` 用外层 `Material` 固定 `BorderSide(color: tokens.surfaces.outline)`，内部 `TextFormField` 全部 `InputBorder.none`。
- 影响：看起来比旧 `OutlineInputBorder` 统一，但 focused/error/disabled 不会变 primary/error，和 Seal/MD3 OutlinedTextField 的交互态不一致。
- 建议：让 shared field 使用 `InputDecorationTheme` 的 `OutlineInputBorder` 和 radius token，或在外层 shape 中用 `Focus`/`MaterialState` 显式 resolve side；补 focus/error widget test。

### W4. 原生词典 popup、reader history tags、tag filter chips 仍明显偏旧

- 证据：native popup 使用自绘列表和 4dp tag（`dictionary_popup_native.dart:126-135`, `:224-232`）；popup layer 8dp border（`dictionary_popup_layer.dart:99-104`）；reader history tag chip 4dp/9px（`reader_hibiki_history_page.dart:229-260`）；tag filter 直接 `FilterChip`（`tag_filter_sheet.dart:127-134`）。
- 影响：这些是用户高频接触的浮层/选择面，会在全局 token 改完后仍像旧 UI。
- 建议：抽 `HibikiTagChip`/`HibikiSelectableChip`/`HibikiPopupListSection`，统一 chip radius、selected fill、tag color contrast 和 popup surface。

### W5. 现有 static test 扩展了旧 primitive 禁用，但覆盖仍是字符串级

- 证据：`md3_design_system_static_test.dart:6-141` 只检查文件包含 shared component；`:167-301` 只检查 banned string。
- 影响：它能防止一部分倒退，但无法发现 `adaptiveModalSheet(showDragHandle: false)`、focused field 边框、ThemeData component shape、dark-mode selected color 这些真实视觉行为。
- 建议：保留 static test 作为 lint，新增 focused Widget/theme tests，尤其覆盖 ThemeNotifier、HibikiCard、AdaptiveSettingsSection、AdaptiveSettingsTextField、adaptiveModalSheet。

## Info

### I1. 当前 token/theme/card 改动是合理基础

- `hibiki_design_tokens.dart`、`theme_notifier.dart`、`hibiki_material_components.dart` 的方向符合“先改共享层”的全局推进方式。它们应该保留，但不能把它们当作“所有地方完成”的证据。

### I2. Anki 和 dictionary settings 的 TextField 迁移合理，但只是局部补洞

- `anki_settings_page.dart` 和 `dictionary_settings_dialog_page.dart` 改用 `AdaptiveSettingsTextField`/`HibikiEditorPanel` 是合理的旧 UI 清理。
- 但 `book_import_dialog.dart:147-162`、`media_item_edit_dialog_page.dart:78-91`、`sync_settings_schema.dart:447` 等仍有直接 field，说明“所有地方”目标还没被系统性收口。

### I3. Custom theme preview 里的小圆角/硬编码字号不应全部算作普通 chrome 债务

- `custom_theme_page.dart:621-769` 是主题效果预览，部分小元素是内容样例。这里要区分“真实控件壳”与“被预览的内容渲染”，不要为追求静态规则把预览语义改坏。

## 最小但真实的推进方案

1. 先补共享抽象，而不是逐页换皮：
   - `HibikiPageScaffold`：Material 大标题内容区、统一 padding、icon actions；设置/统计/tag/collections 等普通页面迁入。
   - `HibikiModalSheetFrame`：drag handle、title/subtitle、section slots、scroll body、sticky action row。
   - `HibikiSelectableChip` / `HibikiTagChip` / `HibikiOptionCard`：覆盖 FilterChip/ChoiceChip/tag chip/format card 的 selected fill 和 shape。
   - 改良 `AdaptiveSettingsTextField`：支持 focused/error/disabled state，不固定死 outline side。
   - `HibikiPopupListSurface`：给 native popup dictionary/floating popup 提供可保留边界的 tonal popup 列表壳。

2. 最小静态测试：
   - 禁止 `adaptiveModalSheet` 默认或强制传 `showDragHandle: false`。
   - 在普通 app chrome allowlist 外禁止直接 `TextField`/`TextFormField`、`Card(`、`ListTile(`、`BorderRadius.circular(4/6/8)`、`Border.all(`。
   - 要求普通 `BasePage` 页面使用 `HibikiPageScaffold`/`AdaptiveSettingsScaffold`/明确 allowlist。
   - 要求 bottom sheet 通过 `HibikiModalSheetFrame` 或明确 content-only allowlist。
   - 要求 tag/filter/choice chip 走新的 chip 抽象，允许 Flutter 内置 chip 只出现在抽象内部。

3. 最小 Widget/theme 测试：
   - `ThemeNotifier`：断言 Card 12dp、Dialog 28dp、BottomSheet 28dp + showDragHandle、FAB 16dp、Chip 8dp、buttons Stadium。
   - `HibikiCard`：默认无 border、selected 使用 selected surface、显式 `borderColor` 仍保留。
   - `AdaptiveSettingsSection`：Material title 使用 primary，group radius 12，group fill 使用 token surface，不带 border。
   - `AdaptiveSettingsTextField`：label/hint/submit 保留，focused outline 变 primary，error outline 变 error。
   - `adaptiveModalSheet`：打开后能找到 drag handle，sheet shape 是 28dp 顶部圆角。
   - `HibikiPageScaffold`：Material 分支使用 `tokens.type.pageTitle`，Cupertino 分支保持原生大标题，不破坏 adaptive 约束。

## Risks

- 把 reader pagination、auto sync、TOC header 行为混在 MD3 diff 中，会把视觉审查变成行为回归审查；这不是“高质量”，这是范围污染。
- 只靠 ThemeData 会漏掉所有自绘 surface、手写 container、直接 TextField、popup/sheet content frame；Hibiki 这类历史 UI 很多，必须补抽象和 guard。
- 静态 banned string 过硬会误伤内容渲染预览、日志、代码编辑器、reader content；需要 allowlist 和 Widget test 搭配。
- 过早删除所有 popup border 可能伤害浮层可读性。`HibikiPopupSurface` 保留边界是可接受例外，但应显式记录为 overlay 例外，而不是让各处自由手写。
