## BUG-655 · 制卡后查词弹窗制卡图标(✓↩)变乱码

- **报告**：2026-07-09（用户：TODO-1338）
- **真实性**：✅ 真 bug — 根因 `hibiki/assets/popup/popup.js:1999`（`setMineState` 把制卡按钮 `textContent` 换成符号字形 `✓`/`✓↩`）+ `hibiki/lib/src/pages/implementations/popup_settings_injection.dart:116-117`（把用户自定义词典字体以 `!important` 注入到 `html, body`）。
- **根因链**：制卡按钮走「文本字形标记」（应用户要求保留 ✓/✓↩，不走 SVG）。未制卡态 `+` 是 ASCII，任何字体都有，故制卡前不乱码；制卡成功后 `setMineState(true)` 把字形换成 `✓`(U+2713)/`✓↩`(U+2713+U+21A9)。而制卡按钮在 `<body>` 内、继承了注入的用户词典字体（`!important`）；该词典字体多为 CJK 正文字体，普遍缺 U+2713/U+21A9 或把 `↩` 走彩色 emoji 呈现 → 制卡后按钮变豆腐块/彩色 emoji/乱码。与 TODO-1337「折叠三角字形乱码」同根因（字体字形继承注入字体）。in-app 弹窗还没有 global-lookup 那套 Segoe UI Symbol 兜底（那套仅外置浮窗用，且对 `.mine-button` 是隐藏而非兜底）。
- **[x] ① 已修复** — 根因修（保留用户要的 ✓/✓↩ 文本标记，不改成 SVG）：
  - `hibiki/assets/popup/popup.css` `.mine-button` 新增独立规则，钉死一套「单色符号字体栈」`"Segoe UI Symbol","Apple Symbols","Noto Sans Symbols2","Noto Sans Symbols","DejaVu Sans","Segoe UI",sans-serif !important`（不含彩色 emoji 字体），靠更高特指度（`.mine-button` 类 > `body` 元素；且直接声明恒压过继承）切断对注入词典字体的继承，`✓/✓↩` 在五平台系统符号字体里稳定单色呈现。
  - `hibiki/assets/popup/popup.js:1999` 给 `↩` 追加 VS15(U+FE0E)（`'✓↩︎'`）强制「文本呈现」，双保险杜绝任何系统级 emoji 回退。
  - 三镜像同步：app popup.css/js re-vendor 到 `hibiki/assets/browser_extension/vendor/` + `tools/browser-extension/vendor/`，并重跑 `generate-content-css.mjs` 重生成 content.css。
  - 提交：`<pending>`
- **[x] ② 已加自动化测试** —
  - `hibiki/test/dictionary/popup_cards_nav_icon_guard_test.dart`：三镜像锁 `.mine-button` 含单色符号字体栈(含 Segoe UI Symbol)+`!important`、不含彩色 emoji 字体；popup.js 保留 ✓ 文本标记且 `↩` 后带 VS15。
  - `hibiki/test/dictionary/popup_niratan_visual_guard_test.dart`：更新为断言 `✓↩︎`（含 VS15）文本三态。
  - `hibiki/test/utils/misc/popup_asset_behavior_test.js`：行为测试（jsdom 执行 popup.js）更新为期望 `✓↩︎`。
  - 提交：`<pending>`
- **备注**：优先纯 SVG「零字体依赖」被用户显式否决（TODO-1325 还原：制卡按钮回到 ✓/✓↩ 文本标记，不走 SVG）。故本修取「字体隔离(单色符号栈)+VS15」——保留用户要的文本标记观感，同时把乱码根因（继承注入词典字体）从数据流上切断，属根因修非绕过。
