# Analysis: Hibiki MD3 Global Redesign

## Gap Analysis: Seal MD3 vs Hibiki Current

### 1. Design Tokens (`hibiki_design_tokens.dart`)

| Token | Current | Seal Target | Change |
|-------|---------|-------------|--------|
| `HibikiRadii.card` | 8 | 12 | +4 |
| `HibikiRadii.group` | 8 | 12 | +4 |
| `HibikiRadii.dialog` | 16 | 28 | +12 |
| `HibikiRadii.menu` | 8 | 12 | +4 |
| `HibikiRadii.chip` | 8 | 8 | NO CHANGE |
| `HibikiRadii.control` | 16 | 16 | NO CHANGE |
| `HibikiSpacingTokens.page` | 16 | 16 | NO CHANGE |
| `HibikiSpacingTokens.gap` | 8 | 8 | NO CHANGE |
| `HibikiTypeRoles.sectionLabel` color | onSurfaceVariant | **primary** | KEY CHANGE |

**New tokens needed:**
- `HibikiRadii.sheet` — 28dp, for bottom sheet top corners
- `HibikiTypeRoles.pageTitle` — Headline Large for page titles
- `HibikiSurfaceColors.primaryContainer` — for FAB/toggle highlight
- `HibikiSurfaceColors.primary` — for section headers

### 2. ThemeData Component Themes (`theme_notifier.dart`)

#### Existing (needs update)
| Component | Current | Target |
|-----------|---------|--------|
| dialogTheme | RoundedRect 16dp | RoundedRect 28dp |
| popupMenuTheme | RoundedRect 4dp | RoundedRect 12dp |
| snackBarTheme | RoundedRect 4dp | RoundedRect 12dp |
| appBarTheme | scrolledUnderElevation: 3 | scrolledUnderElevation: 0 |
| switchTheme | Custom colors, no icon | Add thumbIcon (check) |
| navigationBarTheme | Minimal | Add indicator shape + label |
| inputDecorationTheme | OutlineInputBorder | Keep, verify floating label |

#### Missing (needs addition)
| Component | Configuration |
|-----------|--------------|
| **CardTheme** | Filled, surfaceContainerLow, 12dp radius, 0 elevation |
| **BottomSheetTheme** | 28dp top corners, surfaceContainerLow, showDragHandle |
| **FloatingActionButtonTheme** | Large rounded rect (16dp), primaryContainer |
| **ChipTheme** | Outlined default, primaryContainer selected |
| **FilledButtonTheme** | Primary fill, capsule shape |
| **OutlinedButtonTheme** | Outline border, capsule shape |
| **TextButtonTheme** | Primary text, capsule shape |
| **DividerThemeData** | outlineVariant color |

### 3. Shared Components

#### HibikiCard (`hibiki_material_components.dart`)
- **Current**: Border-based (`BorderSide` + 8dp radius)
- **Target**: Tonal elevation (surfaceContainerLow/surfaceContainer, NO border, 12dp radius)
- **Impact**: HIGH — used across entire app

#### SettingsSectionHeader (`settings_shared.dart`)
- **Current**: Uses `onSurfaceVariant` color
- **Target**: Use `primary` color (Seal pattern)
- **Impact**: All settings pages

#### MaterialSettingsRenderer (`material_settings_renderer.dart`)
- **Current**: Wraps sections in HibikiCard with dividers
- **Target**: Update to use new HibikiCard tonal style, proper section spacing
- **Impact**: All Material settings pages

#### HibikiBottomSheet (`hibiki_bottom_sheet.dart`)
- **Current**: Basic list of HibikiListItems
- **Target**: Theme provides drag handle + 28dp corners automatically via BottomSheetTheme
- **Impact**: All bottom sheets

### 4. Page-Level Changes

Most page changes are **automatic** once tokens + themes + shared components are updated. Manual adjustments needed for:

| Page | Change | Reason |
|------|--------|--------|
| home_page.dart | NavigationBar indicator | Theme handles most |
| display_settings_page.dart | Section header colors | Follows SettingsSectionHeader |
| hibiki_settings_page.dart | Section header colors | Follows SettingsSectionHeader |
| reader_quick_settings_sheet.dart | Bottom sheet styling | Theme handles |
| dictionary_dialog_page.dart | Dialog corner radius | Theme handles |

### 5. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Golden test failures | HIGH | LOW | Expected — update golden files |
| Card border removal breaks visual hierarchy | MEDIUM | MEDIUM | Test with light+dark themes |
| Third-party widgets ignore ThemeData | LOW | LOW | These components use Flutter builtins |
| Cupertino path regression | LOW | LOW | Changes only touch Material path |

## Recommended Strategy

**80% centralized change, 20% per-page adjustment.**

The majority of the visual redesign can be achieved by modifying just 4 files:
1. `hibiki_design_tokens.dart` — token values
2. `theme_notifier.dart` — ThemeData component themes
3. `hibiki_material_components.dart` — HibikiCard tonal migration
4. `settings_shared.dart` — SettingsSectionHeader color

Remaining pages need only minor tweaks (if any) since they consume tokens and themes.
