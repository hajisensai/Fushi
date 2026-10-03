## BUG-2926 · 下载互联书时 iOS 掉帧：进度回报每次整页重建书架/媒体库
- **报告**：2026-10-04（用户：shishamo，「ios 好像锁帧了……好像是在下书的时候」）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/interconnect_download_manager.dart:704` `_updateProgress` 与 `:711` `_updateBytes` 每个下载分块都调 `_notify()`（`:708` / `:720`），不节流；而消费端整页 watch 整个管理器——书架 `fushi/lib/src/pages/implementations/reader_history/remote.part.dart:340`、媒体库 `fushi/lib/src/pages/implementations/home_video_page.dart:6100` / `:6127`、在线源作品页 `fushi/lib/src/media/video/online/anime_source_detail_page.dart:570`。下载期间每个分块（每秒几十到上百次）都让整页网格重建，iOS 上直接掉帧/锁帧。
- **[x] ① 已修复** — 提交 `2c7efa44df5`。管理器侧 `_notifyProgress` 只在整数百分比变化或距上次通知满 `progressNotifyIntervalMs`（250 ms）时通知，状态切换（完成/失败/取消）仍走不节流的 `_notify`；新增值相等的角标记录 `badgeStateFor` / `aggregateBadgeStateFor`，三处页面改为 `ref.watch(provider.select(...))`，只有角标可见内容变化才重建。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_download_manager_test.dart` 组 `progress notification throttle (BUG-2926)`：1000 个亚百分比分块通知 < 10 次且百分比/完成态照样送达；只有字节变化时 `badgeStateFor` 值相等、跨整百分比才不等。
- **备注**：未在 iOS 真机上测帧率；修复针对的是代码路径上确定的重建风暴。
