## BUG-208 · 阅读器背景在 system-theme/light-theme 下不吃主题(恒白)
- **报告**：2026-06-11（用户：TODO-143「书籍背景是不是没吃主题」）
- **真实性**：✅ 真 bug —— 根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:6173`（旧 `_themeMap` 只有 5 个 preset，缺 `light-theme`/`system-theme`）+ `:6207` 旧 `_themeBackgroundColor` 命中失败回落硬编码白 `0xFFFFFFFF`。
- **[x] ① 已修复** — `reader_hibiki_page.dart`：把四个主题色 getter（`_themeBackgroundColor`/`_themeTextColor`/`_themeSasayakiColor`/`_isReaderThemeDark`）收敛到新顶层纯函数 `resolveReaderThemeColors`。preset 命中（ecru/water/gray/dark/black）用手调底色（零变化），custom-theme 用自定义色（零变化），其余 key（`light-theme`/`system-theme`/未来新增）回落到 `appModel.buildColorScheme(brightness).surface/onSurface/brightness`，让阅读器背景真正跟随当前主题。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_theme_background_follows_theme_test.dart`：纯函数守卫断言 system-theme/light-theme/未来 key 回落到真实 scheme.surface（撤修复回硬编码白 → 3 条红），preset/custom 保持向后兼容。
- **备注**：根因是 `_themeMap` 是和 `ThemeNotifier.themePresets` 脱钩的硬编码副本，没覆盖全部主题 key，尤其漏掉**默认主题** `system-theme`，导致默认配置下阅读器背景永远白。文字色/sasayaki/明暗判断同源缺陷一并修复。视觉效果（阅读器/WebView/词典/歌词四表面同源 `_themeBackgroundColor`）需真机复测 system-theme 暗色下背景跟随。
