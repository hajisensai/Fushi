## BUG-1454 · 查词结果正文含假名词被 ruby 占位文本截断
- **报告**：2026-08-02（用户反馈：结果正文内二次点查 `打ち合わせ` 只打开 `打ち`）
- **真实性**：✅ 真 bug。运行中 Windows app 的 `/termEntries` 与 `/api/lookup/dictionary` 对原词均返回完整 `打ち合わせ`，排除索引、变形与排序链路。真实词条 DOM 经 `postProcessRuby` 后会在每个基字前插入 `.ruby-reserve` 占宽副本；根因在 `hibiki/assets/popup/selection.js:35` 的 TreeWalker 过滤契约只排除了 `<rt>/<rp>`，从 `打` 向后扫描实际得到 `打ちあ合わせ`，词典只能命中前缀 `打ち`。浏览器扩展两份 vendored 取词器同源同缺陷。
- **[x] ① 已修复** — 提交 `61578b4b3`。`hibiki/assets/popup/selection.js` 新增统一的 `isIgnoredLookupText` 判定，让查词、整句提取与 ruby 基字解析同时跳过 `<rt>/<rp>` 和布局专用 `.ruby-reserve`；同步 `hibiki/assets/browser_extension/vendor/selection.js`、`tools/browser-extension/vendor/selection.js`，三镜像保持逐字节一致。可见基字与假名仍按原 DOM 顺序组成 `打ち合わせ`，不改后端匹配策略。
- **[x] ② 已加自动化测试** — `test/js/popup_ruby_selection.test.mjs` 用 jsdom 复刻 `postProcessRuby` 后的真实 `打`／`ち`／`合`／`わせ` 分段 DOM。修复前两例稳定红：查询串为 `打ちあ合わせ`、从 `<rt>` 解析出的基字为隐藏 `あ`；修复后断言完整查询与整句均为 `打ち合わせ`、ruby reading 命中回落到可见 `合`。`cd test/js && npm test` 共 20 例全绿。
- **备注**：按用户要求未等待完整 Flutter 编译或设备验收；本改动为三份纯 JS 资产与行为测试，已完成对应 Node 行为测试及镜像一致性检查。
