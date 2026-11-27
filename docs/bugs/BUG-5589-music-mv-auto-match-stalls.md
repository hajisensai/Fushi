## BUG-5589 · 本地 MV 自动匹配停在几首整片音轨上，CD 曲目一首没对过
- **报告**：2026-11-27（用户：「我的音乐cd的动画mv在哪，我怎么找不到」）
- **真实性**：✅ 真 bug。用户库 `music_video_match_checks` 只有 2026-11-26 10:02 一轮写的 15 行、全是电影整片外挂音轨 `.mka`；BUG-5452 的「按发布配特典」对 CD 曲目其实配得上（按库数据模拟，BOCCHI 12 首 CD 曲都能配到 NCOP01/02、CM），但从没被对过。根因三处：
  1. `fushi/lib/src/media/music/metadata/music_video_auto_match.dart`（`schedule`，原 94-114 行）只由 `onMusicSourceScanned`（`app_model.dart`）与设置开关触发，启动不补跑；用户所有音乐来源 `auto_scan = 0`，11-27 10:14 那一轮被自动更新交接杀掉后就再没有下一轮。待办本来就在库里（缺 match_check 的配对），却只在偶发扫描时才消费。
  2. 同文件原 153 行：一对的 `alignLocal` 抛错由整轮外层 catch 接住，后面所有目录一起中止；下一轮又撞同一对，永远挡在同一处。
  3. 整轮没有绑定开轮时的库（响度扫描早在 BUG-5387 就绑了），换库 / 关库时旧库读出的曲目可能写进新库。
- **[x] ① 已修复** — 启动（`post-init-kicks`）消费一轮 MV 匹配与响度扫描（两者按数据幂等）；一对出错只跳过这一对（记错误日志、不记已对过，下一轮再试），不中止整轮；整轮经 `runBackgroundWork('music.videoAutoMatch')` 绑定开轮的库，换库时取消；每对起止各记一条带耗时的诊断（`logDiagnostic`），卡住时能看出卡在哪一对。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_video_auto_match_test.dart`「一对出错只跳过这一对…」。
- **备注**：
  - 11-26 那一轮停在 `V:\…Kitauji…[x265_flac].mka`（3.8 GB 整片音轨，SMB 盘）上、3.7 小时没返回，是卡死还是抛错没能确证（error_log 被截尾）；诊断日志已加，下次复现可定位。没加外层超时兜底。
  - 整片 `.mka` 被音乐库当成「歌」的上游原因另案：BUG-5453 的补搬在启动时对所有任务 `listFiles` 拿到空（host 种子租约 owner 绑的是会轮换的配对凭据指纹，重新配对后 134 个种子对本机 404，客户端把 404 吞成空列表），810 条 `<missing>` 一条没搬成。涉及 host 持久化格式与互联契约，已上拍板台 `design-host-torrent-lease-owner`。
