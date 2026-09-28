## BUG-2752 · 互联下载服务器词典后本地词典全部消失
- **报告**：2026-09-28（用户：fushi互联下载服务器词典之后会清空所有本地词典）
- **真实性**：✅ 真 bug。互联下载本身是并集（`sync_orchestrator/dictionaries.part.dart`：服务器独有→下载、本地独有→不删），数据没丢；坏在下载成功后的刷新：`AppModel.refreshAfterSyncRun`（`fushi/lib/src/models/app_model.dart:955`）先 `dictRepo.clearDictionariesCache()` 清空内存词典列表，紧接着 `_rebuildDictPathsCacheAsync()`（`app_model.dart:2182`）读 `dictRepo.dictionaries`——已是空列表——把引擎重建成空集合。表现：词典管理列表清空、查词无结果、刚下载的词典也不显示，重启后 `loadFromDb()` 才回来。只删掉 clear 也不对：同步导入直接写 `dictionary_metadata`，内存缓存根本不知道新词典。
- **[x] ① 已修复** — `refreshAfterSyncRun` 的词典分支改走既有的 `reloadDictionariesFromDb()`（`dictRepo.loadFromDb()` → `_rebuildDictPathsCacheAsync()` → 清结果缓存 → `dictionarySearchAgainNotifier`），再通知 `dictionaryMenuNotifier`。提交 `373c2a6d0ae`。
- **[x] ② 已加自动化测试** — `fushi/test/models/sync_dict_refresh_reload_guard_test.dart`：源码扫描守卫（引擎是 FFI，flutter_test 链接不了，与 BUG-171 同层），断言该分支不再 `clearDictionariesCache()`、必经 DB 重载、刷新管理列表，且 `reloadDictionariesFromDb` 先 `loadFromDb` 后重建引擎。
- **备注**：未真机复现（需要两台互联设备）；根因沿代码路径确定，修复复用 Profile 切换已在用的整表重载路径。
