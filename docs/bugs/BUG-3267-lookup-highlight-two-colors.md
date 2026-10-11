## BUG-3267 · 查词窗源文本条与结果卡命中高亮两种颜色
- **报告**：2026-10-10（PR #2055 审查遗留疑点；用户拍板「要一致」）
- **真实性**：✅ 真问题。#2055 让 app 外查词窗的源文本条在 M3E 下走 `primaryContainer`（`fushi/lib/src/pages/implementations/popup_dictionary_page.dart` `tonalHighlight: m3e`），而结果 WebView 里的命中（`::highlight(fushi-selection)` / `.fushi-dict-highlight`，`fushi/assets/popup/popup.css`）仍是宿主内联的 `--fushi-primary-highlight`（主色 35%，`popup_theme_css.dart`），同一次查词的两个可见面两种颜色；首页词典 tab 的源文本条则仍是 35%。
- **[x] ① 已修复** — 统一到 M3E tonal 口径：`popup.css` 的 `html.fushi-m3e` 层把两种命中高亮换成 `--md-primary-container` 底 + `--md-on-primary-container` 字（宿主内联变量压不住选择器规则，非 M3E 仍走 35%）；首页词典 tab 按与 app 外查词窗同一判据（`!isGlassDesign && !isEinkTheme`）传 `tonalHighlight`。浏览器扩展 vendor 副本与 `content.css` 经 `generate-content-css.mjs` / `sync-mirrors.mjs` 重生成。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/lookup_highlight_tonal_consistency_guard_test.dart`：钉 popup.css 的 M3E 命中规则与两个宿主的 tonalHighlight 判据。
- **备注**：Apple 设计系统与墨水屏不挂 `fushi-m3e`，源文本条也不走 tonal，两侧同为 35% / 透明，仍一致。
