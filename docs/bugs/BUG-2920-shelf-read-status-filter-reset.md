## BUG-2920 · 书架阅读状态筛选每次打开软件都重置
- **报告**：2026-10-03（用户：书架搜索栏右侧「阅读状态」选成「在读」后，每次重开软件都变回「阅读状态」= 全部）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi_history_page.dart` 的 `_readStatusFilter` 只是 State 字段，注释写着「与搜索词同理不持久化」，重启后 State 重建即回到 null（全部）。同为库页筛选，游戏库的游玩状态（`GalgameLibraryView.status`）与书架排序方式（`shelf_sort_mode`）都持久化，只有它没有——搜索词不持久化是有意的（挂着旧词像书没了），但阅读状态是用户刻意选的视图，不该同理。
- **[x] ① 已修复** — 新偏好键 `shelf_read_status_filter`（`ShelfReadStatus.name`，`''` = 全部；登记于 `preference_keys.dart`，读写在 `PreferencesRepository.shelfReadStatusFilterName` / `setShelfReadStatusFilterName`）；下拉选择经 `_setReadStatusFilter` 落库，`initState` 读回，未知值按全部处理。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_shelf_read_status_filter_persist_test.dart`：真点下拉选「在读」→ 偏好写入 → 换 key 重建页面 State（等价重启）后下拉仍为「在读」→ 选回「全部」也落库；偏好里是未知值时回落全部。
- **备注**：书架与漫画库共用这一页面实例的同一个键（与 `shelf_sort_mode` 同口径）。
