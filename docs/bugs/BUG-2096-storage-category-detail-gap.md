## BUG-2096 · 存储页词典/书籍类目明细不覆盖总量 10.7GB 不可见
- **报告**：2026-09-03（用户：两张「设置 → 存储」截图）
- **真实性**：✅ 真 bug。用户机器上词典类目显示 **11.3 GB**，展开后 8 部词典明细之和只有
  **583.7 MB**（142 + 98.9 + 85.2 + 81.6 + 76.9 + 59.8 + 36.0 + 3.3），**10.7 GB 既看不见、
  也解释不了、更删不掉**。
  根因是两套口径 + 页面从不显示二者之差：
  - `fushi/lib/src/storage/storage_usage_service.dart:571` `_scanBooks` /
    `:621` `_scanDictionaries` —— 类目总量按 `_pathsSizeSync(categoryRoots)`
    **整树**求和（含孤儿），明细却只铺 **DB 已知条目**（`dictionaryResources/<名>`、
    每本书的 counted 路径）。
  - 词典类目的根有三个（`:380` `kStorageCategoryDocumentsChildren`）：
    `dictionaryResources` / `dictionaryImportWorkingDirectory` / `recommended_pack`，
    后两个下面的东西**没有任何 DB 行**，结构上永远进不了明细。
  - `fushi/lib/src/pages/implementations/storage_usage_view.dart:473` `_buildEntryRows`
    只渲染 `usage.entries`（外加「其余 N 项」折叠行），**没有任何差额行**——两套口径的
    缺口在 UI 上彻底静默。
  用户这 10.7 GB 的具体归属见 [BUG-2109](BUG-2109-recommended-pack-never-deleted.md)
  （新手引导推荐包的 9.5 GB zip 导入后永不删除，就落在 `recommended_pack/`）。本条只
  管「占了盘却不出现在明细里」这个显示缺陷本身——即使换成别的残留，洞一样在。
- **[x] ① 已修复** — `_scanBooks` / `_scanDictionaries` 改为：一次 isolate 调用同时取
  「类目根的直接子项」与「每个已知条目的大小」，再把**未被已知条目认领的直接子项**作为
  只读明细铺出来（`StorageEntryKind.readOnly`——裸删会绕过墓碑/引用护栏）。类目总量改由
  子项之和得出（与整树求和恒等，根目录自身不占字节），**扫描量不变**。
  新增 `_topLevelOwners` 把已知条目的路径收敛到「直接子项」层级再求差集：书的音频可能深在
  `fushi_books/<bookKey>/audio/` 之下，若按路径全等去重，整个 `fushi_books/<bookKey>` 会被
  当成没人认领而与那本书重复计一遍。
  提交：见下方测试提交。
- **[x] ② 已加自动化测试** — `fushi/test/storage/storage_usage_service_test.dart`
  - 既有两条断言按新契约更新（旧断言恰恰把病灶写死了：书籍用例造了孤儿目录
    `fushi_books/orphan` 并断言 `entries.length == 2`，即孤儿**不出现**）；两条都补上
    「明细之和 == 类目总量」的对账断言。
  - 新增「BUG-2096：推荐包暂存的整包 zip 出现在词典明细里，而不是只体现为差额」——
    直接复刻用户现场（`dictionaryResources/JMdict` + `recommended_pack/*.zip`）。
  - 新增「认领判据按『类目根的直接子项』收敛，不与已知条目重复计数」——守住上面那个
    重复计数陷阱。
- **备注**：真机未验证（用户设备未连本机 adb，`adb devices` 为空）。结论全部由代码路径 +
  临时目录真实落盘的单测得出；用户可自查 `Android/data/<包名>/files/recommended_pack/`
  确认那 9.5 GB。
