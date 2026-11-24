## BUG-5418 · 「导入文件夹（仅此一次）」导入的发布组目录，SPs / Menus 特典在系列墙上各自成卡
- **报告**：2026-11-24（应用内反馈 aBGenWuGns，Windows 3.4.0-debug.32216）
- **真实性**：✅ 真 bug。用户走的是来源页「导入文件夹（仅此一次）」（截图里没有任何常驻来源）。
  `importLocalFolderOnceAt`（`fushi/lib/src/media/source_library/add_local_folder_source.dart`）扫完即删临时来源行，
  导入的视频 FK 归 NULL、落进无来源范围；而本地作品索引 `VideoSourceMetadataIndexer` 只认来源行：扫描里那次对临时行
  调用时计划器对一次性行不立项（`videoSourcePlansScrapeWorks`），没建作品也没绑特典；启动回填
  `reindexLocalVideoSources`（`fushi/lib/src/media/video/metadata/video_local_index_rebuild.dart`）只遍历
  `getMediaSourcesByKind('video')`，同样永远轮不到无来源视频。在线刮削链早已覆盖无来源范围（拍板台
  gtpgyff3l7-oneshot-scrape），所以正片有了作品，NCOP / NCED / CM / PV / Menu 却从没挂上去。BUG-5260 / BUG-5354
  修的是常驻来源这条路，与这里无关。
- **[x] ① 已修复** — 本地索引改按「刮削范围」跑，与刮削链同口径：`VideoSourceMetadataIndexer` 接受无来源范围
  （成员按 `videoBookInScrapeScope`、NFO / 作品根按 `videoScrapeRootFor`，不认领孤儿蓝光），一次性临时行直接不立项；
  `importLocalFolderOnceAt` 删掉临时行后对无来源范围补跑一次索引；启动回填 / 清除刮削记录后的重建改为遍历
  `localVideoScrapeScopes`（含无来源范围），已经按修前方式导入的库下次启动自动补上绑定。
  详情页「没有规范作品时兜底索引」（`MediaCollectionDetailPage._scheduleSourceIndexing`）同样把无来源成员
  归到无来源范围一并索引，不再只认有来源 id 的成员。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_one_shot_import_extras_test.dart`：用反馈样本目录
  清单做夹具，一次性导入后 13 个 SPs / Menus 特典全部挂到正片作品下、正片不被当特典；修前状态（无来源视频没有作品）
  经启动回填补上绑定且第二次零写入；常驻来源同目录对照。
- **备注**：同一反馈里「详情页预告片 / 花絮点不开」不是代码缺陷：录屏里点击后弹「无法加载该视频」，即 YouTube 解析失败；
  本机实测该作品 TMDB 上的预告片（GsqgtO0vgmY / mnQTohspiYk / 9ruWZg245HA）都能解析，`G6Q1zZ0Ovfo`（日志里缩略图 404）
  已下架、全部 client 报 unplayable；用户日志里 TMDB 图片、反馈上传都有 TLS 握手失败，属网络环境。顺手修了可诊断性：
  两处在线特典起播失败原先吞掉异常，现在记诊断日志（`MediaCollectionDetailPage.openWorkExtra` /
  `VideoWorkDetailPage.playExtra`）。
