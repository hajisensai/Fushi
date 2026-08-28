## BUG-1903 · 一个压缩包内含多本 MDX 词典时只导入第一本，其余静默丢弃且报成功
- **报告**：2026-08-28（用户给了一个 zip：「那三本词典好像不支持」）
- **真实性**：✅ 真 bug，**而且不是「不支持」——是只进了一本**。用户那个 zip 里是三本各自独立的 MDX 词典（各占一个目录，带自己的 css / mdd / png）：岩波国語辞典 8、旺文社国語辞典［第十一版］、三省堂大辞林。
  沿真实路径实测（真引擎 `importDictionaryViaFushidicts`，用户原包）：

  | 输入 | success | title | termCount |
  |---|---|---|---|
  | 整个 zip（用户的姿势） | true | 旺文社国語辞典［第十一版］ | 219343 |
  | 单本 iwanami.mdx | true | 岩波国語辞典 | 189782 |
  | 单本 obunsha.mdx | true | obunsha | 219343 |
  | 单本 daijirin.mdx | true | 大辞林　第四版 | 1000000 |

  整包导入只出**一本**，另外两本没有任何报错、没有任何日志、`success` 照样是 true。用户看到的「不支持」，实际是「拖进去以后想要的词典没出现」。
  根因在 `fushi/lib/src/models/dictionary_import_manager.dart`：`importFromFile`（修前 `:320`）把 zip 路径**原样**丢给 native（`:358 importDictionaryViaFushidicts`），而 native 的 zip 路径只解析它找到的第一本词典。Dart 侧从来没有「这个包里有几本」这个概念——`detectFormat` 的 zip 分支（`:39-41`）只判断「含 mdx/mdd ⇒ 是 mdict 格式」，判完就完了。
  顺带排除两个看着像但不是的原因：① `Encrypted=2`（旺文社正文、岩波 mdd）只是 key-block-info 混淆，`native/fushidicts/fushidicts_src/mdx/mdx_reader.cpp:28-35` 早就用 RIPEMD-128 自解、不需要注册码（真正需要购买密钥的是 bit 0，这三本都没有）；② 日文文件名也没问题（用日文原名跑单本探针照样 success）。
- **[x] ① 已修复** — 在 `importFromFile` 入口按判据分流，拆开逐本导入，与 `importFromDirectory` 的循环同形：
  - 新增纯函数 `DictionaryImportManager.archivedDictionaryEntries(List<String>)`：只认 `.mdx` / `.dsl`。**这条判据是关键**——Yomitan 包里有几十个 `term_bank_N.json`，那仍然是**一本**词典，按文件数拆会把一本拆成几十本；而 MDX / DSL 是「一个文件一本词典」，同一个包里出现两个就是两本。
  - `_importArchivedDictionaries()`：解压到 `import_multi_temp` 并**保持原有目录层级**（MDX 的样式表/资源就躺在它自己那本的目录里，摊平会让 A 典的 css 套到 B 典头上），逐本递归调 `importFromFile`，每本只带**同目录**的 css；单本失败不中断其余（三本里坏一本，另外两本照样进库），最后复用既有的 `formatImportFailureSummary` / `dict_import_success_summary` 汇总提示；临时目录在 `finally` 里清掉。
  - 三个「这是在更新某一本」的入口（`forceReplaceExisting` / `sourceOverride` / `replaceTarget`）**不分流**：它们的语义是「用这个包替换那一本」，拆包会把一次更新做成多次追加。单本包（`length <= 1`）也走原路径，行为逐字节不变。
  - 不需要新 i18n key（复用既有汇总文案）。
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_multi_archive_import_test.dart`（与 [BUG-1904](BUG-1904-dict-import-entry-cap-silent-truncation.md) 合用一个文件，两条根因同源于这次实测）。判据层 6 条纯函数用例（两本 MDX / 用户那一包正好三本 / **Yomitan 多 bank 只算一本** / 单本不触发 / DSL 同理 / mdd·ddb·png 是资源不算典），接线层 4 条源码守卫（分流挂在入口、三个更新入口不拆、每本只带同目录 css 且失败不中断、临时目录 finally 清理）。
  变异实测：把分流条件改成 `archived.length > 999` → 精确红「importFromFile 里按判据分流」1 条；还原后 sha256 与变异前一致（`50b6f9081625d9ed…`）。
- **备注**：真机验证未做（用户已取消该环节）——未在 app UI 里真的拖一次三本包复核 toast 文案与词典列表。拆包路径本身的行为由上述测试与既有 `importFromDirectory` 循环（同一条 `importFromFile`）覆盖。
