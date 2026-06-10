## BUG-171 · 删除词典后查词仍命中已删词典(引擎实例未reload/dispose,需重启)
- **报告**：2026-06-11（用户：飞书巡检 TODO-095）
- **真实性**：✅ 真 bug。两处控制流漏洞，都在 `hibiki/lib/src/models/app_model.dart`：
  - **漏洞 A（单本删到空）**：`_rebuildDictPathsCache()` / `_rebuildDictPathsCacheAsync()`
    把 `HoshiDicts.initializeTyped(...)` 包在 `if (termPaths.isNotEmpty || freqPaths.isNotEmpty || pitchPaths.isNotEmpty)`
    守卫里。删除最后一本（或某类型最后一本）词典后三组路径全空 → `if` 为 false →
    引擎**不重建**，旧的 native FFI 实例（仍装着被删词典的内存索引）原封保留 →
    查词仍命中已删词典，必须重启 app（旧址：app_model.dart 593-618 / 622-650）。
  - **漏洞 B（删全部）**：`deleteDictionaries()`（清空整库）只清 Dart 缓存 + 删文件，
    **完全不触碰引擎实例**，全部旧索引仍在 native 内存里（旧址：app_model.dart 1844-1862）。
  - 引擎模型：`packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart` 是 in-memory
    单例（`_instance`），词典经 `addTermDict` 加载进 native handle，**没有"卸载单本词典"
    的 native API**；唯一卸载途径是 `initializeTyped`/`initialize` 用剩余路径整体重建
    （dispose 旧 handle）。`searchDictionary()` 已有 `if (!HoshiDicts.isInitialized)`
    守卫，所以重建成"空引擎"安全降级为空结果，不会崩溃（app_model.dart 1982）。
- **[x] ① 已修复** — commit `<PENDING>`：根因修复。`app_model.dart`：
  ① `_rebuildDictPathsCache` / `_rebuildDictPathsCacheAsync` 去掉错误的 `isNotEmpty`
  守卫，无条件 `initializeTyped`——空路径集重建成空引擎，丢弃被删词典索引；
  ② `deleteDictionaries()` 清完缓存后调 `_rebuildDictPathsCache()` 重载引擎。
  自动实时生效（无需用户手动刷新、无需重启）。
- **[x] ② 已加自动化测试** — `hibiki/test/models/dictionary_delete_engine_reload_guard_test.dart`：
  源码守卫（最强可落地层；真实 reload 走 C++ FFI 不可在 flutter_test link，
  删除方法是绑了 live DB+FS+FFI 的 AppModel 成员）。4 用例断言两条控制流不变量：
  A/A2 `_rebuildDictPathsCache(Async)` 不被 `isNotEmpty` 门控、B `deleteDictionaries`
  重建引擎、C `deleteDictionary` 仍重建。撤回修复 A2/B 转红已实测。
- **备注**：真机待复测原始失败路径——删一本词典（尤其删到只剩它一本/删全部）后，
  **不重启** app 直接查那本词典里的词，应查不到。修复在 worktree
  `.worktrees/todo-095-dict-delete-refresh`，未 push 未合 develop。
