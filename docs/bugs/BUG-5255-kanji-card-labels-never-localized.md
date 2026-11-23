## BUG-5255 · kanji-card-labels-never-localized
- **报告**：2026-11-23（实现拍板台 6uasoIUvSR 时顺带发现，agent）
- **真实性**：✅ 真 bug。查词弹窗汉字卡的行标签读 `window._kanjiLabels`（`fushi/assets/popup/popup.js` `createKanjiCard`：radical / strokes / onyomi / kunyomi 四处），但全仓没有任何宿主注入这个全局（`git grep _kanjiLabels` 只命中 popup.js 与它的 vendor 镜像），所以所有语言下都只显示英文回退「Radical / Strokes / On / Kun」。
- **[ ] ① 未修复** — 根因修法：在唯一注入点 `popup_settings_injection.dart` 的 head 段注入 `window._kanjiLabels`（经 i18n_sync 新增四个 key，`localeTag` 已在 memo 命中判据里，切语言会重建）；扩展 theme 通道视需要另接。
- **[ ] ② 未加自动化测试** — 计划：源码守卫断言注入点写了 `window._kanjiLabels`，再加 node 行为测试，确认注入的标签会出现在汉字卡里。
- **备注**：拍板台 6uasoIUvSR 的 PR #4190 没有修这个问题（不在拍板范围内），只登记在这里。
