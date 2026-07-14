## BUG-818 · 查词浮窗卡片背景半透明透出壁纸浅色下看不清
- **报告**：2026-07-15（用户：）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart:330`
- **[x] ① 已修复** — 见 `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart:330`
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_surface_opaque_guard_test.dart`（源码扫描守卫）
- **备注**：

### 根因
独立查词浮窗（`hibiki/lib/popup_main.dart` 宿主 `PopupDictionaryPage`）跑在**完全透明的浮动窗**里（`popup_main.dart` 各分支 `Scaffold backgroundColor: Colors.transparent`，为圆角+阴影）。浮窗内唯一的背景是 `_buildCard` 里的 `HibikiPopupSurface`，其色 `= appModel.overrideDictionaryColor ?? tokens.surfaces.page`。

- `tokens.surfaces.page = scheme.surface`（`hibiki/lib/src/utils/components/hibiki_design_tokens.dart:148`），默认不透明。
- 但 `overrideDictionaryColor` 由阅读器主题背景灌入：`_syncDictionaryTheme` → `setOverrideDictionaryColor(bg)`，`bg = _themeBackgroundColor() = _readerThemeColors.bg`（`reader_hibiki/chrome.part.dart:1930/1887`）。某些预设/自定义阅读器主题的背景色**带 alpha**（同文件 1746 行的 frosted 逻辑也印证 bg 可被赋透明度语义）。

app 内查词时浮窗背后是不透明阅读页，半透明卡片看着正常；到了独立浮窗（窗口透明），半透明卡片直接透出**桌面壁纸**，浅色壁纸下文字/边界发虚看不清。属**上下文不匹配**：同一颜色在实心页面 vs 透明浮窗上行为不同。

### 修复
`popup_dictionary_page.dart:330` 浮窗卡片色强制补满 alpha：
```dart
color: (appModel.overrideDictionaryColor ?? tokens.surfaces.page).withValues(alpha: 1.0),
```
浮窗卡片是透明窗上唯一背景层，理应恒不透明——消除“卡片可能半透明”这一特殊情况。主题色本就不透明时该调用是 no-op，零破坏（app 内不受影响）。

### 测试
`hibiki/test/pages/popup_surface_opaque_guard_test.dart`：源码扫描守卫，断言浮窗卡片 `HibikiPopupSurface(color: ...)` 那行对 `overrideDictionaryColor ?? tokens.surfaces.page` 施加了 `.withValues(alpha: 1.0)`，防止未来重构重新引入透明浮窗透壁纸。
