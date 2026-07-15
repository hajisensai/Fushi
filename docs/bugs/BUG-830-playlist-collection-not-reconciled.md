## BUG-830 · m3u8播放列表增删视频后合集成员不更新
- **报告**：2026-07-15（用户）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/source/media_source_scanner.dart:625`（旧 `_importPlaylists`）。
- **[x] ① 已修复** — `hibiki/lib/src/media/source/media_source_scanner.dart`（`_importPlaylists` 重扫改 reconcile）+ `hibiki/lib/src/media/video/video_book_repository.dart`（新增 `reconcileSplitPlaylist`）
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_import_split_playlist_test.dart`（`reconcileSplitPlaylist` group 三例）+ `hibiki/test/media/source/media_source_scanner_test.dart`（source guard 更新为 reconcile 契约）
- **备注**：

### 根因
统一合集 Phase 2 里，一个 m3u8 清单 = N 条独立 `VideoBooks` 行 + 一个 `MediaCollections(collectionType='playlist')`，成员走 `MediaCollectionItems`。`_importPlaylists` 用「同名 playlist 合集是否已存在」判重（合集名 = m3u8 basename），命中即 `if (existingPlaylistNames.contains(collectionName)) continue;`（旧 `media_source_scanner.dart:625`）——**只要合集已存在就整体跳过，连清单都不读**，从不把清单和 `MediaCollectionItems` 做差异比对。于是磁盘上编辑 m3u8 增删某集后，成员表永远停在首次导入那一刻的快照，剧集面板/合集详情显示旧成员。

初衷是「编辑集路径重扫仍幂等、不产生 X (2) 重复」（TODO-1237 ②），但把「幂等」错误地实现成了「存在即整体跳过」，而非「存在则以清单为准对齐成员」。

### 修复
- 新增 `VideoBookRepository.reconcileSplitPlaylist(collectionId, entries)`：以清单为准、按集的**稳定基身份** `coreSingleVideoBookUid`（取文件名去扩展名、与目录/绝对路径无关）对齐成员——
  - 清单有、成员没有的基身份 → 建 VideoBook + `addToCollection`；
  - 成员有、清单已删的基身份 → 只 `removeFromCollection` 解绑，**保留 VideoBook 本体**（不丢观看进度，非破坏性）。
  - 先加后删，避免整批替换时合集瞬时空掉被「移空自删」误删。已在清单里的集不重跑 `importSplitPlaylist`（避免撞 uid 加后缀造重复行）。
- `_importPlaylists` 重扫逻辑：把「同名即 `continue` 跳过」改为「首导不存在 → `importSplitPlaylist`；已存在 → `reconcileSplitPlaylist` 对齐成员」，并把去重键从 `Set<String>` 名集改成 `Map<String,int>` 名→合集 id。

### 为何按「基身份」而非完整路径匹配
`coreSingleVideoBookUid` 是 basename 派生、与路径无关。同一集换目录（相对→绝对 / 移动文件夹）基身份不变，判为「未变」不增删，不误制孤儿行——保住重扫 relocation 幂等契约（守卫 `media_source_scanner_test` 的 `re-scan after manifest episode paths change` 用例）。真正的增删（不同 basename 的集）才触发成员同步。
