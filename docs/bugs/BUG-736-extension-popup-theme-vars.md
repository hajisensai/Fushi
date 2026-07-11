## BUG-736 · 浏览器扩展查词弹窗主题与 app 不一致(漏发4个CSS变量)
- **报告**：2026-07-11（用户：查词弹窗在浏览器里和 app 内不一样）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/models/app_model.dart:2288`（`browserExtensionThemeColors()` 返回的 theme map）。
- **[x] ① 已修复** — `app_model.dart` `browserExtensionThemeColors()` 补发 4 个变量（提交见备注）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/browser_extension_theme_var_parity_guard_test.dart`（源码扫描：断言 in-app 注入的每个变量都在服务器 map 中 + 4 个变量显式钉死）。
- **备注**：

  **现象**：浏览器扩展（Netflix/YouTube/任意网页划词）里的查词弹窗和 app 内的观感不一样，最明显是**查到的词高亮成灰色**，而 app 内是主题主色。

  **根因**：扩展弹窗和 app 内用**同一份 popup.js/css**，但主题注入是两套：
  - app 内：Flutter 直接往弹窗 `documentElement` `setProperty` 全套 CSS 变量（`popup_settings_injection.dart` / `dictionary_popup_webview.dart`）。
  - 扩展：靠查词响应的 `theme` 字段下发（`AppModel.browserExtensionThemeColors()`），`content.js` 只把该 map 里**有的** key `setProperty` 到 `#entries-container`。

  服务器 map 只发了 13 个变量，**漏了 in-app 注入器里的 4 个**，扩展只能吃 popup.css 硬编码兜底：
  | 变量 | 漏发后兜底 | 影响 |
  |---|---|---|
  | `--hoshi-primary-highlight` | 灰 `rgba(160,160,160,0.4)` | 查到词高亮变灰（最扎眼） |
  | `--md-on-primary` | 白 `#fff` | 主色上文字色 |
  | `--hibiki-radius-card` | `10px` | 卡片圆角 |
  | `--hibiki-card-bg-rgb` | 纯白 `255,255,255` | 卡片底色 alpha |

  用实际运行的服务器（`127.0.0.1:19633`，app build `86ca7bd`）curl `/api/lookup/dictionary`，回的 `theme` 确实只有 13 键、缺这 4 个 → 证据确凿。`extensionBuild` 与装机扩展 build 一致，排除「扩展过期」。

  **修复**：在 `browserExtensionThemeColors()` 里补发这 4 个变量，表达式与两个 in-app 注入器逐字节同源（`--hoshi-primary-highlight`=primary@0.35、`--md-on-primary`=onPrimary、`--hibiki-radius-card`=`HibikiRadii.cardValue`、`--hibiki-card-bg-rgb`=bg 三元组）。改主题即实时生效，无需重装扩展。

  **待真机**：需在真实浏览器扩展里划词复测高亮/圆角/文字色与 app 一致（自动化测试只能守住「变量已下发」，渲染观感需人工确认）。
