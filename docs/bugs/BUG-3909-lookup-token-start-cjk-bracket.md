## BUG-3909 · 点〖tempering〗的 t，高亮却从〖开始
- **报告**：2026-10-31（用户：反馈 pm3A75D5xZ，Windows，截图为大辞泉『テンパリング〖tempering〗』）
- **真实性**：✅ 真 bug。点非日文字符时的词首回退 `isTokenStartBoundary`（`fushi/assets/popup/selection.js` 原 :63、`fushi/lib/src/reader/reader_selection_scripts.dart` 原 :1927）只认 `scanDelimiters` 清单；〖〗（U+3016/3017）不在表内，回退吃进『〖』（同节点时一路退进前面的片假名），引擎跳过前导标点匹配出 tempering，高亮从 startOffset 数 9 字 → 『〖temperin』。
- **[x] ① 已修复** — dc92af870d：回退终点追加「日文字符（含 CJK 标点）」与 Unicode `Ps/Pe/Pi/Pf`（开/闭括号、引号）；前向扫描不变。popup/扩展三镜像与阅读器注入脚本同步。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/token_start_cjk_bracket_fb_pm3a_test.dart` + `.js`（node 真执行两份取词引擎；旧代码红）。
