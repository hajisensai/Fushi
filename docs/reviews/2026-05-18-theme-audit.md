# Theme System Audit — 2026-05-18

## Scope

Full audit of theme/color system: definitions, CSS reader colors, Flutter-side reader colors, audiobook colors, floating dictionary, custom theme builder.

Files examined:
- `hibiki/lib/src/models/app_model.dart` — theme presets, custom theme props, ThemeData builders
- `hibiki/lib/src/reader/reader_content_styles.dart` — WebView CSS theme colors
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart` — Flutter-side reader colors
- `hibiki/lib/src/pages/implementations/custom_theme_page.dart` — custom theme editor
- `hibiki/lib/src/pages/implementations/hoshi_settings_page.dart` — theme selector UI
- `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart` — audiobook highlight colors
- `hibiki/lib/src/media/audiobook/audiobook_bridge.dart` — audiobook CSS injection
- `hibiki/lib/src/utils/misc/jidoujisho_color.dart` — color utilities
- `hibiki/lib/floating_dict_main.dart` — floating dictionary entry point
- `hibiki/lib/main.dart` — MaterialApp theme application

---

## 1. Theme Presets (6 + 1 Custom)

Defined in `app_model.dart:1622-1629`:

| Key | Seed Color | Hex | Brightness | 描述 |
|-----|-----------|-----|-----------|------|
| `light-theme` | Deep Teal | `#1F4959` | Light | 默认浅色 |
| `ecru-theme` | Warm Brown | `#8B7355` | Light | 暖色/米色 |
| `water-theme` | Blue-Gray | `#4A7C8F` | Light | 冷色/水色 |
| `gray-theme` | Dark Gray | `#5C6B73` | Dark | 中性深色 |
| `dark-theme` | Deep Teal | `#1F4959` | Dark | 默认深色 |
| `black-theme` | Almost Black | `#263238` | Dark | 纯黑高对比 |
| `custom-theme` | User-defined | — | User-defined | 11 个可定制颜色槽 |

### Custom Theme 可定制属性 (app_model.dart:1678-1783)

| 属性 | Pref Key | 默认值 | 用途 |
|------|---------|--------|------|
| seed | `custom_theme_seed` | `0xFF1F4959` | Material 3 seed |
| dark | `custom_theme_dark` | `false` | 明暗切换 |
| fontColor | `custom_theme_font_color` | null | 阅读器文字 |
| backgroundColor | `custom_theme_bg_color` | null | 阅读器背景 |
| selectionColor | `custom_theme_selection_color` | null | 文字选择高亮 |
| primaryColor | `custom_theme_primary_color` | null | Material primary |
| secondaryColor | `custom_theme_secondary_color` | null | Material secondary |
| tertiaryColor | `custom_theme_tertiary_color` | null | Material tertiary |
| containerColor | `custom_theme_container_color` | null | Primary container |
| sasayakiColor | `custom_theme_sasayaki_color` | null | 有声书同步高亮 |
| linkColor | `custom_theme_link_color` | null | 超链接颜色 |

---

## 2. Reader CSS Colors (WebView 侧)

Defined in `reader_content_styles.dart:378-429` (`_themeColors` method):

| Theme | Text | Background | Selection | Sasayaki | Link |
|-------|------|------------|-----------|----------|------|
| **light** (default) | `rgba(0,0,0,0.87)` | `#fff` | `rgba(160,160,160,0.40)` | `rgba(135,206,235,0.40)` | `#426cf5` |
| **ecru** | `rgba(0,0,0,0.87)` | `#f7f6eb` | `rgba(194,178,128,0.35)` | `rgba(168,198,140,0.40)` | `#7a6232` |
| **water** | `rgba(0,0,0,0.87)` | `#dfecf4` | `rgba(130,170,210,0.35)` | `rgba(100,180,220,0.40)` | `#3a5fad` |
| **gray** | `rgba(255,255,255,0.87)` | `#23272a` | `rgba(100,140,180,0.35)` | `rgba(80,150,200,0.35)` | `#6fa8dc` |
| **dark** | `rgba(255,255,255,0.6)` | `#121212` | `rgba(110,120,150,0.35)` | `rgba(70,130,180,0.35)` | `#7aacdf` |
| **black** | `rgba(255,255,255,0.87)` | `#000` | `rgba(90,100,130,0.40)` | `rgba(60,120,170,0.40)` | `#5b9bd5` |
| **custom** | user/fallback | user/fallback | **default** | **default** | **default** |

CSS 用法位置:
- `html, body { background; color }` — 分页/连续布局 (lines 281-282, 330-331)
- `::highlight(hoshi-selection)` — 文字选择 (line 216)
- `::highlight(hoshi-sasayaki)` — 有声书同步 (lines 238-241)
- `a { color }` — 超链接 (line 253)
- `:root` CSS 变量 — `--hoshi-sasayaki-text-color`, `--hoshi-sasayaki-background-color` (lines 171-173)

---

## 3. Flutter-side Reader Colors (硬编码)

Defined in `reader_hoshi_page.dart:3056-3141`:

### `_themeBackgroundColor()` (lines 3097-3114)

| Theme | Flutter Color | 与 CSS 一致性 |
|-------|-------------|--------------|
| ecru | `0xFFF7F6EB` | `#f7f6eb` ✅ |
| water | `0xFFDFECF4` | `#dfecf4` ✅ |
| gray | `0xFF23272A` | `#23272a` ✅ |
| dark | `0xFF121212` | `#121212` ✅ |
| black | `0xFF000000` | `#000` ✅ |
| light/default | `0xFFFFFFFF` | `#fff` ✅ |
| custom | `customThemeBackgroundColor ?? 0xFFFFFFFF` | ✅ |

使用位置:
- Scaffold/Container 背景色 (reader_hoshi_page.dart 多处)
- 歌词模式背景 (line 1579)
- 悬浮歌词样式 (line 2475)
- 字典主题同步 (line 3172)

### `_themeTextColor()` (lines 3117-3133)

| Theme | Flutter Color | 与 CSS 一致性 |
|-------|-------------|--------------|
| gray/black | `0xDEFFFFFF` (87%) | `rgba(255,255,255,0.87)` ✅ |
| dark | `0x99FFFFFF` (60%) | `rgba(255,255,255,0.6)` ✅ |
| light/ecru/water | `0xDE000000` (87%) | `rgba(0,0,0,0.87)` ✅ |
| custom (dark) | `0xDEFFFFFF` | ✅ |
| custom (light) | `0xDE000000` | ✅ |

### `_infoTextColor()` (lines 3056-3068) — 进度条专用

| Theme | Color | 说明 |
|-------|-------|------|
| gray/dark/black | `0x99FFFFFF` | 白色 60% |
| ecru | `0x7A5C5448` | 暖棕色 48% (匹配主题色调) |
| default | `0x8A000000` | 黑色 54% |

---

## 4. Audiobook Highlight Colors

### Play Bar Highlights (`audiobook_play_bar.dart:1911-1923`)

| Preset | Color | Hex |
|--------|-------|-----|
| green | `0xFF00C853` | 绿色 |
| blue | `0xFF448AFF` | 蓝色 |
| pink | `0xFFFF4081` | 粉红 |
| purple | `0xFFAA00FF` | 紫色 |
| yellow (default) | `0xFFFFDC00` | 黄色 |

这些是有声书播放条的独立 highlight preset，与主题系统无关。

### Audiobook Bridge (`audiobook_bridge.dart:230`)
- 默认 `primaryColor = Color(0xFFFFDC00)` (黄色)
- 被 `reader_hoshi_page.dart:1850-1852` 调用时传入 `customThemeSasayakiColor ?? Color(0x6687CEEB)`

### Lyrics Mode Accent (`reader_hoshi_page.dart:1581-1583`)
- Dark mode: `0xFFFFDC00` (黄色硬编码)
- Light mode: `Theme.of(context).colorScheme.primary`

---

## 5. Floating Dictionary Theme

`floating_dict_main.dart:79-86`:
- 优先用 `appModel.overrideDictionaryTheme`
- Fallback: `ThemeData(colorSchemeSeed: Color(0xFF1F4959), brightness: ...)`
- Fallback 不经过 `buildHibikiColorScheme`，无 custom role colors

---

## 6. Magic Constants (散落的硬编码颜色)

| 常量 | 出现次数 | 位置 |
|------|---------|------|
| `0x6687CEEB` (sky blue 40%) | **6** | custom_theme_page.dart ×5, reader_hoshi_page.dart ×1 |
| `0xFFFFDC00` (yellow) | **3** | audiobook_bridge.dart, audiobook_play_bar.dart, reader_hoshi_page.dart |
| `0x33FFFFFF` / `0x1A000000` | **1** | reader_hoshi_page.dart (floating lyric button) |

---

## Findings

### HBK-AUDIT-001 — 自定义颜色泄漏到预设主题 [Bug]

**Severity**: High | **Status**: Fixed

**File**: `reader_hoshi_page.dart:993-1004`

**根因**: `_buildStyleTag()` 和 `_applyStylesLive()` 无条件传入 `customThemeSelectionColor`、`customThemeSasayakiColor`、`customThemeLinkColor`，即使当前主题不是 `custom-theme`。`customBg` 和 `customFg` 有 `appThemeKey == 'custom-theme'` 守卫，但这三个颜色没有。

**影响**: 用户在 custom-theme 里设置了 selection/sasayaki/link 颜色后，切回预设主题，阅读器仍会使用自定义颜色覆盖预设主题的 CSS 配色。

**修复**: 添加 `_isCustomTheme` getter，给这三个参数加上守卫，与 `customBg`/`customFg` 一致。

### HBK-AUDIT-002 — Audiobook Bridge 不使用当前主题的 sasayaki 颜色 [Bug]

**Severity**: Medium | **Status**: Fixed

**File**: `reader_hoshi_page.dart:1850-1852`

**根因**: `_injectAudiobookBridge()` 使用 `customThemeSasayakiColor ?? Color(0x6687CEEB)`。对于预设主题，`customThemeSasayakiColor` 为 null，所以始终回退到 `0x6687CEEB`（light 主题的默认值），而不是当前主题的 sasayaki 颜色。

**影响**: 预设主题（ecru/water/gray/dark/black）的有声书同步高亮颜色与 CSS 侧不一致。

**修复**: 添加 `_themeSasayakiColor()` per-theme 查表方法，audiobook bridge 使用它。

### HBK-AUDIT-003 — Magic constant `0x6687CEEB` 散落 6 处 [Code Quality]

**Severity**: Low | **Status**: Fixed

**Files**: custom_theme_page.dart (×5), reader_hoshi_page.dart (×1)

**修复**: 在 `JidoujishoColor` 中定义常量 `defaultSasayakiColor`，全部替换。

### HBK-AUDIT-004 — Magic constant `0xFFFFDC00` 散落 3 处 [Code Quality]

**Severity**: Low | **Status**: Fixed

**Files**: audiobook_bridge.dart, audiobook_play_bar.dart, reader_hoshi_page.dart

**修复**: 在 `JidoujishoColor` 中定义常量 `defaultHighlightYellow`，全部替换。

### HBK-AUDIT-005 — theme/darkTheme getter 近乎重复 [Code Quality]

**Severity**: Low | **Status**: Fixed

**File**: `app_model.dart:561-718`

**根因**: `theme` 和 `darkTheme` 仅 `Brightness` 和 `scrollbarTheme.thickness` 不同，其余 ~70 行完全相同。

**修复**: 提取 `_buildThemeData(Brightness)` 私有方法，消除约 70 行重复。

### HBK-AUDIT-006 — 查词高亮与当前播放语句同色 [Bug]

**Severity**: Medium | **Status**: Fixed

**File**: `reader_content_styles.dart:389-420`

**根因**: water/gray/dark/black 四个主题的 `selectionColor`（查词/选中高亮）和 `sasayakiColor`（当前播放语句）都落在蓝色系，肉眼难以区分。

**影响**: 用户在有声书模式下查词时，无法分辨哪部分是"正在播放的句子"、哪部分是"查词选中的文字"。

**修复**: 把 water/gray/dark/black 主题的 `selectionColor` 改为暖色调琥珀色，与蓝色系 sasayaki 形成冷暖对比。

| 主题 | 旧 selectionColor | 新 selectionColor | sasayakiColor |
|------|------------------|------------------|---------------|
| water | `rgba(130,170,210,.35)` 蓝 | `rgba(200,170,110,.35)` 琥珀 | `rgba(100,180,220,.40)` 蓝 |
| gray | `rgba(100,140,180,.35)` 钢蓝 | `rgba(190,155,100,.35)` 琥珀 | `rgba(80,150,200,.35)` 蓝 |
| dark | `rgba(110,120,150,.35)` 灰蓝 | `rgba(180,145,90,.35)` 琥珀 | `rgba(70,130,180,.35)` 钢蓝 |
| black | `rgba(90,100,130,.40)` 暗蓝 | `rgba(170,135,80,.40)` 琥珀 | `rgba(60,120,170,.40)` 蓝 |

### HBK-AUDIT-007 — TOC 选中章节字体色与 accent 相同 [Code Quality]

**Severity**: Low | **Status**: Fixed

**File**: `audiobook_play_bar.dart:891-900`

**修复**: 改为 Material 3 标准 `ListTile(selected: true)` + `primaryContainer` 底色 + `onPrimaryContainer` 文字色。

### HBK-AUDIT-008 — 收藏句子高亮完全不显示 [Bug]

**Severity**: Critical | **Status**: Fixed

**Files**: `highlight_bridge.dart`, `reader_hoshi_page.dart`

**根因 (三重)**:
1. `_buildOffsetMap` JS 函数使用 `charCodeAt` 迭代文本，而保存侧 (`getNormalizedOffset`) 使用 `codePointAt`。非 BMP 字符（如 emoji、部分 CJK 扩展）导致偏移量错位，Range 创建失败。
2. `_buildGroups` 中 `rawIdx + 1` 硬编码单 code unit 宽度，非 BMP 字符的第二个 surrogate 被截断。
3. `FavoriteSentenceRepository.applyHighlights` 原本用 `.where()` 静默丢弃 `normCharOffset == null` 的收藏，无日志无回退。

**影响**: 所有收藏句子高亮不可见——有偏移量的因 Unicode 错位而 Range 创建失败，无偏移量的被静默过滤。

**修复**:
- `_buildOffsetMap`: 改用 `codePointAt` + `charLen` 迭代，map 条目增加 `rawLen` 字段
- `_buildGroups`: 使用 `rawLen` 替代硬编码 `+1`
- `__hibikiGetSelectionNormRange`: 同样的 `codePointAt` 修复
- 新增 `__hibikiFindTextNormRange` JS 函数：文本搜索回退，用于无偏移量的旧收藏
- Dart 侧 `applyHighlights`: 对无偏移量的收藏调用文本搜索回退，添加 debugPrint 诊断

### HBK-AUDIT-009 — 歌词模式不显示收藏标记 [Bug]

**Severity**: Medium | **Status**: Fixed

**Files**: `lyrics_mode_html.dart`, `reader_hoshi_page.dart`

**根因**: 歌词模式使用独立 HTML 页面，不加载 `HighlightBridge` JS，因此 `_applyChapterHighlights()` 对歌词页面无效。歌词页面没有任何收藏标记机制。

**影响**: 歌词模式下收藏的句子没有视觉反馈。

**修复**:
- `lyrics_mode_html.dart`: 添加 `.cue.favorited::before` CSS（★星标）+ `__lyricsMarkFavorites(texts)` JS 函数
- `reader_hoshi_page.dart`: 新增 `_applyLyricsFavorites()` 方法，在歌词页面加载完成和收藏切换时调用

## Next Scope

- 验证修复后预设主题切换不再泄漏自定义颜色
- 检查 `_syncDictionaryTheme()` 是否正确使用主题颜色
- Audiobook highlight preset 是否需要与主题联动（当前设计为独立，暂不视为 bug）
- 在真机上验证：收藏句子 → 切章节 → 切回 → 高亮是否恢复
- 验证歌词模式收藏星标是否正确出现/消失
