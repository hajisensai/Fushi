## BUG-1180 · 互联远端库列表零缓存，每次切页面全额重拉

- **报告**：2026-07-28（用户：每次切页面都要重新拉取）
- **真实性**：✅ 真 bug。远端**条目列表**从来没有缓存层——只有封面图有磁盘缓存
  （`hibiki/lib/src/sync/remote_cover_cache.dart:19`）。清单本身是裸 GET + jsonDecode：
  - `hibiki/lib/src/sync/interconnect_sync_backend.dart:709` `listRemoteBooks`
  - `hibiki/lib/src/sync/interconnect_sync_backend.dart:1163` `listRemoteVideos`
  - `hibiki/lib/src/sync/interconnect_sync_backend.dart:1132` `listRemoteActivity`
  - `hibiki/lib/src/sync/cloud_remote_video_client.dart:32` 云清单同样每次重读

  而顶层 tab 保活（BUG-750）之后，为了让对端新增内容仍然可见（BUG-992/994），书架与
  视频页各注册了一个「切回本 tab 就无条件重拉」的监听器：
  - `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:358` `_onShellTabActivated`
  - `hibiki/lib/src/pages/implementations/home_video_page.dart:264` `onTabActivated`

  净效果：保活省下的重建被这两个监听器原样加了回来，**每切一次页面 = 一整轮完整
  网络往返**。首页 dashboard 更差——它根本不在 `_keepAliveTabs`
  （`home_page.dart:935`），每次进首页整页重建，并**串行**发三个远端请求
  （`home_dashboard_page.dart:530-534`），`_scheduleReload` 的 400ms 防抖还会再走一遍。

  放大器见 [BUG-1183](BUG-1183-restore-auth-invalidates-session.md)（每次拉取前
  `restoreAuth` 把已探明的地址作废，逼出一轮全候选重探测）。

- **[x] ① 已修复** — 新增 `hibiki/lib/src/sync/remote_library_cache.dart`：
  `RemoteLibraryCache` = 通用 `key -> slot` 表，提供 TTL（默认 60s）、in-flight 去重、
  显式失效、generation 守卫（拦截「旧请求后到覆盖新结果」）。app 级
  `remoteLibraryCacheProvider` 让书架 / 漫画书架 / 视频页 / 首页共享同一份，
  「首页刚拉过书清单、切到书架」直接命中。

  接线：`reader_history/remote.part.dart` 的 `_loadRemoteBooks` /
  `_loadStandaloneRemoteSrtAudiobooks`、`home_video_page.dart` 的 `_loadRemoteVideos`
  （互联与云盘分属 `videos` / `cloud_videos` 两个 key——元素类型不同，共用会 cast 崩）、
  `home_dashboard_page.dart` 的 `_loadRemoteDashboardData`（顺带把三个串行请求改成
  `Future.wait` 并行）。

  **强制穿透只有显式入口**：下拉刷新（两页的 `_pullToRefresh*` 传 `forceRefresh: true`）
  与「管理来源」（`_openManageSources` 先 `invalidateAll()`，换了对端不能拿旧清单渲染）。

  缓存只包住「问对端要清单」这一层，本地 DB 查询与去重仍每次照跑——本地新增/删除的
  条目立即反映在混排网格里，BUG-992/994 的用户可见语义不受影响。

- **[x] ② 已加自动化测试** —
  - `hibiki/test/sync/remote_library_cache_test.dart`（12 例）：TTL 命中 / TTL 过期重取 /
    forceRefresh 穿透 / in-flight 去重 / 失败不缓存且下次重试 / 失败保留上次成功值 /
    单 key 失效不牵连别域 / invalidateAll / 在途请求被失效后不写回 /
    forceRefresh 期间旧请求不覆盖新结果 / activity 按 limit 分槽 / 视频与云视频分槽。
  - `hibiki/test/pages/reader_remote_interconnect_test.dart`：
    「BUG-992/1175: 切回书架 tab 远端卡在场，且 TTL 内不重打网络」取代原 BUG-992 用例
    （原用例断言的是实现细节「调用次数增加」，与本 bug 直接冲突；新用例断言用户可见的
    不变式「远端卡在场」+ 新约束「不得重复联网」），以及
    「BUG-1180: 下拉刷新强制穿透缓存」。

- **备注**：TTL 定为 60s 的取舍——切页面是秒级操作必须命中缓存；「对端刚加了一本书」的
  可见延迟上限一分钟，且下拉刷新随时可强制穿透。
