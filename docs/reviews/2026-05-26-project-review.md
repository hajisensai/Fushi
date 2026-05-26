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
