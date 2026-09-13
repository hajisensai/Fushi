## BUG-2193 · 本地备份导出：一条幽灵词典元数据行让全部词典静默不打包
- **报告**：2026-09-06（用户：「使用『本地备份-导出』功能时，即便勾选了词典（或勾选其他项），导出的压缩包里也只有 backup_meta.json 和 fushi.db，无法导出词典文件。」）
- **真实性**：✅ 真 bug，而且**接近静默数据丢失**。根因是一道**无日志的全表 AND 门**：
  - `backup_service.dart` 的
    `includeDictionary = wants(dictionary) && await _hasCompleteDictionaryResources(root)`；
  - `_hasCompleteDictionaryResources` 遍历 `dictionary_metadata` 全表，**任何一行**
    其 `dictionaryResources/<name>/` 不存在或为空就 `return false`。
  - 于是「一条坏行 → 一本都不打包」。更糟的是紧接着还会
    `_stripDictionaryState(tmpDir)`（`clearAllDictionaryMeta` + `clearDictionaryHistory`），
    把导出副本 DB 里的词典行也整表删掉。**zip 里既没有 `dictionaryResources/`，
    `fushi.db` 里也没有词典元数据。**
  - **全程零日志、零 UI 提示**，导出照样弹 `backup_export_success`。
- **不变式本身是对的，实现方式是错的**：`docs/reviews/2026-06-01-project-review.md`
  记着当年引入它的理由——「每一行 `dictionary_metadata` 都必须有对应的
  `dictionaryResources/<name>/` 文件」，目的是不让恢复端造出查不了的幽灵词典。
  这条不变式没问题，但把它实现成**全表 AND**，代价就从「那一条」放大成了「全部」。
- **幽灵行怎么来的**（都有代码/档案依据）：
  1. 运行期引擎**主动容忍**幽灵行——`app_model.dart` 的 `bucketDictPaths` 里
     `if (!e.exists) continue;`，所以用户平时完全看不出自己有一行坏数据。
  2. 覆盖式导入把 bak 里的词典行整表灌回、不校验磁盘
     （`_reapplyDictionaryTablesFromBak`）。
  3. `docs/bugs/BUG-1994-profile-switch-prunes-dictionary-metadata.md`：
     profile 切换会误删/误留 `dictionary_metadata` 行。
  4. 导入中断留下的 `import_temp` / `download_temp`、删除失败的 `.pending_delete`。
- **第二个根因：显示口径 ≠ 打包口径**。勾选对话框里的「词典 (N)」来自
  `summarizeLiveContent`，那里 `(await _db.getAllDictionaryMetadata()).length`
  **只数 DB 行、完全不看磁盘**。于是对话框显示「词典 (12)」，勾上，导出后一本没有——
  用户没有任何线索。（同一个函数里字体那一格反而是对齐的，注释还写着
  「这也正是导出会打包的内容，所以预览计数、打包内容、导入回读三者一致」。）
- **恢复侧会把这个坑埋得更深**（未改，仅记录）：`restoreBackup` 见包里没有
  `dictionaryResources/` 条目时走 BUG-454 分支，认定「用户当初就没勾词典」，
  从 `pre-restore.bak` 把本机词典行灌回、**不提示**。恢复到有旧库的机器上问题被完美
  掩盖；恢复到新机器则词典彻底消失且零告警。
- **[x] ① 已修复** — `worktree-fix-dict-download-error-anki-parallel`：
  - **全表 AND → 逐本分区**：新增 `_DictionaryPackPlan{packable, ghosts}` 与
    `_planDictionaryPack(root)`，逐本查磁盘后分区。不变式依然成立（出包里的每一行
    都有对应文件），但代价降到「那一条」。
  - **剥离改成三分支**：没勾词典 → 整表清空（行为不变）；勾了但一本都打不出来 →
    同上；勾了且有得打 → **只**删缺文件的那几行（新增 `_stripGhostDictionaryRows`，
    走 `deleteDictionaryMeta(name)` 逐行删，**不动查询历史**——那是「这次不导出词典」
    才该做的事）。
  - **打包按词典名枚举**：新增 `_collectDictionaryTrees`，只打 `packable` 里那几个
    子目录。顺带修掉旧实现的副作用——`_collectTreeFiles` 整棵树无差别打包，会把
    `import_temp` / `download_temp` / `update_temp` / `.pending_delete` 一起塞进备份包
    白白撑大。
  - **不再静默**：`createBackup` 新增 `onDictionariesSkipped` 回调；
    `runBackupExportFlow` 收到后把成功提示换成
    `backup_export_dictionaries_skipped`（点名跳过了哪几本，i18n × 17 语言）。
    用户没勾词典时**不报**——那是他自己的选择，不是缺陷。
  - **预览计数与打包口径统一**：`summarizeLiveContent` 的词典格改成数
    `_planDictionaryPack(...).packable.length`。
- **[x] ② 已加自动化测试** — 新增 `fushi/test/sync/backup_ghost_dictionary_row_test.dart`（6 条）。
  定向批 8 个文件共 **90 条全绿**（含既有 `backup_categories_test` /
  `backup_service_test` / `backup_full_export_test`，行为无回归）。
  - 一条幽灵行不再连累其余词典：两本好的照进包，坏的那本只出现在 `skipped` 里。
  - 运行期临时目录不进包（按词典名枚举的副产品）。
  - 全是幽灵行时如实报出全部跳过，且不产出空的 `dictionaryResources/` 前缀。
  - 没有幽灵行时**一条都不报**（不制造假警报）。
  - 用户没勾词典时不算「被跳过」。
  - 预览计数只数打得出来的（3 行 DB / 2 本有文件 → 计数必须是 2）。
  - **为什么这个形态此前零覆盖**：`backup_categories_test` 的 harness 注释里明写
    数据是造来「让 `_hasCompleteDictionaryResources` 放行」的；
    `backup_service_test.dart:460` 那条只覆盖「整个根目录都不存在」，
    没有覆盖「根在、但某一行的子目录缺失」这个真实形态。
  - **变异实测**（非空转）：把判据改回 `... && dictionaryPlan.ghosts.isEmpty`
    （即还原成全表 AND 门）→ 新测试立刻红；还原后源文件 sha256 与变异前逐字节一致。
- **未做 / 已知缺口**：
  - **恢复侧的歧义未消**：包里没有词典条目时，`restoreBackup` 仍无法区分
    「用户没勾」与「导出时被跳过了」。`backup_meta.json` 的 `excludedCategories`
    已经能表达前者，真正的修法是让恢复端在「没勾 ≠ 空」时给出提示。本条没动它，
    避免把备份 wire 格式的改动混进来。
  - **真机复测未做**：本机无 Android 设备接入本次会话，用户那台机器上到底是哪几行
    幽灵行仍未知。要坐实需要用户的 `dictionary_metadata` 行数与
    `dictionaryResources/` 实际子目录清单做一次比对——修复后导出时那条
    「有 N 本词典被跳过（…）」的提示会直接把名字报出来。
