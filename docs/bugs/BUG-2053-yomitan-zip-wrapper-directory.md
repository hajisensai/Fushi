## BUG-2053 · 带顶层文件夹的 Yomitan zip 导入失败
- **报告**：2026-09-02（用户截图：红色 toast「匯入失敗: [JA Freq] JPDB_v2.2_Frequency_Kana_2024-10-13」）
- **真实性**：✅ 真 bug — 解压一本 Yomitan 词典再把文件夹整个压回去，zip 里每个条目就变成 `MyDict/index.json`、`MyDict/term_bank_1.json`。而 native 侧一律拿**原始条目名**匹配：
  - `zip/zip.cpp` 的 `Zip::find()` 是精确字符串比较 → `zip.find("index.json")` 落空 → `importer.cpp` 的格式分派认不出 yomitan，最终 `unsupported dictionary format`；
  - 即使绕过上一步，`importer.cpp` 的 `get_files()` 用 `name.starts_with("term_bank_")` 等前缀判据，带目录前缀时**全部 bank 落进 `media_files`** → `offsets` 为空 → `throw "empty dictionary"`。

  Dart 侧判据却是宽的：`dictionary_import_manager.dart:50` 认 `f == 'index.json' || f.endsWith('/index.json')`，所以 UI 把这种包判成 yomitan、正常发起导入，native 再拒绝 —— 用户只看到一条不带原因的「匯入失敗」。

  toast 里那个名字是**文件名去掉扩展名**（`dictionary_dialog_page.dart:558` 的 `basenameWithoutExtension`），不是 index.json 的 title；这也是同批导入时「报错名字对不上我以为的那本」的原因。

- **[x] ① 已修复** — 在 Zip 层引入「逻辑名」：`Zip::open()` 算出 `root_prefix`（整包共享的顶层目录，可多层嵌套，见 `compute_root_prefix()`），`Zip::logical_name(i)` 返回剥掉该前缀的词典相对名。`find()` 改按逻辑名匹配，`get_files()` 改用 `logical_name(i)` 分类，`read_media()` 也返回逻辑名（否则媒体键会变成 `MyDict/img/a.png`，`<img src="img/a.png">` 取不到）。一处剥离，`find` / bank 分类 / media 键三处特殊情况一起消失。

  保守边界：只有**整包**都在同一顶层目录下才剥。根级出现任何文件（`index.json` + `img/a.png` 这种合法布局）或条目分散在两个顶层目录，一律不剥，宁可原样认不出，也不猜哪半边是词典。

- **[x] ② 已加自动化测试** — `native/fushidicts/tests/zip_wrapper_directory_test.cpp`（ctest 用例 `zip_wrapper_directory_test`，已登记进 `native/fushidicts/tests/CMakeLists.txt`）。四段断言：① 裹了目录的 term 词典能导入，`styles.css` 仍被认成样式表而非 media，且 media 键是 `img/sun.png` 而非 `WrappedTerms/img/sun.png`；② 裹了目录的**纯频率包**（用户报的形状，目录名就用 `[JA Freq] JPDB/`）导入成功且 `detected_type == "frequency"`；③ 根级布局与 `img/` 子目录不受影响；④ 两个顶层目录的包必须仍然导入失败。

  变异实测（非空转）：把 `get_files()` 改回 `zip.entries[i].name` 后，该用例报 `FAIL wrapped term import: empty dictionary` / `FAIL wrapped freq import: empty dictionary` —— **与用户实际遇到的失败同形**；其余 23 个 native 用例不受影响；还原后 24/24 绿。

- **备注**：未做但值得单独排期的两点 —— ① 失败 toast 只带名字不带原因，native 的 `result.error` 只进 `error_log.txt`，用户和排查者都得翻日志；② 失败时显示文件名、成功时显示 index.json title，两条路径取的维度不同。另：`__MACOSX/` 之类的打包垃圾目录会让包变成「两个顶层目录」从而不被剥离，本次刻意不加白名单（不猜），真出现再单独处理。
