## BUG-1650 · 同步拉回更远进度后首页继续与书架不刷新须重启
- **报告**：2026-08-14（用户：every time you sync and the remote progress is further than local, you have to restart the app for the progress to actually reflect in the "continue reading"）
- **真实性**：✅ 真 bug，三处断链共同作用（首页「继续」的书侧数据全部派生自 `reader_positions`，而同步回灌只写这张表）：
  1. `FushiDatabase.watchDashboardDataChanges()`（首页自动刷新的表级信号，`database_statistics.part.dart`）表集不含 `reader_positions` → 同步写回后首页不重载；
  2. 书数据的三个缓存 provider（`fushiBooksProvider`（`MediaItem.position` 派生自 reader_positions）/ `bookLastReadAtProvider`，`reader_fushi_source.dart`）只在**关书**（`onSourceExit`）与**导入**时失效——同步这条写入路径没有任何失效点；
  3. BUG-686 让书进度拉回触发 `ReaderMediaType.refreshTab()`，但书架页的 `_reloadShelfMapsOnTabRefresh` 只重载合集折叠映射、不失效上述 provider——信号修了、消费端一直没接上。
  重启「能好」正是因为 provider 冷重建时才重新读库。
- **[x] ① 已修复** —（本分支提交）响应式根修，一条通道覆盖所有写入点（本机关书 / 互联 sweep / 云同步 / 下载回填）：
  - `watchDashboardDataChanges()` 表集加入 `readerPositions`；
  - 首页 `_scheduleReload` 防抖回调里同点失效 `fushiBooksProvider` + `bookLastReadAtProvider`（书架从未打开也能刷新；频度由写入端 debounce + 400ms 防抖兜住）；
  - 书架 `_reloadShelfMapsOnTabRefresh` 同点失效两 provider（进度条 / 最近阅读排序同步后立即正确）。
  视频侧无此断链：首页 `_videos` 走 `videoBooks` 表级信号（本就在表集里），sweep 写 `updateVideoBookPosition` 即触发。
- **[x] ② 已加自动化测试** — `fushi/test/database/activity_events_test.dart`（`watchDashboardDataChanges` 在 `upsertReaderPosition` 时 emit——根通道守卫，同组既有 activity/统计/视频改名用例同款）。页面侧 invalidate 是两行胶水，由根通道测试覆盖。
- **备注**：视频**库页**（home_video_page）监听的是 `watchVideoBookUids().distinct`（纯列更新不触发），同步写回断点后要切回 tab 才刷新——症状轻（tab 激活即刷），未在本条处理，记为后续观察项。
