## BUG-1739 · 来源重扫按自然键复活用户已删除的playlist合集
- **报告**：2026-08-19（用户：QQ 截图报「合集无法删除」——系列页删除合集对话框确认后合集还在；「这个旧功能加入的合集甚至无法删」）
- **真实性**：✅ 真 bug。删除链路本身没有问题（`collection_context_dialog.dart:194-226` → `deleteMediaCollectionWithAssets` → `FushiDatabase.deleteMediaCollection` 删行 + 写合集级墓碑），坏在**删除会被下一次来源扫描撤销**：
  1. 每次来源扫描对该来源下**全部**已入库视频路径重新归组（`source_library_scanner.dart:441-452` → `VideoFolderGroupCoordinator.groupPaths`），多集组找不到既有合集就按自然键 `createMediaCollection(group.series, 'playlist')` 重建（`video_folder_group_coordinator.dart:150-166`）；
  2. m3u8 清单同理：`_importPlaylists`（`source_library_scanner.dart:766+`）发现同名合集不存在（因为被用户删了）就走 `importSplitPlaylist` 首导，重建合集（`video_book_repository.dart:330`）；
  3. `createMediaCollection` 无条件清同自然键的合集级墓碑（`database_library.part.dart:505-512`，语义=「重建=撤销删除」）——这个语义对**用户显式**重建正确，但扫描的自动重建也走同一入口，把删除墓碑一并抹掉，连跨端同步的防复活都失效。
  - 用户视角：删除合集 → 下一次扫描（启动/手动刮削/定时）→ 合集原样回来（还是新 id，旧合集的刮削资料/封面全丢）→「合集无法删除」。
- **[x] ① 已修复** — 根因修复：区分「用户显式创建」与「扫描自动重建」两种意图：
  1. `FushiDatabase.hasCollectionDeletionTombstone(name, type)`（fushi_core `database_library.part.dart`）：查合集级墓碑哨兵行；
  2. `VideoFolderGroupCoordinator.groupPaths` 创建分支先查墓碑，有墓碑不重建（成员视频照常入库/保留，只是不再自动归组）；
  3. `SourceLibraryScanner._importPlaylists` 首导分支同样先查墓碑，有墓碑跳过该清单；
  4. 用户显式路径（导入对话框、批量组合成系列、合集详情）仍走 `createMediaCollection` 清墓碑 = 撤销删除，行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_folder_group_coordinator_test.dart`（BUG-1739 用户删除的合集不被重扫复活；显式重建后恢复归组）+ `fushi/test/media/source_library/source_library_scanner_test.dart`（BUG-1739 已删除的 m3u8 playlist 合集重扫不复活）。
- **备注**：用户同时要求移除旧「导入视频」对话框里产生合集的入口（m3u8 播放列表 / 文件夹自动分组），另行处理，不属于本 bug 修复范围。复活时合集拿新 id、旧 `collection_scrape_meta` 因 id 断链而丢失，也解释了用户「无法刮削/刮削信息丢了」的部分观感。
