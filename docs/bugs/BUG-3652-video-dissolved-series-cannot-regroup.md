## BUG-3652 · 整批解散合集后系列永久散成单集，重扫无法恢复
- **报告**：2026-10-21（用户反馈：资源管理器里挪了一个视频后，视频库 Series 视图所有动画季拆成单集卡，卡片标题是单集名（「接敵作戦」「この不当な裁判に救援を！」），顶部「169 works still need identity confirmation」；附目录树与 `collection_member_tombstones` 导出）
- **真实性**：✅ 真 bug。挪文件不是成因——app 无文件监视，重扫把「同名、旧路径已不存在」认作搬家并保留合集归属（`source_library_scanner.dart` 搬家识别），重扫只补不删成员。真正成因由用户墓碑表证实：
  1. 2026-10-08 23:28:26 同一秒写下约 40 条合集级墓碑，含 `Season 01` / `Extras` / CD 专辑等目录合集（`collection`）——AniDB 拆分不碰目录合集（`video_source_scrape_coordinator.dart` `_splitByAnidbWork` 对 `sourceFolderPath != null` 直接返回），只可能是批量解散：库页多选删除合集卡 = 逐个 `deleteMediaCollectionWithAssets`（`home_video_page.dart` `_batchDeleteConfirm`），每个写一条按合集名的墓碑（`database_library.part.dart` `deleteMediaCollection`）。23:39:09 又把重扫按系列名重建的 7 个合集再解散一次；2026-10-21 01:13:29 解散了两个 Dragon Ball 合集与 Dr STONE。
  2. 墓碑是 BUG-1739 的「不复活」门：`VideoFolderGroupCoordinator.groupPaths` 新建 playlist 前查 `hasCollectionDeletionTombstone`，命中就 `continue`；目录合集、m3u8 清单、蓝光盘三处同款。于是解散后的系列**永久**不再被任何扫描归组，界面上既看不到这层状态，也没有撤销入口——用户的库一旦整批解散就无路可回。
  3. 散开的单集卡显示单集名，是因为合集刮削把分集名写进了每集自己的 `video_books.title`；刮削计划器把每个散集算成一部作品，于是出现 169 部「待确认」。
- **[x] ① 已修复** — 保留 BUG-1739 的语义（普通重扫 / 定时扫描仍尊重用户解散），给出唯一的显式出路：
  1. `VideoFolderGroupCoordinator.groupPaths(restoreDissolvedGroups:)`：为 true 时越过合集级墓碑与目录合集的成员墓碑；新建经 `createMediaCollection` 清合集墓碑、加成员经 `addToCollection` 清成员墓碑，恢复后普通重扫幂等。
  2. `SourceLibraryScanner.scan(restoreDissolvedGroups:)` 一路透传到文件名归组、m3u8 清单、蓝光盘三条路径。
  3. 来源行 ⋮ 菜单新增「恢复自动分组」（`media_sources_view.dart` `_restoreAutomaticGrouping`，确认后带参重扫）。
  4. 成因仍有一半没定：墓碑表显示 10-08 的整批解散是用户操作，但用户描述的「挪了一个视频后全散」对应的 10-21 只有 3 条合集墓碑，Spy x Family / Frieren / K-ON 等合集是被**不写墓碑**的路径拿掉的（移空自删 / 互联同步删除 / AI 整理移出，候选未排除）。用户不会查 SQL、整库太大，所以「导出刮削诊断包」新增 `grouping.json`（`video_scrape_diagnostic_exporter.dart` `VideoGroupingSnapshot`）：每集入库时刻与所属合集、含视频或已空的合集、合集级 + 成员级墓碑、视频域 AI 整理记录、配对设备数，成员一律相对路径。用户回传诊断包后据此定位第二成因，另立条目修。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_folder_group_coordinator_test.dart`：「BUG-3652 整批解散后普通重扫保持解散；恢复自动分组把每个系列归回」「BUG-3652 文件夹模式恢复自动分组越过合集墓碑与成员墓碑」。
- **备注**：未处理、另立条目的相邻问题：① 解散提示没有「撤销」（`FushiToast` 无 action 能力）；② app 端不清理磁盘已不存在的视频（只有服务端 `pruneMissingVideoRows`）；③ 下载整理把整条发布名当剧集目录名 / 合集名（`video_download_organizer.dart`），同系列不同发布组拆成两部作品；④ AniDB 拆分先删原合集再建新合集且不在同一事务。
