## BUG-2053 · 带顶层文件夹的 Yomitan zip 导入失败
- **报告**：2026-09-02（用户截图：红色 toast「匯入失敗: [JA Freq] JPDB_v2.2_Frequency_Kana_2024-10-13」）
- **真实性**：✅ 真 bug — 解压一本 Yomitan 词典再把文件夹整个压回去，zip 里每个条目就变成 `MyDict/index.json`、`MyDict/term_bank_1.json`。而 native 侧一律拿**原始条目名**匹配：
  - `zip/zip.cpp` 的 `Zip::find()` 是精确字符串比较 → `zip.find("index.json")` 落空 → `importer.cpp` 的格式分派认不出 yomitan，最终 `unsupported dictionary format`；
  - 即使绕过上一步，`importer.cpp` 的 `get_files()` 用 `name.starts_with("term_bank_")` 等前缀判据，带目录前缀时**全部 bank 落进 `media_files`** → `offsets` 为空 → `throw "empty dictionary"`。

  Dart 侧判据却是宽的：`dictionary_import_manager.dart:50` 认 `f == 'index.json' || f.endsWith('/index.json')`，所以 UI 把这种包判成 yomitan、正常发起导入，native 再拒绝 —— 用户只看到一条不带原因的「匯入失敗」。

  toast 里那个名字是**文件名去掉扩展名**（`dictionary_dialog_page.dart:558` 的 `basenameWithoutExtension`），不是 index.json 的 title；这也是同批导入时「报错名字对不上我以为的那本」的原因。

- **[x] ① 已修复** — 在 Zip 层引入「逻辑名」：`Zip::open()` 算出 `root_prefix`（整包共享的顶层目录，可多层嵌套，见 `compute_root_prefix()`），`Zip::logical_name(i)` 返回剥掉该前缀的词典相对名。`find()` 改按逻辑名匹配，`get_files()` 改用 `logical_name(i)` 分类，`read_media()` 也返回逻辑名（否则媒体键会变成 `MyDict/img/a.png`，`<img src="img/a.png">` 取不到）。一处剥离，`find` / bank 分类 / media 键三处特殊情况一起消失。

  保守边界：只有**整包**都在同一顶层目录下才剥。根级出现任何文件（`index.json` + `img/a.png` 这种合法布局）或条目分散在两个顶层目录，一律不剥，宁可原样认不出，也不猜哪半边是词典。

  **打包垃圾（补）**：macOS Finder 的「压缩」会在文件夹旁边吐一棵 AppleDouble 资源叉树 `__MACOSX/MyDict/._index.json`，并顺手留一个 `.DS_Store`。前者是第二个顶层目录 → 触发 fan-out，后者是根级**文件** → 直接终止剥离；两种都让「解压再压回去」这条最常见的复现路径继续报 `unsupported dictionary format`，而 Fushi 本身出 macOS 包。`zip.hpp` 的 `is_packaging_noise()` 按**确定的固定名**跳过这两者（`__MACOSX/` 前缀 + basename 恰为 `.DS_Store`），`compute_root_prefix()` 算前缀时不让它们投票，`get_files()` 也不把它们收成 media（资源叉不是词典媒体）。**只有这两个 Apple 自己拥有的名字，不是通用「忽略垃圾文件」白名单** —— 通用白名单要猜，这两个不用猜。

- **[x] ② 已加自动化测试** — `native/fushidicts/tests/zip_wrapper_directory_test.cpp`（ctest 用例 `zip_wrapper_directory_test`，已登记进 `native/fushidicts/tests/CMakeLists.txt`）。八段断言：① 裹了目录的 term 词典能导入，`styles.css` 仍被认成样式表而非 media，且 media 键是 `img/sun.png` 而非 `WrappedTerms/img/sun.png`；② 裹了目录的**纯频率包**（用户报的形状，目录名就用 `[JA Freq] JPDB/`）导入成功且 `detected_type == "frequency"`；③ 根级布局与 `img/` 子目录不受影响；④ 条目真正分散在两个顶层目录的包必须仍然导入失败；⑤ macOS Finder 包（`__MACOSX/` 资源叉 + 词典）导入成功、media 键仍是 `img/sun.png`、且 `media_count == 1`（资源叉不进 media）；⑥ `.DS_Store`（根级 + 词典内各一个）不影响导入且 `media_count == 0`；⑦ 两层嵌套 `NestedTwice/NestedTwice-v2/…` 与单层同构；⑧ 显式目录标记条目（`DirMarkers/`、`DirMarkers/img/`）外加旁边一个游离空目录 `scratch/` 不影响剥离。

  ④ 的形状是**特意重做过的**：原来写成 `a/index.json` + `b/term_bank_1.json`，把 `fan_out = true` 改成 `false` 时它照样绿 —— 错剥出的前缀 `a/` 把 bank 留在了外面，导入因为**无关原因**（找不到 bank）失败，断言根本没看见差别（M4 存活）。改成「词典在 `a/` 下完整、`b/readme.txt` 另在一边」之后，错剥会真的导入出一本词典并把 `b/readme.txt` 吞成 media，`r.success` 才会翻。⑧ 里的 `scratch/` 同理：没有它，目录标记的跳过条件删掉也不红。

  变异实测（逐条改坏 → 实测红 → 按唯一锚点还原 → sha256 比对，全套 24 例）：

  | 变异 | 位置 | 结果 | 报错文案 |
  |---|---|---|---|
  | M4 `fan_out = true` → `false` | `zip.cpp:127` | 🔴 红 | `entries fanning out into two top-level directories were wrongly peeled: "a/" was stripped into a dictionary and "b/" swallowed as media` |
  | M5 `__MACOSX/` 判据 `return true` → `false` | `zip.cpp:78` | 🔴 红 | `FAIL __MACOSX import: unsupported dictionary format` |
  | M6 `.DS_Store` 判据改名失配 | `zip.cpp:82` | 🔴 红 | `FAIL .DS_Store import: unsupported dictionary format` |
  | M7 `get_files()` 去掉 `is_packaging_noise` | `importer.cpp:76` | 🔴 红 | `FAIL __MACOSX media_count: got 4 want 1` / `FAIL .DS_Store media_count: got 2 want 0` |
  | M8 `prefix += candidate` 后直接 return（只剥一层） | `zip.cpp:135` | 🔴 红 | `FAIL nested import: unsupported dictionary format` |
  | M9 去掉目录标记跳过 | `zip.cpp:110` | 🔴 红 | `FAIL dir-marker import: unsupported dictionary format` |

  另一条早先的变异：把 `get_files()` 改回 `zip.entries[i].name` 后报 `FAIL wrapped term import: empty dictionary` / `FAIL wrapped freq import: empty dictionary` —— **与用户实际遇到的失败同形**。每轮都只有 `zip_wrapper_directory_test` 一个用例变红，其余 23 个不受影响；还原后 24/24 绿。

- **备注**：未做但值得单独排期的两点 —— ① 失败 toast 只带名字不带原因，native 的 `result.error` 只进 `error_log.txt`，用户和排查者都得翻日志；② 失败时显示文件名、成功时显示 index.json title，两条路径取的维度不同。另：`__MACOSX/` 与 `.DS_Store` 这两种 macOS 打包垃圾**已在本条内处理**（见上文「打包垃圾（补）」）—— 起初写成「刻意不加白名单（不猜）」，但这两个是 Apple 固定拥有的唯一名字，根本不需要猜，而 Finder「压缩」正是 macOS 用户复现本 bug 的默认路径，不处理等于这条修复在相当一部分真实路径上够不着。其它形态（Windows `Thumbs.db`、各类编辑器临时文件等）仍不处理，那才是要猜的地方。
