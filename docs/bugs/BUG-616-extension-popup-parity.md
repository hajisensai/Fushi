## BUG-616 · 浏览器扩展查词弹窗与 app 内不一致（丑/按钮位置不同）

- **报告**：2026-07-08（用户：扩展弹窗还是完全不一样，丑死了，按钮位置也不一样）
- **真实性**：✅ 真 bug（TODO-1267）。根因=**版本漂移**，不是「装了旧包」。扩展加载自己 vendor 的
  `popup.js` / 手工 scope 的 `content.css`，两者都**从未纳入 app↔扩展 一致性守卫**，随 app 内
  `hibiki/assets/popup/popup.js`（133 KB）/ `popup.css`（1188 行）演进而落后：
  - `tools/browser-extension/vendor/popup.js` + `hibiki/assets/browser_extension/vendor/popup.js`
    停在 75 KB 旧版（`manifest.json:12` 加载它），比 app 少 57 KB、少 5 个渲染 handler
    （`callHandler('favoriteCheck'|'minedCardAction'|'setSentenceContext'|'clearSentenceDraft'|'updateEntry')`）
    → 渲染的 DOM/按钮结构是旧版（收藏星、制卡动作面板、例句上下文选择器、汉字卡等新按钮缺失）。
  - 扩展真正的样式源是 `vendor/content.css`（`manifest.json:13`；`popup.css`/`popup.html` 在扩展里是
    死文件，未被 manifest 引用）。`content.css` 是 `popup.css` 的手工 scope 移植（文档级规则 re-root 到
    `#entries-container` 防污染宿主页，TODO-1090），但停在旧版，**缺 59 个新 selector**
    （`.favorite-button` / `.clear-draft-button` / `.sentence-context-picker*` / `.inline-action-button*`
    / `.kanji-card*` / `.pitch-transcription*` / `.overlay-close > svg` / `::-webkit-scrollbar*` 等）
    → 新按钮无样式 = 「丑、按钮位置不一样」。
  - 既有守卫 `hibiki/test/build/browser_extension_dict_media_mirror_guard_test.dart` 只在**两个扩展镜像
    之间**互比字节（清单里根本没有 popup.js/popup.css/popup.html/content.css），从不比对 app↔扩展 →
    漂移无人拦。
- **[x] ① 已修复** — 提交 `9b3ee8d`
  1. re-vendor `popup.js`/`popup.html`/`popup.css`（app → 两个扩展镜像，字节拷贝）→ 扩展渲染同款 DOM。
     新版调用的 5 个新 handler 经 `bridge-shim.js` 的 `default` 分支 no-op（`Promise.resolve(null)`），
     popup.js 对 null 返回全部 graceful（favoriteCheck→未收藏态、setSentenceContext→0），不崩渲染。
  2. 新增确定性生成器 `tools/browser-extension/scripts/generate-content-css.mjs` +
     `content-css-overlay.css`（扩展专属块），机械把 `popup.css` 文档级规则 re-root 到
     `#entries-container`、drop app 外部专属的 `html.global-lookup`/`html.mobile-external` 规则、class
     规则 verbatim，再拼接 overlay，重生成 `content.css`（两镜像）。遇未知文档级选择器**报错**，不可能
     静默污染宿主页。以后改 popup.css 只需重跑生成器，消除手工再移植的漂移源。
  - 未做（越界，需排序/独立 feature）：**未改 `popup.js` 本体**（TODO-1231 并发在改 app 外查词，约定不动）；
    收藏落库 / 例句上下文制卡 / 制卡动作面板**持久化**在扩展里仍 no-op（需给 `bridge-shim.js` + sync
    server 加端点，属独立功能 scope，非本视觉一致性 bug）。
- **[x] ② 已加自动化测试** — `hibiki/test/build/browser_extension_popup_parity_guard_test.dart`
  （10 tests，`flutter test` 绿）：① popup.js/html/css 在 app + 两个扩展镜像三方字节一致；② content.css
  含 popup.css 的每个 class selector（防再漏新按钮样式）；③ content.css 无未 scope 的文档级选择器（防
  泄漏宿主页）；④ 保留扩展 overlay + scoped 形式；⑤ 两 content.css 镜像字节一致。生成器另带
  `--check` 本地守卫。既有 `browser_extension_dict_media_mirror_guard_test.dart`（49）+ 扩展 node 测试
  （45）均未回归。
- **备注**：真机验收=装 `%APPDATA%/Hibiki/Hibiki/hibiki-browser-extension` 的新扩展，在任意网页取词弹出
  查词弹窗，逐项对比 app 内弹窗：收藏星 / 制卡➕ / 例句上下文「上 N 下 N」/ 汉字卡 / 声调转写 / 关闭按钮
  （SVG ×）/ 滚动条主题 / 多列布局，按钮位置与样式应与 app 内一致。与本地不入库的
  `docs/REGRESSION_BUGS.md` 区分。
