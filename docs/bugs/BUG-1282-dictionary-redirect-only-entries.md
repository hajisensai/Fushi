## BUG-1282 · redirect-only 词典条目混入真实释义结果
- **报告**：2026-07-29（用户截图：查询 `repaired` 时，LDOCE5 与 OALD10 的跳转记录和 Oxford 的真实释义一起显示）
- **真实性**：✅ 真 bug。`hibiki/assets/popup/popup.js:2200` 的词典分组此前只处理隐藏词典，没有识别 Yomitan 结构化义项里的 redirect-only 记录；同一份 glossary 又在 `:806`、`:864`、`:4044` 分别进入制卡、旧渲染和增量渲染路径。
- **[x] ① 已修复** — `865508b29` 按数据形态而非词典名称识别 `redirect` / `redirected` tag、`Redirected from …` 文本，以及 `non-lemma + redirect` 组合。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_redirect_entry_filter_test.js` 真实执行 `popup.js`，覆盖截图中的 LDOCE5/OALD10 形态、Oxford 真实释义保留和正文含 `redirect` 的误杀边界；2026-07-29 Node 行为用例通过。
- **备注**：过滤同时覆盖展示、制卡 glossary、主分组与增量分组，避免“页面隐藏但制卡仍混入”或后续增量又重新出现。Flutter wrapper 因 `pdfium_dart` 构建 hook 下载 GitHub 资源超时而未进入用例；按用户要求未继续等待完整编译验收。
