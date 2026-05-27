# CCG 并行分析员 A：MD3 全局重设计状态审查

## 结论

【核心判断】现有 `.ccg/tasks/md3-global-redesign/plan.md` 不覆盖用户要求的“所有地方”。它是第一批 token/theme/shared-component 基础层计划，不是全量迁移计划。

【品味评分】黄：方向对，边界错。先改 token 和共享组件是对的，但用 6 个文件就宣称全局重设计，这是计划层面的假完整。

当前工作区已有一轮未提交 UI 改动，覆盖 `hibiki_design_tokens.dart`、`theme_notifier.dart`、`hibiki_material_components.dart`、`settings_shared.dart`、`material_settings_renderer.dart`，以及 `reader_quick_settings_sheet.dart`、`reader_hibiki_page.dart`、`anki_settings_page.dart` 等页面局部。下面结论按“计划覆盖”和“当前实际状态”分开判断。

## Files Found

- `.ccg/tasks/md3-global-redesign/plan.md`：现有计划，只列 Layer 1-3 共 6 个文件，声称“80% centralized, 20% per-page”，没有展开所有 page families。
- `.ccg/tasks/md3-global-redesign/analysis.md`：早期分析，仍是 token/theme/shared component 级别，判断“4 个文件可完成多数视觉变化”。
- `.ccg/tasks/md3-global-redesign/review.md`：已有 Round 1 审查，显示基础层变更已被实现并跑过测试，但不是全量 UI 覆盖审查。
- `docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md`：真正的全量 surface 规格；声明 Entry 3、Pages 53、Shared/support 28，并要求 shared components -> shell -> page groups。
- `docs/design/md3-cupertino/UI_COVERAGE_AUDIT.md`：旧覆盖审计，文档中记录 `unmappedUiFiles=0` 和 `interfaceCoverage=ok`，但当前工作区复跑失败。
- `docs/design/md3-cupertino/COVERAGE.md`：board 到文件的覆盖表；当前仍列不存在的 `reader_hoshi_page.dart` / `reader_hoshi_history_page.dart`。
- `.codex-test/reference/seal/1.jpg` 到 `9.jpg`：实际参考图均存在，尺寸都是 576x1280。
- `hibiki/lib/src/utils/components/hibiki_design_tokens.dart`：当前已有 MD3 radius、surface、type role token 改动。
- `hibiki/lib/src/models/theme_notifier.dart`：当前已有 Material ThemeData component theme 改动。
- `hibiki/lib/src/utils/components/hibiki_material_components.dart`：`HibikiCard`、`HibikiListItem`、`HibikiSearchField`、`HibikiPopupSurface`、`HibikiCompactSearchRow` 等共享 Material 组件。
- `hibiki/lib/src/utils/components/settings_shared.dart`：`AdaptiveSettingsScaffold/Section/Row/TextField/Slider/Segmented` 等设置页共享组件。
- `hibiki/lib/src/utils/adaptive/adaptive_navigation.dart`：`adaptiveBottomBar`、`adaptiveAppBar`，主壳层 Material/Cupertino 导航分支。
- `hibiki/lib/src/utils/adaptive/adaptive_widgets.dart`：`adaptiveAlertDialog`、`adaptiveModalBottomSheet`、`adaptiveSlider` 等 modal/control grammar。
- `hibiki/lib/src/pages/base_page.dart`、`base_source_page.dart`、`base_tab_page.dart`、`base_history_page.dart`、`base_media_search_bar.dart`：页面族基础层，影响 placeholder、popup dictionary、history card、search bar。
- `hibiki/lib/src/pages/implementations/*.dart`：当前实际有 53 个页面实现文件，远多于 plan.md 的 6 个目标文件。
- `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`：当前是大型 reader settings surface，覆盖脚本识别为 UI-building 但覆盖表未纳入。
- `hibiki/lib/src/settings/settings_schema.dart`、`hibiki/lib/src/sync/sync_settings_schema.dart`、`hibiki/lib/src/sync/sync_compare_dialog.dart`、`hibiki/lib/src/models/anki_integration.dart`：当前覆盖脚本识别的漏映射 UI/对话框文件。

## Dependencies

```
Seal reference images 1-9
  -> IMPLEMENTATION_SPEC_FINAL_DRAFT board decisions
  -> COVERAGE/UI_COVERAGE_AUDIT surface map
  -> runtime architecture:
     tokens
       hibiki_design_tokens.dart
       theme_notifier.dart
     shared components
       hibiki_material_components.dart
       settings_shared.dart
       material_settings_renderer.dart
       cupertino_settings_renderer.dart
       adaptive_widgets.dart
       adaptive_navigation.dart
       hibiki_bottom_sheet.dart
       hibiki_icon_button.dart
       hibiki_placeholder_message.dart
       hibiki_tag.dart
       hibiki_toast.dart
     shells
       main.dart
       popup_main.dart
       floating_dict_main.dart
       home_page.dart
       base_page/base_tab_page/base_source_page/base_history_page
     page families
       reader + reader quick settings + audiobook bar
       dictionary + popup dictionary + dictionary management
       settings schema + detail/home renderers
       import/media dialogs
       creator/Anki/card mining dialogs
       collections/stats/tags
       logs/debug/system/sync/profile/language
```

关键依赖关系：

- `theme_notifier.dart` 是 Material ThemeData 根，影响 Card/Dialog/BottomSheet/FAB/Chip/Button/Switch/SnackBar/NavigationBar。
- `hibiki_design_tokens.dart` 被 `HibikiCard`、`HibikiListItem`、settings shared components、popup/search components 消费。
- `settings_shared.dart` 和 `material_settings_renderer.dart` 是设置页族最关键的中间层，`display_settings_page.dart`、`custom_theme_page.dart`、`custom_fonts_page.dart`、`anki_settings_page.dart`、`profile_management_page.dart`、`miscellaneous_settings_page.dart`、`reader_quick_settings_sheet.dart` 都依赖它。
- `adaptive_widgets.dart` 的 `adaptiveAlertDialog` 是大量弹窗入口的公共壳；只靠 `dialogTheme` 不能保证管理型对话框、复杂 import flow、sync compare dialog 都符合目标。
- `base_source_page.dart` 是 reader/dictionary popup 交汇处；`HibikiPopupSurface`、loading placeholder、nested lookup popup 都依赖这里。
- `base_history_page.dart` 和 `reader_hibiki_history_page.dart` 控制书架/history card 的大部分视觉债务。

## Patterns

- 计划只覆盖基础层：`plan.md` 的 Architecture 把 Pages 写成“home, settings, dialogs, reader quick settings, collections...”，但实际任务列表只有 Layer 1 三个文件、Layer 2 两个文件、Layer 3 一个测试文件。证据：`.ccg/tasks/md3-global-redesign/plan.md:3`、`:12`、`:19`、`:253`、`:290`、`:310`。
- 最终规格明确禁止 page-local decoration，要求先 shared components，再 shell，再 page groups。证据：`docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md:21`、`:49`、`:52`、`:53`。
- 最终规格的 surface matrix 是全量迁移入口，至少包含 Entry、Pages、Shared/support 三层。证据：`docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md:10`、`:57`、`:59`、`:69`、`:129`。
- UI 覆盖文档旧状态声称通过：`unmappedUiFiles=0` / `interfaceCoverage=ok`。证据：`docs/design/md3-cupertino/UI_COVERAGE_AUDIT.md:17`、`:28`、`:29`。
- 当前复跑覆盖脚本失败，输出未映射 UI-building 文件：
  - `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
  - `hibiki/lib/src/models/anki_integration.dart`
  - `hibiki/lib/src/models/theme_notifier.dart`
  - `hibiki/lib/src/settings/settings_schema.dart`
  - `hibiki/lib/src/sync/sync_compare_dialog.dart`
  - `hibiki/lib/src/sync/sync_settings_schema.dart`
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - `hibiki/lib/src/utils/spacing.dart`
- 当前代码已实现部分基础层目标：
  - `HibikiRadii` 已有 `card=12`、`dialog=28`、`sheet=28`，见 `hibiki/lib/src/utils/components/hibiki_design_tokens.dart:28`。
  - `HibikiTypeRoles` 已有 `pageTitle` 和 primary 色 `sectionLabel`，见 `hibiki/lib/src/utils/components/hibiki_design_tokens.dart:101`、`:132`、`:136`。
  - `ThemeData` 已有 `appBarTheme`、`navigationBarTheme`、`dialogTheme`、`cardTheme`、`bottomSheetTheme`、`floatingActionButtonTheme`、`chipTheme`、button themes，见 `hibiki/lib/src/models/theme_notifier.dart:254`、`:281`、`:293`、`:329`、`:336`、`:343`、`:352`、`:360`。
  - `HibikiCard`、`HibikiListItem`、`HibikiPopupSurface` 是正确的共享组件入口，见 `hibiki/lib/src/utils/components/hibiki_material_components.dart:5`、`:63`、`:362`。
  - `SettingsSectionHeader` 和 `AdaptiveSettings*` 是设置页族正确入口，见 `hibiki/lib/src/utils/components/settings_shared.dart:8`、`:30`、`:94`、`:178`、`:391`、`:600`。
- 当前仍存在 page-local hardcoded visual debt：
  - `borderRadius.circular(4/6/8)`、`Border.all`、局部 border 仍散落在 `custom_theme_page.dart`、`reader_hibiki_history_page.dart`、`dictionary_popup_native.dart`、`audiobook_play_bar.dart`、`reader_quick_settings_sheet.dart`、`sync_compare_dialog.dart` 等文件。
  - 这些不全是错误；内容渲染、色板、阅读器正文、popup 边界可能需要例外。但它们必须逐项分类，不能让 plan 用 token 改动一笔带过。

## Critical

### C1. plan.md 没有覆盖“所有地方”

现有计划只列 6 个文件：

- `hibiki_design_tokens.dart`
- `theme_notifier.dart`
- `hibiki_material_components.dart`
- `material_settings_renderer.dart`
- `settings_shared.dart`
- `md3_design_system_static_test.dart`

而当前实际页面实现文件有 53 个，最终设计规格还列 Entry、Pages、Shared/support 三层 surface。`plan.md` 没有给出每个 surface 的迁移状态、验收点、截图/手工验证路径，也没有按 18 个 board 或 9 张 Seal 参考图对应页面族拆任务。

影响：后续执行者会以为“基础 token 改完 = 全局完成”，实际会漏掉 popup dictionary、reader chrome、history cards、import/media dialogs、sync/settings schema、debug/log/system 等大量 UI。

修复建议：把 `plan.md` 升级为全量迁移计划：按 `IMPLEMENTATION_SPEC_FINAL_DRAFT.md` 的 Entry / Shared-support / Page families 分批，给每个 family 写文件清单、共享组件依赖、验收截图、风险和验证命令。

### C2. 覆盖审计文档已经与当前工作区漂移

`UI_COVERAGE_AUDIT.md` 写着 `interfaceCoverage=ok`，但当前复跑：

```text
Unmapped UI-building file: hibiki\lib\src\media\audiobook\reader_quick_settings_sheet.dart
Unmapped UI-building file: hibiki\lib\src\models\anki_integration.dart
Unmapped UI-building file: hibiki\lib\src\models\theme_notifier.dart
Unmapped UI-building file: hibiki\lib\src\settings\settings_schema.dart
Unmapped UI-building file: hibiki\lib\src\sync\sync_compare_dialog.dart
Unmapped UI-building file: hibiki\lib\src\sync\sync_settings_schema.dart
Unmapped UI-building file: hibiki\lib\src\utils\components\hibiki_material_components.dart
Unmapped UI-building file: hibiki\lib\src\utils\spacing.dart
```

影响：全量设计覆盖的前置 gate 失效。继续迁移会基于过期 coverage 做任务拆分，必然漏 surface。

修复建议：先修 `COVERAGE.md` / `UI_COVERAGE_AUDIT.md` / verifier manifest，使 `node docs\design\md3-cupertino\verify-interface-coverage.mjs` 在当前工作区重新通过，再谈全局完成。

### C3. reader_hoshi/reader_hibiki 命名映射不一致

当前代码存在 `reader_hibiki_page.dart` 和 `reader_hibiki_history_page.dart`，没有 `reader_hoshi_page.dart` 文件。但 `COVERAGE.md` 和最终规格仍列 `reader_hoshi_page.dart` / `reader_hoshi_history_page.dart`。证据：`docs/design/md3-cupertino/COVERAGE.md:85-88`、`docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md:119-120`。

影响：阅读器是高风险 surface。设计和执行计划如果同时引用不存在文件与当前文件，后续拆任务会错分，甚至可能把当前 Hoshi/Hibiki reader 路径当成两个独立页面。

修复建议：确认当前命名边界后更新 coverage/spec。不要重命名持久化 key；只修设计文档的文件映射和任务拆分。

## Warning

### W1. 迁移优先级应从 shared + shell 开始，而不是继续局部页面打补丁

可执行优先级建议：

1. **P0 覆盖 gate 修复**：修 coverage/verifier 漂移，补 `reader_quick_settings_sheet.dart`、`settings_schema.dart`、`sync_compare_dialog.dart`、`sync_settings_schema.dart`、`anki_integration.dart`、`theme_notifier.dart`、`hibiki_material_components.dart`、`spacing.dart` 的映射或候选说明。
2. **P1 主题和 token 收口**：当前已有改动，但需补静态扫描，确认 `ThemeData`、tokens、`HibikiCard`、`HibikiListItem`、`HibikiPopupSurface`、settings shared 的例外边界。
3. **P2 壳层**：`main.dart`、`popup_main.dart`、`floating_dict_main.dart`、`home_page.dart`、`adaptive_navigation.dart`、`adaptive_widgets.dart`。它们决定启动/loading/error、主导航、popup process、floating dictionary 和 modal grammar。
4. **P3 设置页族**：`settings_home_page.dart`、`settings_detail_page.dart`、`material_settings_renderer.dart`、`cupertino_settings_renderer.dart`、`settings_schema.dart`、`settings_actions.dart`、`sync_settings_schema.dart`、`display/custom_theme/custom_fonts/anki/profile/misc`。这些最适合共享组件一次收口。
5. **P4 词典族**：home dictionary、popup dictionary、native/webview popup、dictionary result/term/entry、dictionary management/import/progress/settings。这里要保护 lookup 行为和 popup 层级。
6. **P5 reader + audiobook**：`reader_hibiki_page.dart`、`reader_quick_settings_sheet.dart`、`audiobook_play_bar.dart`、lyrics、reader history cards、book import/rematch。视觉改动必须带真实 emulator 验证。
7. **P6 media/import/creator/dialogs**：book/audiobook import、media item/edit/source picker、example sentences、stash、audio recorder、crop、segmentation、Anki mapping。
8. **P7 collections/stats/tags/log/debug/system/sync**：集合、统计、标签、日志、websocket、sync compare。这里主要是列表密度、FAB、空态和对话框一致性。

### W2. plan.md 没有处理 Cupertino/material adaptive 边界

需求要求保持 Material/Cupertino adaptive 分支。实际关键边界在 `adaptive_navigation.dart`、`adaptive_widgets.dart`、`settings_shared.dart`、`cupertino_settings_renderer.dart`、`material_settings_renderer.dart`。现有 plan 只改 Material token/theme，缺少“Material 改动如何不破坏 Cupertino 体验”的检查清单。

### W3. Dialog 和 bottom sheet 不能只靠 ThemeData

大量弹窗走 `adaptiveAlertDialog`，复杂管理 UI 有的需要 `Dialog` frame 而不是 `CupertinoAlertDialog`/`AlertDialog`。`BookImportDialog`、`AudiobookImportDialog`、`dictionary_dialog_page.dart`、`sync_compare_dialog.dart`、reader quick settings、dictionary progress 都需要按 flow 审，不是 28dp radius 就结束。

### W4. 硬编码圆角/border 需要分类，而不是机械删除

当前 grep 仍看到多个 `borderRadius.circular(4/6/8)` 和 `Border.all`。其中一部分是内容预览、色板、reader正文、popup边界，可能合理；另一部分是旧卡片/列表视觉。计划应该把这些分为：

- shared component 应统一收口；
- content-rendering 允许例外；
- popup/overlay 边界允许例外；
- page-local decoration 需要迁移。

### W5. 验证计划太窄

现有 plan 验证只写 `flutter analyze`、`flutter test` 和若干视觉检查。对于用户要求的“所有地方”，还需要：

- 覆盖 verifier 通过；
- 静态测试防止旧 UI dependency 回流；
- Android emulator 关键路径截图；
- reader 手工验证；
- popup process / floating dictionary 单独启动验证；
- dark/light 与 Material/Cupertino 模式分别检查。

## Info

### I1. 参考图可执行解读

Seal 1-9 对应的是一个小而明确的 MD3 语言包：

- 1：主 shell，大标题、rounded-square FAB、卡片化列表。
- 2：bottom sheet，drag handle、分段标题、chips、双按钮。
- 3：选择列表，checkbox、缩略图+文本。
- 4：下载/history，横向 filter chips、列表、详情弹窗。
- 5：格式/card option，selected = primaryContainer。
- 6：模板编辑，OutlinedTextField + floating label + chips wrap。
- 7：命名/选项，toggle highlight card、radio list。
- 8/9：显示设置 light/dark，preview card、颜色圆点、toggle+icon row、完整暗色映射。

这些参考图最适合先落到 shared components 和 settings/schema family，而不是逐页复制布局。

### I2. 最应该先改的共享组件

按影响面排序：

1. `hibiki_design_tokens.dart`
2. `theme_notifier.dart`
3. `hibiki_material_components.dart`
4. `settings_shared.dart`
5. `material_settings_renderer.dart`
6. `adaptive_widgets.dart`
7. `adaptive_navigation.dart`
8. `hibiki_bottom_sheet.dart`
9. `hibiki_icon_button.dart`
10. `hibiki_placeholder_message.dart`
11. `hibiki_tag.dart`
12. `hibiki_toast.dart`
13. `hibiki_text_selection_controls.dart`

### I3. 最应该先改的壳层

1. `main.dart`：主 `MaterialApp`、loading/error/splash shell、CupertinoTheme builder。
2. `popup_main.dart`：Android process-text popup dictionary app。
3. `floating_dict_main.dart`：floating dictionary overlay app。
4. `home_page.dart`：mobile bottom navigation、desktop NavigationRail、top actions。
5. `base_page.dart`：全局 error/loading/selection toolbar 行为。
6. `base_tab_page.dart` / `base_media_search_bar.dart`：home tab/search family。
7. `base_source_page.dart`：reader/dictionary popup overlay family。
8. `base_history_page.dart`：library/history cards。

### I4. 最应该先改的页面族

1. Settings/schema family：最集中、最容易共享组件收口。
2. Dictionary family：搜索、result browsing、popup lookup 是高频核心。
3. Reader family：高风险，必须最后带手工验证，不要只改视觉。
4. Import/media/dialog family：modal grammar 和 action rows 统一。
5. Creator/Anki family：mapping panel、field preview、recorder/crop/segmentation。
6. Collections/stats/tags family：lists、chips、FAB、empty states。
7. Logs/debug/system/sync family：dense operational surfaces，避免假状态。

## Risks

- **破坏当前未提交改动**：工作区已有 14 个文件 UI 改动，本报告没有修改业务代码。后续执行必须先确认这些改动归属，不能 reset 或覆盖。
- **覆盖文档漂移导致任务拆错**：verifier 当前失败，必须先修 coverage gate。
- **阅读器路径混淆**：当前代码是 `ReaderHibiki*` 文件名，但项目说明里仍强调当前 EPUB reader 是 Hoshi 路径。迁移文档要描述清楚“文件名/实现路径/历史命名”的关系，不要引入 TTU 或错误重命名。
- **把 content typography 当 chrome typography 改坏**：reader正文、词典结构化内容、lyrics、preview/editor 内容不应被普通 chrome text token 机械覆盖。
- **Cupertino 管理弹窗被 AlertDialog 规则误伤**：复杂管理 UI 需要 real Dialog/sheet frame，不能被 `adaptiveAlertDialog` 的 compact alert shell 挤压。
- **全局 dark mode 映射不足**：Seal 8/9 要求 light/dark 成对检查；只看 light 的 token 很容易漏 surfaceContainer/outlineVariant/onSurfaceVariant 对比度。

## 建议的下一步

1. 先更新 `plan.md`，把它从“基础层小计划”改成全量迁移计划。
2. 先让 `verify-interface-coverage.mjs` 在当前工作区重新通过。
3. 按 P0-P7 切批，每批都写对应 files、视觉目标、验证方式。
4. 对 reader/popup/dictionary/import/sync 这些高风险 surface，要求截图或 UI hierarchy 证据，不要只跑单元测试。
