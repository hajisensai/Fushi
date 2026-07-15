## BUG-995 · 视频页「继续观看」+「媒体库概览」在只有远端视频时不显示且不计入远端
- **报告**：2026-07-15（用户：继续观看和书库概览没有。远端的）
- **真实性**：✅ 真 bug。根因：`home_video_page.dart` 概览块门控 `if (all.isNotEmpty)`（all=本地视频）+ `_buildOverviewSection(all)` 与 `computeVideoLibraryOverview(entries: all)` 只喂本地。用户手机基本无本地视频、全靠互联看桌面远端视频 → all 空 → 概览+继续观看整块**不渲染**，总数/继续观看也不含远端。（书架页概览已含远端 remoteBooks/remoteSrtBooks；视频页此前未同步，属 BUG-790/815 同类残留。）
- **[x] ① 已修复** — 门控改 `if (all.isNotEmpty || remoteVideos.isNotEmpty)`；`_buildOverviewSection(all, remoteVideos)` 把远端视频并入 `VideoOverviewEntry`（bookUid=id、lastPositionMs=positionMs、completed=false 计未完成、importedAt=null 不计近7天）+ `lastWatchedByUid` 并入远端 positionUpdatedAtMs 参与 hero 择新；hero 本地找不到时在 remoteVideos 找，新增 `_buildContinueHeroRemote`（同布局，封面 `_buildRemoteVideoCover`、点击 `_openRemote` 流播）。书架侧「继续阅读」不加远端 hero——书须下载才能读，远端占位无本地进度（视频可流播续看，故不对称是正确的）。
- **[x] ② 已加自动化测试** — `test/pages/home_tab_keepalive_guard_test.dart` 源码守卫：断言概览门控含 `remoteVideos.isNotEmpty`、`_buildOverviewSection` 接收 `List<RemoteVideoInfo>`、`_buildContinueHeroRemote` 存在。（视频页 widget 测试有既有 timer 泄漏无法稳定跑，用确定性守卫。）
- **备注**：取 832（develop bug 号已到 827，我独有的取 828-832）。**未真机验证，勿宣称已修好。**
