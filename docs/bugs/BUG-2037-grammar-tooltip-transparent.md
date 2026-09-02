## BUG-2037 · 查词弹窗语法说明浮层背景半透明，透出下方词典正文
- **报告**：2026-09-02（用户：截图，鼠标悬停词形变化标签 `-ちゃう` 时弹出的语法说明浮层没有底色，整段英文直接压在词典卡片正文上）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.css:21`（改前）——兜底块选择器写成 `html,\nbody { ... --surface-container-high: rgba(128,128,128,0.14); ... }`。
  - 主题真值只声明在 `html[data-theme="light"|"dark"]`（`popup.css:1583/1601`）与 `html.eink[...]` 上；Dart 注入的 `--md-*` 也只落在 `documentElement` 上（`fushi/lib/src/pages/implementations/dictionary_popup_webview.dart:1137`）。
  - 自定义属性靠**继承**往下传，而 CSS 里「元素自身的声明」优先于「从父元素继承来的值」。兜底块同时命中了 `body`，于是 body 及其**全部后代**永远拿兜底值，主题块对它们完全失效。
  - `.grammar-tooltip { background: var(--surface-container-high); }`（`popup.css:733` 改前）因此恒为 14% 灰 ≈ 透明。同一遮蔽还影响暗色主题下的 `--text-color-light1..4` / `--background-color-dark1`（恒为亮色值）。
  - 浏览器扩展侧不受影响：`generate-content-css.mjs` 把 `html` 与 `body` 都重写成同一个 `:where(#entries-container)`，主题块重写成 `:where(#entries-container)[data-theme=...]`（特异性更高），本来就是主题块赢。
- **[x] ① 已修复** — 把自定义属性的兜底声明从 `html, body` 拆成只写在 `html` 上（非自定义属性仍留在 `html, body`）；重跑 `node tools/browser-extension/scripts/generate-content-css.mjs` 同步两份 `vendor/content.css`（生成结果行为等价：同一元素、同一顺序）。提交 `6f11f8c625`。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_theme_vars_not_shadowed_on_body_guard_test.dart`：按行为判据钉住「凡被 `html...` 主题块重定义过的自定义属性，都不许出现在任何命中 `body` 的规则里」，外加 `.grammar-tooltip` 背景不得为 transparent / 半透明 rgba。改兜底值、加变量、改名都不会假红；把选择器改回 `html, body` 才红。
- **备注**：同一轮还修了 BUG-2038（这段语法说明只有英文）。
