# 2026-05-26 Project Review

## Round 1 - Material 3 visual/design audit

### Scope

- Design contract:
  - `docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md`
  - `docs/design/md3-cupertino/RECOMMENDED_FINAL_SELECTION.zh-CN.txt`
- Runtime theme and shared primitives:
  - `hibiki/lib/src/models/theme_notifier.dart`
  - `hibiki/lib/src/utils/adaptive/adaptive_navigation.dart`
  - `hibiki/lib/src/utils/components/settings_shared.dart`
  - `hibiki/lib/src/settings/material_settings_renderer.dart`
- Page/component samples with visible MD2-era residue:
  - `hibiki/lib/src/pages/base_media_search_bar.dart`
  - `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
  - `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`
  - `hibiki/lib/src/pages/implementations/dictionary_entry_page.dart`
  - `hibiki/lib/src/pages/implementations/media_source_picker_dialog_page.dart`
  - `hibiki/lib/src/pages/implementations/reading_statistics_page.dart`
  - `hibiki/lib/src/pages/implementations/custom_theme_page.dart`
  - `hibiki/lib/src/utils/components/hibiki_list_tile.dart`
  - `hibiki/lib/src/utils/components/hibiki_text_selection_controls.dart`
- Reference baseline:
  - Flutter Material 3 migration guide: `https://docs.flutter.dev/release/breaking-changes/material-3-migration`
  - Flutter `ThemeData.useMaterial3` API: `https://api.flutter.dev/flutter/material/ThemeData/useMaterial3.html`
  - Material 3 guidance centers on `ColorScheme`, updated typography, new component implementations, and surface/elevation color roles.

### Findings

#### HBK-AUDIT-001 - MD3 is enabled, but there is no complete design-token layer

- severity: HIGH
- status: open
- files/lines:
  - `hibiki/lib/src/models/theme_notifier.dart:249-314`
  - `docs/design/md3-cupertino/IMPLEMENTATION_SPEC_FINAL_DRAFT.md:53-58`
- root cause:
  - `ThemeData(useMaterial3: true)` and `ColorScheme.fromSeed()` are present, but the runtime system stops at a partial theme. There is no single app token layer for radius, spacing, density, state layers, component surface roles, icon sizes, and page-level layout grammar.
  - The design spec explicitly says tokens and shared components come first, but runtime code still lets many pages choose their own Card/ListTile/TextField/PopupMenu/Chip shapes locally.
- impact:
  - The app can technically be "Material 3 on paper" while still visually feeling like old Flutter Material 2: same flat lists, hand-sized text, local rounded rectangles, hand-selected containers, and inconsistent density.
  - This is the biggest reason "没那味" is a fair criticism. The theme flag is not a design system.
- fix:
  - Add a small `HibikiDesignTokens` / `HibikiComponentTheme` layer consumed by shared components:
    - radius: container/card/chip/sheet/dialog/control
    - spacing: page/content/list/row/control
    - surface roles: page, grouped section, card, elevated overlay, selected row
    - typography aliases: page title, section label, list title, metadata, dense control label
    - density policy: normal mobile, compact admin, reader chrome
  - Move page-local `BorderRadius.circular(...)`, `fontSize: ...`, `VisualDensity.compact`, and ad hoc `surfaceContainer*` choices behind these shared tokens.
- verification:
  - Add a static audit test that flags new page-local visual constants in migrated surfaces unless the file is a token/component implementation.
  - Widget-test at least the home shell, dictionary search, settings, and reader-history surfaces in light/dark/custom themes.

#### HBK-AUDIT-002 - Search UI still uses old floating-search grammar instead of MD3 SearchBar/SearchAnchor semantics

- severity: HIGH
- status: open
- files/lines:
  - `hibiki/lib/src/pages/base_media_search_bar.dart:36-69`
  - `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:151-189`
- root cause:
  - `BaseMediaSearchBar` still depends on `material_floating_search_bar` and hard-codes a zero-radius, zero-elevation bar with a legacy floating-search layout.
  - `HomeDictionaryPage` builds a custom 42px `TextField` search box with local fill, border, radius, padding, and icon sizing instead of a shared MD3 search component.
- impact:
  - Search is one of the most visible surfaces in Hibiki. Right now it reads as "old custom Flutter search field", not MD3. The dictionary tab can never feel fully MD3 while its primary control bypasses SearchBar/SearchAnchor-style component semantics.
  - The two search implementations also drift visually from each other.
- fix:
  - Create one shared `HibikiSearchBar` abstraction:
    - Material path uses Flutter MD3 `SearchBar` / `SearchAnchor` where the workflow fits.
    - Existing paged media search can keep its controller semantics, but its shell must consume the same tokens and component theme.
    - Dictionary search and media search should share height, shape, state layer, leading/trailing actions, hint typography, and suggestion/result surfaces.
- verification:
  - Static test: app search surfaces should not instantiate `FloatingSearchBar` or raw search `TextField` outside the shared search component.
  - Screenshot/widget tests for dictionary tab empty, searching, result, history, and media search states.

#### HBK-AUDIT-003 - Dense ListTile/Card patterns are still page-local instead of MD3 list/card components

- severity: HIGH
- status: open
- files/lines:
  - `hibiki/lib/src/settings/material_settings_renderer.dart:57-82`
  - `hibiki/lib/src/settings/material_settings_renderer.dart:160-177`
  - `hibiki/lib/src/settings/material_settings_renderer.dart:371-423`
  - `hibiki/lib/src/utils/components/hibiki_list_tile.dart:43-82`
  - `hibiki/lib/src/pages/implementations/media_source_picker_dialog_page.dart:84-124`
  - `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:278-353`
  - `hibiki/lib/src/pages/implementations/reading_statistics_page.dart:238-267`
- root cause:
  - There are shared settings primitives, but the Material renderer and many page/dialog surfaces still build raw `Material + ListTile`, `Card`, `InkWell`, or custom rows directly.
  - Several rows opt into `dense: true`, copied font sizes, 12px radii, 0 elevation cards, and custom borders. That is old Material list grammar with newer colors sprinkled over it.
- impact:
  - Inconsistent row heights, paddings, icon alignment, selection treatment, and card shape make the app feel assembled from old widgets rather than one MD3 component set.
  - Settings were partially cleaned up, but dialogs and management surfaces still leak the old grammar.
- fix:
  - Make `HibikiListTile`, `AdaptiveSettingsRow`, and a new `HibikiListItem` / `HibikiCard` the only public row/card APIs for feature pages.
  - Convert media-source picker, dictionary history cards, reading-stat summary cards, and Material settings destination rows onto those components.
  - Keep compact density as a named mode, not a random `dense: true` or `VisualDensity.compact`.
- verification:
  - Extend `settings_migration_static_test.dart` into a broader design-system static test:
    - migrated surfaces should not use raw `ListTile(`, `Card(`, `CheckboxListTile(`, or `SwitchListTile(` unless the file is a component renderer.
  - Golden/screenshot comparison for list-heavy pages.

#### HBK-AUDIT-004 - Menus and text-selection toolbar still use MD2-era PopupMenu/Card surfaces

- severity: MEDIUM
- status: open
- files/lines:
  - `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart:904-928`
  - `hibiki/lib/src/pages/implementations/dictionary_entry_page.dart:101-126`
  - `hibiki/lib/src/utils/components/hibiki_text_selection_controls.dart:223-247`
- root cause:
  - Dictionary item actions still use `PopupMenuButton` with hand-clipped 30px/22px menu anchors.
  - Text selection wraps `TextSelectionToolbar` in a plain `Card` and uses a `PopupMenuButton` for overflow.
- impact:
  - Menus are small but high-frequency. These controls keep the old "three-dot popup card" feel, especially on desktop/tablet where Flutter's newer menu system is more appropriate.
- fix:
  - Introduce `HibikiOverflowMenu`:
    - Material desktop/web path should consider `MenuAnchor`.
    - Mobile path can keep popup semantics if needed, but shape, size, padding, and state colors must come from the component theme.
  - Replace the text-selection toolbar wrapper with a tokenized toolbar surface.
- verification:
  - Widget tests for dictionary entry menu and selection toolbar overflow.
  - Static test blocks direct `PopupMenuButton` outside the shared overflow menu component, with explicit exceptions if needed.

#### HBK-AUDIT-005 - Typography is repeatedly hand-sized, so the M3 type scale cannot govern the UI

- severity: MEDIUM
- status: open
- files/lines:
  - `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:306-341`
  - `hibiki/lib/src/pages/implementations/custom_theme_page.dart:632-688`
  - `hibiki/lib/src/utils/components/hibiki_list_tile.dart:61-72`
  - `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart:441-490`
- root cause:
  - Many widgets pull a raw `fontSize` from a theme role or set literal sizes like 18, 13, 12, 16, 15. That preserves visual habits from older code instead of using `textTheme` roles directly.
- impact:
  - Text hierarchy becomes inconsistent: dictionary history, preview cards, old list tiles, and dialogs do not share a reliable M3 type scale.
  - Accessibility scaling and dense/comfortable variants become harder to control because every surface has local typography decisions.
- fix:
  - Define semantic text aliases and use them directly:
    - `listTitle`, `listSubtitle`, `metadata`, `sectionLabel`, `controlLabel`, `previewBody`, `readerChrome`
  - Ban page-local `fontSize:` except in token definitions, text renderers, or truly content-specific previews.
- verification:
  - Static test for `fontSize:` in `lib/src/pages` with an allowlist.
  - Visual regression for text scale 1.0 and 1.3.

#### HBK-AUDIT-006 - Color roles are partly correct, but page-local surface choices flatten the MD3 palette

- severity: MEDIUM
- status: open
- files/lines:
  - `hibiki/lib/src/pages/base_media_search_bar.dart:43-47`
  - `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:171-185`
  - `hibiki/lib/src/pages/implementations/reading_statistics_page.dart:240-243`
  - `hibiki/lib/src/pages/implementations/custom_theme_page.dart:625-656`
- root cause:
  - The app uses `ColorScheme`, but individual pages pick `surfaceContainerHigh`, `surfaceContainerHighest.withValues(alpha: 0.5)`, `surface`, `surfaceContainerLow`, and custom borders independently.
  - This creates a washed, inconsistent surface ladder instead of a deliberate MD3 elevation/surface model.
- impact:
  - The UI feels neither clearly tonal nor clearly layered. Components look flat, bordered, and old-school even when the colors are technically from the M3 scheme.
- fix:
  - Define app-specific surface roles:
    - `appSurface`, `groupSurface`, `cardSurface`, `selectedSurface`, `searchSurface`, `overlaySurface`
  - Components consume these roles; pages stop choosing `surfaceContainer*` directly unless they are visualizing a color theme.
- verification:
  - Static test for direct `surfaceContainer` references in page files.
  - Manual screenshot pass in light, dark, system dynamic, and custom theme.

### Overall judgment

【品味评分】

🟡 凑合，偏旧。

The base theme is not garbage: `ThemeNotifier` already uses `useMaterial3: true`, seeded color schemes, dynamic color support, and some component themes. Navigation also uses `NavigationBar` on Material platforms instead of `BottomNavigationBar`.

But the runtime design system is incomplete. The real problem is local visual decision-making: search bars, list rows, cards, menus, typography, and surface colors are still hand-built in many pages. That is exactly how an app ends up "technically MD3" but visually not MD3.

【核心判断】

✅ 值得做：这是用户会立刻感知的真实问题，不是过度设计。修法不是重画几个页面，而是把 token/component 层补齐，然后逐页迁移掉旧组件语法。

【关键洞察】

- 数据结构：UI 的核心数据不是页面，而是 token -> component -> surface。现在很多页面绕过 component 层直接画自己。
- 复杂度：特殊情况太多。每个页面都在决定 radius、fontSize、surface、dense、menu shape，这些应该收敛到少数共享组件。
- 风险点：一次性全量重做会破坏已有工作流。应该先迁移最高曝光组件：search -> row/card -> menu -> typography/surface audit。

### Next Scope

1. 先做设计系统组件审查：列出所有允许直接使用 `Card/ListTile/PopupMenuButton/TextField/fontSize/surfaceContainer` 的文件白名单。
2. 第二轮聚焦 search surfaces：`BaseMediaSearchBar`、`HomeDictionaryPage`、dictionary popup lookup。
3. 第三轮聚焦 list/card surfaces：reader shelf、dictionary history、collections、statistics、media source picker。
4. 第四轮补截图验证：Android Material path light/dark/custom theme，确认视觉层级和 MD3 味道，而不是只看代码 token。

## Round 2 - Material 3 repair verification

### Scope

- Commits reviewed:
  - `69d45558c feat(ui): add HibikiDesignTokens + HibikiCard/ListItem/SectionHeader components`
  - `6a6c73f39 refactor(ui): migrate pages + settings renderer to HibikiCard/ListItem`
- Current working-tree repairs reviewed:
  - `hibiki/lib/src/pages/base_media_search_bar.dart`
  - `hibiki/lib/src/pages/base_tab_page.dart`
  - `hibiki/lib/src/media/media_type.dart`
  - `hibiki/lib/src/media/sources/reader_hibiki_source.dart`
  - `hibiki/pubspec.yaml`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
- Verification guards:
  - `hibiki/test/settings/md3_design_system_static_test.dart`
  - `hibiki/test/pages/media_source_picker_dialog_page_test.dart`
  - `hibiki/test/settings/settings_renderer_test.dart`
  - `hibiki/test/i18n/i18n_completeness_test.dart`

### Findings

#### HBK-AUDIT-001 - Token layer missing

- severity: HIGH
- status: resolved
- files/lines:
  - `hibiki/lib/src/utils/components/hibiki_design_tokens.dart`
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
- root cause:
  - Round 1 was right: `useMaterial3` alone did not give the app a component contract.
- impact:
  - Fixed for migrated Material surfaces. Feature pages now have shared surface, radius, spacing, typography and row/card/search/menu primitives instead of each page inventing local visual rules.
- fix:
  - Added `HibikiDesignTokens`, `HibikiCard`, `HibikiListItem`, `HibikiSearchField`, and `HibikiOverflowMenu`.
  - Added static checks that require high-exposure pages to consume those primitives.
- verification:
  - `flutter test test/settings/md3_design_system_static_test.dart` passed.

#### HBK-AUDIT-002 - Search shell used legacy floating search

- severity: HIGH
- status: resolved
- files/lines:
  - `hibiki/lib/src/pages/base_media_search_bar.dart`
  - `hibiki/lib/src/pages/base_tab_page.dart`
  - `hibiki/lib/src/media/media_type.dart`
  - `hibiki/lib/src/media/sources/reader_hibiki_source.dart`
  - `hibiki/pubspec.yaml`
- root cause:
  - The old `material_floating_search_bar` dependency controlled page search state and actions, so the app still carried an MD2-era search shell even after the dictionary page moved to `HibikiSearchField`.
- impact:
  - Fixed. Media search now uses the shared MD3 search field, local `TextEditingController` / `FocusNode` state, and plain Hibiki icon actions. The dead dependency was removed from `pubspec.yaml` and `pubspec.lock`.
- fix:
  - Replaced `FloatingSearchBar` and `FloatingSearchBarAction` usage in the shared media search path.
  - Removed `FloatingSearchBarController` from `MediaType`.
  - Kept existing search data flow: submit, suggestions, search history, paging controller, source actions, and change-source dialog.
- verification:
  - `rg -n "material_floating_search_bar|FloatingSearchBar|floatingSearchBarController" hibiki/lib hibiki/test -g "*.dart"` only finds test guard strings.
  - `flutter test test/settings/md3_design_system_static_test.dart` passed.

#### HBK-AUDIT-003 - Page-local ListTile/Card grammar

- severity: HIGH
- status: resolved for audited high-exposure surfaces
- files/lines:
  - `hibiki/lib/src/settings/material_settings_renderer.dart`
  - `hibiki/lib/src/utils/components/hibiki_list_tile.dart`
  - `hibiki/lib/src/utils/components/hibiki_bottom_sheet.dart`
  - `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
  - `hibiki/lib/src/pages/implementations/media_source_picker_dialog_page.dart`
  - `hibiki/lib/src/pages/implementations/reading_statistics_page.dart`
- root cause:
  - Settings rows, dictionary history, statistics panels and picker rows were still built as local `Card` / `ListTile` / custom rows.
- impact:
  - Fixed for the surfaces above. Static tests now block direct old primitive use in those files.
- fix:
  - Migrated to `HibikiCard` and `HibikiListItem`.
  - Updated media source picker test so it asserts rendered source identity, not the obsolete `ListTile` implementation type.
- verification:
  - `flutter test test/settings/md3_design_system_static_test.dart` passed.
  - `flutter test test/widgets/hibiki_list_tile_test.dart` passed.
  - `flutter test test/pages/media_source_picker_dialog_page_test.dart --plain-name "media source picker fits a compact desktop window"` passed.

#### HBK-AUDIT-004 - PopupMenu/Card menus

- severity: MEDIUM
- status: resolved for audited dictionary and text-selection surfaces
- files/lines:
  - `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`
  - `hibiki/lib/src/pages/implementations/dictionary_entry_page.dart`
  - `hibiki/lib/src/utils/components/hibiki_text_selection_controls.dart`
  - `hibiki/lib/src/pages/base_source_page.dart`
  - `hibiki/lib/src/pages/implementations/dictionary_term_page.dart`
- root cause:
  - Dictionary management and selection toolbar actions used direct `PopupMenuButton` / `Card` surfaces.
- impact:
  - Fixed for the audited paths. `PopupMenuButton` is now behind `HibikiOverflowMenu`, and toolbar/loading/term surfaces use `HibikiCard`.
- fix:
  - Replaced direct menu/card construction with shared MD3 primitives.
- verification:
  - `flutter test test/settings/md3_design_system_static_test.dart` passed.

#### HBK-AUDIT-005 - Typography hand sizing

- severity: MEDIUM
- status: resolved for app chrome and audited feature rows
- files/lines:
  - `hibiki/lib/src/utils/components/hibiki_design_tokens.dart`
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - `hibiki/lib/src/utils/components/hibiki_list_tile.dart`
  - `hibiki/lib/src/utils/components/hibiki_search_history.dart`
  - `hibiki/lib/src/pages/implementations/home_dictionary_page.dart`
  - `hibiki/lib/src/pages/implementations/collections_page.dart`
- root cause:
  - The worst row/card/search surfaces had hand-sized text instead of shared type roles.
  - Search history and collection rows still carried old copied `fontSize` decisions after the first migration.
- impact:
  - Fixed on migrated row/search/card surfaces by using `HibikiTypeRoles`.
  - Remaining literal `fontSize` usage is scoped to content-specific rendering and previews: reader typography, logs, dictionary native content, CSS/editor fields, audio import diagnostics, charts, and theme color previews. Those are not list/card/menu chrome and should not be forced into one app row type scale.
- fix:
  - Centralized list title, subtitle, metadata, section label and control label styles in `HibikiTypeRoles`.
  - Migrated search history and collections list rows to `HibikiListItem`, removing their page-local row text sizing.
- verification:
  - Static guard blocks old hand-sized row values in migrated app chrome surfaces.
  - `flutter test test/settings/md3_design_system_static_test.dart` passed.

#### HBK-AUDIT-006 - Page-local surface roles

- severity: MEDIUM
- status: resolved for app chrome and audited feature rows
- files/lines:
  - `hibiki/lib/src/utils/components/hibiki_design_tokens.dart`
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - migrated dictionary/settings/statistics/source-picker/collections/tag/media-dialog/update/sync surfaces
- root cause:
  - Round 1 found direct `surfaceContainer*` choices scattered through high-exposure pages.
  - Several ordinary chrome surfaces still used direct `Card`, `ListTile`, or `PopupMenuButton` even after the initial high-exposure pass.
- impact:
  - Fixed for migrated shared component surfaces. Ordinary app chrome now routes list/card/menu surfaces through `HibikiCard`, `HibikiListItem`, and `HibikiOverflowMenu`.
  - Remaining direct `surfaceContainer*` references are token definitions, adaptive/settings internals, reader chrome, content rendering, charts, or explicit custom-theme previews where the surface itself is being demonstrated.
- fix:
  - Centralized page/group/card/selected/search/overlay colors in `HibikiSurfaceColors`.
  - Added a second static guard covering collections, tag management, media item dialog actions, update download overlay, sync compare select-all menu, search history rows, and custom theme preview shell.
- verification:
  - Static guard blocks direct old list/card/menu/surface roles in audited app chrome files.
  - `flutter test test/settings/md3_design_system_static_test.dart` passed.

### Overall Judgment

【品味评分】

🟢 好品味，仍有内容渲染与专项页面债务。

The important part is fixed: the app no longer merely flips `useMaterial3` while high-exposure Material pages keep drawing MD2 rows, cards, menus and search bars by hand. The data structure is now sane: tokens feed shared components, and pages consume the components.

This does not mean every single page in `lib/src/pages` is pixel-perfect MD3. It means the audited high-risk surfaces now have a contract and a regression guard. Remaining raw widgets are content-rendering or specialized surfaces: native popup dictionary content, reader history cards, editor fields, diagnostics, logs, charts, and explicit theme previews. Those should be migrated page by page with a failing guard first, not by a blind rewrite.

### Verification

- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart --reporter expanded`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\widgets\hibiki_list_tile_test.dart --reporter expanded`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\settings_renderer_test.dart --reporter expanded`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\pages\media_source_picker_dialog_page_test.dart --plain-name "media source picker fits a compact desktop window" --reporter expanded`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\i18n\i18n_completeness_test.dart --plain-name "i18n completeness every translation covers 100% of base keys" --reporter expanded`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test` (1131 tests)
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat tool\i18n_sync.dart`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run slang`
- Blocked by existing generated build directory state: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .` still fails while listing `build\flutter_inappwebview_android\.transforms\...\headless_in_app_webview\*`. Targeted formatting of touched Dart files passed.

### Next Scope

1. Do not reopen the MD2 search shell. Keep `material_floating_search_bar` out of runtime code.
2. Next cleanup should target the remaining non-audited high-visibility page families in this order: native popup dictionary, reader history cards, media edit/import dialogs, and editor/diagnostic shells.
3. For those pages, add a failing static/widget check first, then migrate ordinary app chrome to existing `HibikiCard`, `HibikiListItem`, `HibikiSearchField`, or add one missing shared primitive if the existing component is the wrong data structure.
4. Treat content-rendering typography as a deliberate exception only when the font size is the user content being previewed or rendered, not chrome text pretending to be content.
