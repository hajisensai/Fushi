## BUG-1595 · 词典更新入口遇新包标题变化仍判新增两版并存
- **报告**：2026-08-13（用户：导入同一部 Yomitan 词典的新版本——标题含版本号「OALDPEX En-Cn 精装版 V2026.08.11」→「V2026.08.13」——无法覆盖旧版，两版并存于词典列表）
- **真实性**：✅ 真 bug。根因链：
  - `fushi/lib/src/models/dictionary_import_manager.dart:683-710`（修复前行号）：判重入口 `_decideUpdate`/`decideUpdate` 只按**新包 title** 喂 `hasExactName` / `hasUpdatableVersion` 两个 bool，被点击的词典（真正的替换目标）完全不参与决策。
  - `fushi/lib/src/models/dictionary_repository.dart:239-256`：`findUpdatable` 只认尾部 `[YYYY-MM-DD]` 方括号日期尾缀（`_dateSuffixPattern`）；「V2026.08.11」这种写法不匹配 → baseName 不相等 → 判成 `newDictionary` → 追加新词典而非替换。
  - `fushi/lib/src/pages/implementations/dictionary_dialog_page.dart:1842-1912`（修复前）：行尾「更新」按钮的 `_updateDictionaryFromFile` 虽带 `forceReplaceExisting: true` + 异名确认框，但 force 导入内部仍按新包 title 决策（`dictionary_import_manager.dart:371`），标题变了照样 `newDictionary`，确认异名后依旧是新增而非替换——该语义陷阱在 `dictionary_dialog_page.dart:1833-1841` 注释里被显式记录。
- **[x] ① 已修复** — 给 `importFromFile` / `AppModel.importDictionary` 增加显式替换目标 `replaceTarget: Dictionary?`：更新入口（本地「从文件覆盖更新」`_updateDictionaryFromFile`、在线单本/批量更新 `_redownloadAndReimport`、启动自动更新 `_autoRedownloadAndReimport`）传入被点击/被更新的词典；`decideUpdate` 新增 `hasReplaceTarget` 恒定 `replaceExact`，旧本清理与设置继承收敛到新的 `resolveAndRemoveReplaced`（删目标磁盘目录 + meta、继承 order/hiddenLanguages/collapsedLanguages，异名撞上另一本已存词典时按同待遇一并清理，避免孤儿 meta / 引擎索引指向被覆盖目录）。异名确认框保留（标题变了用户仍知情），确认后执行的是替换。普通导入入口不传 `replaceTarget`，`_dateSuffixPattern` 语义未动，零破坏。提交：见本分支 PR（worktree-agent-a1fcf4e9481dc5637）。
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_import_force_replace_test.dart`：`hasReplaceTarget` 压过一切按 title 判定（含默认 false 契约不变）；`resolveAndRemoveReplaced` 行为组（真 `DictionaryRepository` + 临时资源目录）：用户症状原型异名替换（并固化「旧决策对该形状确实误判 newDictionary」）、同名替换、撞名双删、无目标时 replaceExact/replaceOldVersion 旧行为不变、非替换决策零副作用、目录缺失容忍。
- **备注**：TODO-2836。
