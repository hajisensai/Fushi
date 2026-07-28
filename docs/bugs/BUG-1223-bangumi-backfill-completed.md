## BUG-1223 · 连令牌前已看完/读完的条目永不上传：视频与书籍 reconcile 只从已有映射出发

- **报告**：2026-07-28（用户：旧的已经完成的也应该上传吧）
- **真实性**：✅ 真 bug（视频/书籍两侧与游戏侧不对称）

根因：进度上报的前提是先有 `media_tracking_mappings` 行，而映射只在 `recordVideoCompleted` / `recordBookProgress` 被**实时事件**触发时才建。三个 reconcile 里：

| 补发路径 | 出发点 | 能否补建映射 |
|---|---|---|
| `loadPersistedGameTrackingStatus`（`media_tracking_repository.dart:393`） | `getAllGalgames()`（全部游戏） | ✅ 能——`_reconcileGameStatus` 走 `recordGameStatus` 完整入队路径 |
| `loadCompletedVideoTrackingProgress`（`:459`） | `listMappings()` | ❌ 不能——且 `_reconcileCompletedVideoProgress` 只调裸 `enqueueProgress` |
| `loadPersistedBookTrackingProgress`（`:530`） | `listMappings()` | ❌ 同上 |

于是「在连上 Bangumi 之前就已经看完/读完」的视频和书落进死角：没有映射 → `enqueueProgress` 直接 `return false` → reconcile 又只从映射出发看不见它们 → 永远不上传，除非用户把那一集**重新看完一次**去触发实时事件。游戏侧没有这个洞，纯粹是视频/书籍侧的实现不对称。

配合 BUG-1220（链路全静默）时症状尤其像"同步坏了"：首页显示已连接、零待办、全部已发送，而 Bangumi 上什么都没有。

- **[x] ① 已修复** — commit 见本分支
  1. `MediaTrackingRepository.loadCompletedUnmappedVideos()` / `loadCompletedUnmappedBooks()`：查「本地 `completed_at` 非空、但既无单集/合集映射（视频）或无 book/bookChapter 映射（书）」的条目，按 `completed_at` 升序取前 N。
  2. `MediaTrackingService._backfillCompletedMappings()` 跑在三个 reconcile **之前**：对每条历史条目调 `recordVideoCompleted` / `recordBookProgress` 完整路径（刮削条目优先、单集 vs 合集语义、高置信度搜索门槛都在那两个方法里，不复制一份），映射建好后随后的 reconcile 自然用完整算法算出准确进度，outbox 单调合并取较大值。
  3. 限流：每批 20 条、单次 `syncNow` 总预算 100 条（可注入，测试用 1/2），剩余留给下次同步——首次连接时全库可能上千条，一次打上千个 Bangumi 搜索既慢又易被限流。
  4. 独立水位 `media_tracking_{video,book}_backfill_watermark_v1`（视频/书各一条，**不能共用**——共用会让另一类中 evidenceAt 小于水位的条目被永久跳过）。每条历史条目只尝试建一次映射：匹配不唯一时不重试，避免每次启动重扫全库；换令牌与其它水位一起归零重新全量补。
- **[x] ② 已加自动化测试** — `hibiki/test/media/tracking/media_tracking_service_test.dart`（group「历史已完成条目补传（BUG-1223）」6 项）
  - 连令牌前看完的视频：无需重看即建映射**并真的发出去**（断言 `episodePatches` 非空 + `pendingCount()==0`）
  - 连令牌前读完的书：无需重读即建映射并上报
  - 每条只尝试一次：第二次同步不再重复搜索（水位越过失败条目）
  - 换令牌把补传水位归零
  - 单次同步预算上限，超出的下次继续补（不被永久跳过）
  - 已有合集映射的分集不重复建单集映射
  - **变异实测**：注释掉 `_backfillCompletedMappings()` 调用后上述 5 项立刻变红（第 6 项是负向断言，本该保持绿），确认不是假绿。
- **备注**：匹配不唯一 → 不建映射的门槛**未放宽**（见 BUG-1220），历史条目里标题噪声大的那些仍需手工关联；首页卡会显示「没有任何条目关联」并指向入口。真机验收要点：库里已有大量已完成条目时，首次连接后连点几次「立即同步」应逐批补齐，且不应出现远端限流报错。
