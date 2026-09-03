## BUG-1686 · 视频首页「下一集」「最近添加」两行不含互联远端条目
- **报告**：2026-08-16（用户：「视频首页没完全互联」）
- **真实性**：✅ 真 bug。首页 home 分区就三条横滚行，只有「继续观看」认远端：
  `fushi/lib/src/pages/implementations/home_video_page.dart:2425,2426` 调
  `_buildNextEpisodeRow(filtered, …)` / `_buildRecentlyAddedRow(filtered, …)` 时只传本地行，
  两个函数内部的成员表结构上也只装 `VideoBookRow`。后果：
  本机看到第 1 集、第 2 集只在 host 上时「下一集」整行不出现；host 上新入库的一批在
  子设备首页完全看不见。
  「最近添加」还有一个数据缺口：`RemoteVideoInfo` 没有 `importedAt`，
  `_groupVideos` 只能给远端造一个负数假 importedAt 占位排序
  （同文件 `:4088`），窗口判定 `isVideoRecentlyAdded` 结构上永远判 false。
- **[x] ① 已修复** — `a511a4d0ee`。三行的合集成员统一成 `_VideoSlot`（本地行 | 远端占位）：
  取组内序 / 取观看态 / 取封面 / 点开四件事按来源分流，选集、最近添加窗口判定、排序
  两边同一份代码。远端清单补 `importedAt`（host 下发 `VideoBooks.importedAt`，云清单
  透传已有的 `importedAtMs`），加字段向后兼容：旧 host 不带 → null → 与改动前逐字节
  同行为。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_home_rows_remote_test.dart`
  （跨本地/远端合并选出「下一集」；host 带 importedAt 时远端进「最近添加」；旧 host
  不带时不进 —— 第三条守的是向后兼容）。
- **备注**：血缘同 BUG-995（当时只把「继续观看」与概览接上了远端）。
