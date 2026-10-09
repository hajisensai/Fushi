## BUG-2995 · 整合包父目录与嵌套 Yomitan 根同时存在时子词典被重打包为空
- **报告**：2026-10-06（Codex 第六轮审查 HBK-AUDIT-043；复现 `fushi/test/models/dictionary_nested_root_bundle_repro.dart`，分支 `codex/sh-style-review-1006`；引入于 `91749fb328c`）
- **真实性**：✅ 真 bug（根因：`fushi/lib/src/models/dictionary_import_manager.dart:459` 给每个 Yomitan 根打包时把**所有其它根**都放进 skipPaths，`packDirectoryToZip` 的 `skipped`（`:842`）用 `path.isWithin(skip, file)` 判排除；子词典的 skipPaths 含祖先根，于是子词典自己的全部文件都被判成「在别的词典里」，打出空 zip）
- **[x] ① 已修复** — `dictionary_import_manager.dart:463` 只排除落在本根之下的其它根（`path.isWithin(root, d.path)`）；祖先根 / 兄弟根本来就不在本根的遍历范围内，不需要排除
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_nested_root_bundle_test.dart`（真实 importFromFile → 拆包 → packDirectoryToZip，只把末端 native 导入换成产物检查：父+子、三层嵌套、兄弟+嵌套+MDX 混合，3 例）
- **备注**：
