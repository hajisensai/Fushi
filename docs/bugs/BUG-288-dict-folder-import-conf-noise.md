## BUG-288 · 「导入文件夹词典」选到只含无关文件（QQ 下载的随机名 .conf）的目录报含糊错（TODO-379）
- **报告**：2026-06-15（用户：导入 `C:\Users\wrds\Downloads\QQ\879-11f1-ab07-7df86a9e5503.conf` 所在目录做「导入文件夹词典」报错）
- **真实性**：✅ 真 bug（设计缺陷）。根因 `hibiki/lib/src/models/dictionary_import_manager.dart:130`（`importFromDirectory` 的「整目录打包」分支）：
  目录导入分两支——目录里有 `.zip/.dsl/.mdx` 时逐个导入（无关文件被忽略，OK，:69-128）；
  否则（典型 yomitan 解压散文件 / migaku JSON 目录）走「把整个目录 `packDirectoryToZip` 递归
  打包成一个 zip 喂给 native」（:130-235）。**这条分支不做任何「目录里到底有没有词典」的
  预检**：哪怕目录里只有 QQ 下载的随机名 `.conf` 等无关文件、没有任何词典主文件，也照样把
  无关文件打包后丢给 native，native 找不到 `index.json` / 词条数据 → `result.success=false` →
  抛 `result.error` 或 `t.import_failed`（:165-167）的含糊「导入失败」，用户无从判断是选错目录。
  另：`detectFormat` / `detectFormatFromDirectory`（:25/:49）这对格式检测函数全仓库**无任何调用者**
  （死代码），真实导入路径从不用它们做预检。
- **[x] ① 已修复** — 在整目录打包前新增递归预检纯函数
  `DictionaryImportManager.directoryContainsImportableDictionary(Directory)`
  （`dictionary_import_manager.dart`，`@visibleForTesting`，复用 native yomichan/migaku 判据：
  任意层有 `index.json` 或任意 `.json` 即视为词典）；`importFromDirectory` 分支 B 打包前调用，
  无词典则抛明确的 `t.dictionary_unrecognized_format`（i18n key 已存在，17 语言齐全）。
  预检与 `packDirectoryToZip` 同样 `recursive`，子目录里的词典不会被误杀（Never break userspace）。
  无关文件混在真词典目录里仍正常导入（native 只读词典主文件）。提交：见分支 todo-379-dict-conf-import。
- **[x] ② 已加自动化测试** — `hibiki/test/models/dictionary_import_directory_precheck_test.dart`
  纯函数守卫 7 例：顶层 index.json / 嵌套子目录词典 / 散 .json(migaku) / 词典+无关.conf 混合 → true；
  只有 .conf（用户场景） / 全非 json 杂项 / 空目录 → false。撤预检调用即放行无词典目录（回归形态）。
- **备注**：
  - 用户文件 `879-11f1-ab07-7df86a9e5503.conf` 是 UUID 片段命名的 QQ 接收临时文件，
    极可能是被 QQ 改名截断的下载文件或纯配置文件，非词典。修复后用户会得到明确的
    「无法识别的词典格式」提示而非含糊「导入失败」。
  - 若该 .conf 实为被改名的 yomitan zip，用户应改用「导入词典文件」选中它本身（detectFormat
    按 .zip 内容判格式），而非「导入文件夹」——本修复不改这条路径。
  - native C++ importer 源码不在本仓库（预编译 FFI），未改 native；纯 Dart 层根因修复。
  - 待真机复测：选含 .conf 的目录确认弹「无法识别的词典格式」、选正常 yomitan 目录仍正常导入。
