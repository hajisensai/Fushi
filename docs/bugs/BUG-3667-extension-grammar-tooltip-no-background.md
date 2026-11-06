## BUG-3667 · extension-grammar-tooltip-no-background
- **报告**：2026-10-22（用户反馈 Atbl_kOuZK，Windows 3.0.0 浏览器扩展：「点击变形时，加个底色」。截图：点「被动形」标签，语法说明文字没有底色，直接叠在下面的词典正文上）
- **真实性**：✅ 真 bug。语法说明浮层挂在 `__fushiOverlayParent()`（`fushi/assets/popup/popup.js` `ensureGrammarTooltip`），扩展里那是 shadow root 顶层，不是 `#entries-container` 的后代；浮层的底色 / 描边 / 文字色全是 `var(--surface-container-high)` 等主题变量（`popup.css` `.grammar-tooltip`），而扩展把这些变量只落在 `#entries-container` 上（content.css 把 `html` 选择器改写成 `:where(#entries-container)`），浮层拿不到 → 透明。「选择音频源」菜单早就为同一原因做过 `applyAudioMenuTheme`，语法说明浮层漏了。
- **[x] ① 已修复** — `applyGrammarTooltipTheme`：shadow 宿主下每次 `showGrammarTooltip` 前从弹窗容器抄 `--text-color` / `--surface-container-high` / `--outline-variant` / `--on-surface-variant`、字体与 `data-theme`；app 内 / app 外整窗 WebView（浮层挂 body 下、本来就继承）不动。三份 popup.js 镜像同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-shadow-host-columns-and-tooltip.test.js`：shadow 宿主下浮层拿到容器的变量与明暗、非 shadow 宿主不动、`showGrammarTooltip` 接线；`grammar-tooltip-single-surface.test.js` 沙箱补 `__fushiContainer` 替身。变异实测：删掉接线 → 红。
- **备注**：真机未复测。M3E 专属的浮层外观（`html.fushi-m3e .grammar-tooltip`）在扩展的 shadow 里本来就匹配不到，这里只保证有底色 / 描边 / 文字色，外观与扩展里其它浮层一致。
