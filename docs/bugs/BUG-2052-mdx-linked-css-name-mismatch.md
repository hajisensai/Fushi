## BUG-2052 · MDX 附属 CSS 与 mdx 不同名时样式完全不生效
- **报告**：2026-09-02（用户：对比欧路词典，同一本 NLT 词频词典在我们这里表格无边框、无绿色表头，且多出「頻度‱」「順位」两列）
- **真实性**：✅ 真 bug — `native/fushidicts/fushidicts_src/importer.cpp` 的 `read_sibling_css()` 只把 `.mdx` 的扩展名换成 `.css` 去找同 stem 的兄弟文件。用户这本词典是 `NLT（話し言葉）.mdx` + `NLT.css`，stem 不同 → 找不到 → 词典目录里从没写出 `styles.css` → `query.cpp:159`（只读字面量 `styles.css`）读到空 → 弹窗无样式可注入。

  实际条目 HTML 每条都自带（用 mdict-utils 解出的真实字节）：
  ```html
  <link rel="stylesheet" type="text/css" href="NLT.css" />
  <script src="NLT.js" type="text/javascript"></script>
  <table border="0" cellpadding="5"> …6 列… </table>
  ```
  即「要哪个样式表」HTML 里写得清清楚楚，旧实现却去猜 stem。`NLT.css` 里的
  `th:nth-child(5), td:nth-child(5), th:nth-child(6), td:nth-child(6){display:none}`
  正是欧路只显示 4 列、我们显示 6 列的原因。

  另有两条同源死路（同属「附属文件按名字取不到」）：
  - `<link>` 被 `assets/popup/dict-media.js:14` 重写成 `dictmedia://NLT.css`，但 `query.cpp` 的 `get_media_file_view` 只查 media.idx（`.mdd` 内容），不回落词典目录散文件 → 404。
  - 用户即使在导入对话框手选 `NLT.css`（`dictionary_dialog_page.dart:472` 允许选 css），`dictionary_import_manager.dart:533` 也只是按原 basename 拷进词典目录，而读侧只认字面量 `styles.css` → 永远不生效。

- **[x] ① 已修复** — `read_sibling_css(primary_path, entries)` 改为**先读条目 HTML 里 `<link>` 实际指名的 css**，在 `.mdx` 自己的目录内解析（`extract_linked_css_names()` 扫前 50 条，去重、多张按首次出现顺序拼接）；找不到才回退原来的同 stem 兄弟文件。`is_plain_file_name()` 拒绝含 `/ \ :` 与 `..` 的 href，故不可能读出词典目录以外的文件。zip 内的 mdx 导入白名单同步放宽：`.css` 不再要求同 stem（`importer.cpp` 的 `import_mdx_from_zip`）。

  选择内联成 `styles.css` 而不是修 media 回落让 `<link>` 去取，是因为**只有内联这条路径会被 `constructDictCss()` 加上 `[data-dictionary="X"]` 作用域前缀**；这些表里全是 `table{}` `th{}` `td{}` 裸标签选择器，走 `<link>` 不作用域化会把共享弹窗文档里**所有**词典的表格一起染绿。

- **[x] ② 已加自动化测试** — `native/fushidicts/tests/mdx_linked_css_name_test.cpp`（ctest 用例 `mdx_linked_css_name_test`，已登记进 `native/fushidicts/tests/CMakeLists.txt`）。三段断言：① stem 与 link 指名不同，且同目录**故意放一个同 stem 的 decoy**，断言取的是 link 指名那张；② 无 `<link>` 时同 stem 回退仍工作；③ `href="../secret.css"` 不得逃出词典目录。

  变异实测（非空转）：把 `extract_linked_css_names(...)` 换成空列表后，该用例报 `FAIL: styles.css came from the stem-named decoy, not the <link>-named sheet`，其余 23 个 native 用例不受影响；还原后 24/24 绿，`importer.cpp` sha256 精确回到 `abba1fb5…`。

- **备注**：**条形图仍未复刻**。欧路的「頻度」列是条形图，由 `NLT.js` 在 `DOMContentLoaded` 里读 `td span.rank` 的值、把 `td span.freq` 包进 `.freq-container`/`.freq-bar` 生成的。我们经 `wrapper.innerHTML = …` 插入的 `<script>` 按 HTML 规范**永不执行**（`assets/popup/popup.js:3739`），所以该列只显示纯数字。要复刻需要新增「执行词典自带 JS」的能力，且必须解决两件事：弹窗是长驻 SPA，`DOMContentLoaded` 早已过去不会再触发；`NLT.js` 用 `document.querySelectorAll('tr')` 全文档扫描，会改到别的词典的表格。属于独立能力，未在本次范围内。
