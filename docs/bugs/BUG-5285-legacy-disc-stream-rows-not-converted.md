## BUG-5285 · 修复前逐个入库的蓝光流文件行（00000.m2ts）一直留在视频库，不会换成原盘合集
- **报告**：2026-11-23（用户：BUG-5280 遗留的 179 张「00000」卡片，拍板「转成原盘合集」）
- **真实性**：✅ 真 bug。本机库 179 行 `…/BDMV/STREAM/000NN.m2ts`（无来源，全在用户清单「Hibike! Euphonium」里）。BUG-4245 只修了**新**导入走 `DiscLibraryImporter`，存量流文件行没有任何路径会回收：`packages/fushi_engine/lib/media/video/disc/disc_library_import.dart` `_rowsOnDisc`（:281）靠 `discRootForMemberPath` 认盘上的行，它只认 `.mpls` / DVD title，流文件行不算盘的成员，`_reclaimStaleDiscRows` 永远看不到它们；这些盘也不在任何来源库下，扫描器不会再导入。
- **[x] ① 已修复** — 新增 `packages/fushi_engine/lib/media/video/disc/legacy_disc_stream_rows.dart` `migrateLegacyDiscStreamRows`：按盘根分组流文件行 → 同一个 `DiscLibraryImporter.importBlurayDiscs`（`restoreDissolvedGroups: true`）导入成盘合集 → 流文件行所在的其它合集（用户清单）改挂这张盘的标题行（`pinnedByUser`）→ 回收流文件行（不删用户文件、不写删除墓碑）。`AppModel` 启动后与「纯音频视频迁音乐库」同一处跑一次，按数据幂等；盘读不出的行原样留到下次。片段行断点不折到标题（片段内时间与标题时间轴对不上）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/video/disc/legacy_disc_stream_rows_test.dart`（盘根推导、换合集 + 清单改挂 + 回收 + 重跑幂等、残盘不动）。本机真实库副本实测：第一季 3 张盘 → 1 个 14 集盘合集，回收 77 行，清单改挂 14 集。
- **备注**：其余 102 行是第二季 7 张盘（`…/響け! ユーフォニアム 2/…`），盘文件夹已不在磁盘上，无从转换，迁移不动它们（其中 2 行有观看进度）；删不删交用户决定。
