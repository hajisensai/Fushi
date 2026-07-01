## BUG-515 · 媒体来源重扫跨async读已销毁ProviderScope崩溃
- **报告**：2026-07-01（用户：Windows 1.0.1-debug 崩溃报告，TODO-1084）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/media_sources_dialog.dart:45`
  （原 `HibikiDatabase get _db => ref.read(appProvider).database;`）。
  崩溃栈：`_MediaSourcesDialogState._rescan` 的 `finally` 里 `await _db.getMediaSourceById(row.id)`
  （原 `media_sources_dialog.dart:399`）先于 `if (mounted)` 守卫执行；`_db` 是每次调用都
  `ref.read(appProvider)` 的 getter，走 `ConsumerStatefulElement.read → ProviderScope.containerOf`
  （`getElementForInheritedWidgetOfExactType`）。用户点「重新扫描」后关闭对话框 →
  路由 pop → `ConsumerStatefulElement` deactivate/dispose、`ProviderScope` 从祖先链移除；
  扫描 future 恢复到 `finally` 时再 `ref.read`，InheritedWidget 查找返回 null →
  `StateError('No ProviderScope found')`。属跨 async gap 读已销毁的 ProviderScope。
- **[x] ① 已修复** — `media_sources_dialog.dart`：把 `_db` 从每次 `ref.read` 的 getter 改为
  `late final HibikiDatabase _db`，在 `initState`（ProviderScope 必然存活）里
  `_db = ref.read(appProvider).database` 捕获一次。此后所有 async 方法（`_load` /
  `_rescan` 的 finally / `_addLocalFolder` / `_persistOrder` / `_remove` / `_refreshCount`）
  只用该字段，绝不在 async gap 恢复后再 `ref.read`。字段访问对已 dispose 的 State 安全。
  对话框正常打开时的重扫/添加/移除行为不变（never-break）。提交哈希：见分支
  `fix-1084-media-sources-rescan-scope`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/media_sources_dialog_test.dart`：
  ① 行为烟囱测试 `rescan then dispose dialog mid-scan drains without throwing`：
  点重扫→扫描 in-flight 时把对话框换出树 dispose→排空 future 断言 `takeException()==null`。
  ② 源码守卫组 `BUG-515 no ref access after initState`：`_db is a captured field`
  断言无 `get _db =>` getter、有 `late final HibikiDatabase _db`；
  `every ref.read/watch/listen sits inside initState` 逐行扫描 `ref.(read|watch|listen)`
  必须落在 `initState` 方法体内（去行注释）。已验证：改回原 getter 后两条守卫立即变红
  （精确指出 `HibikiDatabase get _db => ref.read(...)` 那一行），修复后全绿。
- **备注**：源码守卫比脆弱的时序型 widget 测试更能钉死不变量——`flutter_test`（debug）下
  `getElementForInheritedWidgetOfExactType` 对 defunct element 的行为与 release 的
  null→StateError 路径不同，用时序竞态复现 `No ProviderScope found` 不可靠，故以「跨 async
  gap 不再 ref.read」这个根因不变量作为最强可落地守卫层。
