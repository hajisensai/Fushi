## BUG-1731 · 互联子端看片进度不反向推进 host 的继续观看/下一集
- **报告**：2026-08-19（用户：手机（peer）互联电脑（host），接着第 13 集看完 14、15 集；手机「继续观看」正确显示 16，电脑仍显示下一集=14）
- **真实性**：✅ 真 bug，两处断链共同作用（子端上报链路本身完好且身份正确：`video_fushi_page.dart` `_persistRemotePosition` → `PUT /api/library/videos/<id>/position`，合集模式 key = (成员 id, 0) 与 host 该集 bookUid 一致）：
  1. host 收到上报只写 prefs：`fushi/lib/src/sync/app_model_library_host_service.dart:1503-1526`（`putVideoPosition`）LWW 后仅 `setPrefTyped` `video_remote_position_<uid>` / `..._at_<uid>`，**不写 VideoBooks 行**。该 prefs 键空间唯一消费者是「下发清单给子端」；host 自己的「继续观看/下一集」读的是 `VideoWatchStatistics.lastModified`（`home_video_page.dart` `_watchAtByUid`）+ `VideoBooks.lastPositionMs/lastPlayedAt`，永远看不到对端进度。client 侧 `sync_orchestrator.dart` 的 `writeBackLocal` 早就有「prefs + `updateVideoBookPosition(uid, pos, playedAt: 对端 updatedAtMs)`」双写纪律，host 侧缺的正是这句镜像。
  2. 即使写了行，锚点还是不动：`home_video_page.dart` `_seriesPlaybackStates` / `_slotWatchedAtMs` 的 `lastWatchedAtMs` 只认统计行（`VideoWatchStatistics`），对端看的 14/15 集在 host 无统计行 → `latestPlayedSeriesIndex`（`video_home_layout.dart:144-156`）锚点仍=13。同页 hero 走 `collection_continue.dart` 用的却是 `VideoBooks.lastPlayedAt`——同页两套锚点口径。
- **[x] ① 已修复** —（本分支提交，分支 fix-interconnect-reverse-progress）：
  - host 落库补齐：`putVideoPosition` prefs 写入后，LWW 胜者来自对端且 `episodeIndex<=0`（合集每集一行 / 单视频）且行存在时，补 `updateVideoBookPosition(id, winner.positionMs, playedAt: winner.updatedAtMs)`。**playedAt 用对端 updatedAtMs 绝不用 now**（传 now 会把对方三天前看的冒充成本机刚看的，钉死续播锚点，BUG-1542 同教训）。`episodeIndex>0`（host-playlist 单行多集形态）不写行——行级 `lastPositionMs` 无按集语义；流式视频无行不强建行。
  - 锚点口径统一：`video_home_layout.dart` 新增纯函数 `effectiveWatchedAtMs(statsWatchedAtMs, lastPlayedAt)` 取两者较大值；`home_video_page.dart` `_seriesPlaybackStates` / `_slotWatchedAtMs` 改走它——无统计行时回落行级 `lastPlayedAt`（与 hero 的 collection_continue 口径一致），有统计行且较新时仍以统计为准（本机播放两来源同时写、时刻近似，行为不变）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/fushi_library_host_service_video_test.dart`：新 group「putVideoPosition mirrors VideoBooks row (BUG-1731)」——上报后行 lastPositionMs/lastPlayedAt 前进且时刻=对端戳、host 本机旧进度被推进、older 上报不回退、episodeIndex>0 不镜像行、无行不建行。
  - `fushi/test/media/video/video_home_layout_test.dart`：新 group「effectiveWatchedAtMs (BUG-1731)」——四个边界 + 用户实报形状端到端（13 集本机统计、14/15 仅远端回灌时刻 → 锚点 15、下一集 16）。
- **备注**：
  - 完成态（`completedAt`）反向同步**本条不做**（后续项）：子端看完整集后 host 行仍无 completedAt，只靠 lastPositionMs/lastPlayedAt 推锚点；对「下一集」行已足够（本修复后电脑端下一集能到 16）。
  - 形态边界：主流互联合集是「每集一行」（`_remotePositionKeyForIndex` 合集模式 key=(成员 id,0)，与 host 清单按成员对齐）；「单行 playlist #ep<N>」形态（episodeIndex>0）的行级镜像**刻意不做**（行级 lastPositionMs 无按集语义），其进度仍走 per-episode prefs 下发，host 本机 UI 对该形态的锚点不受本修复影响。
  - `video_remote_position_*` prefs 与 VideoBooks 行自此在 host 侧成对推进；历史上只有 prefs 的存量差异会在下一次更新的上报到来时被带平。
