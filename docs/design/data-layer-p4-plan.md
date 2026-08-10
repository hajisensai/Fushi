# P4 写侧收敛实现计划(侦察定稿,2026-08-10)

> 基线 develop@7a3505ca7a + Stage 2。分期:A1/A2/A3 本轮落地;B1/B2/B3 需决策仅记录;「必须停在边界」清单碰 wire 禁做。

三个子代理全部回报,承重结论已复核。以下是完整实现地图。

---

# P4 剩余(写侧收敛)实现地图

基线 develop@7a3505ca7a + worktree 未提交 Stage 2 改动(只碰 entryKey→uid 管道,统计写侧无涉)。所有路径相对仓库根,`core:` = `packages/fushi_core/lib/src/database/`。

## 1. 现状全景:事实 vs 投影

| 表 | 角色(代码真相) | 关键位置 |
|---|---|---|
| ActivityEvents | **session 粒度事实流**(read/watch/added/game),纯追加不去重 | 表 `core:tables.dart:239`;唯一 INSERT `core:database_statistics.part.dart:278` |
| ReadingStatistics | 日聚合**投影**——已由 `recordReadingSession` 派生 | `core:database_statistics.part.dart:249`(单入口),`:35`(累加),`:17`(sync OVERWRITE) |
| ReadingHourlyLogs | **tick 粒度独立账本**(非 session 派生物),60s 窗口+跨界拆桶 | 写入 `packages/fushi_audio/lib/src/audiobook/reading_time_tracker.dart:123` |
| VideoWatchStatistics | 日聚合投影,**桶粒度累加**(per-uid 键控 v39) | `core:database_statistics.part.dart:176`(累加)/`:613`(sync OVERWRITE) |
| VideoHourlyLogs | tick 粒度账本(与阅读侧对称) | `core:database_statistics.part.dart:672`/`:707` |
| MiningStatistics | 全局制卡计数**投影**(sourceType,dateKey) | `:828`(累加)/`:861`(MAX) |
| LookupMiningCounters | per-identity 查词+制卡计数**投影**——与 MiningStatistics 是**两份平行投影,无共同事实表** | `:903`/`:948`(累加),`:991`/`:1066`(MAX) |
| GalgameSessions | **事实表,刻意无投影**(现算 GROUP BY),但**不进 sync** | `:470`(insert),设计注释 `:376-380`、`:547` |

制卡的"事实"理论上是 `MinedSentences`,但它被 `_trimMinedSentences` 按 `kMinedSentenceHistoryLimit` 截断(`:1196-1208`)——**不能当计数事实源**,计数真相只存在于调用现场局部变量。

**recordReadingSession 已收敛**:EPUB `fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:1431`、PDF `reader_pdf_page.dart:263`、漫画 `fushi/lib/src/media/manga/reader/manga_fushi_page.dart:2926`。`addReadingStatistic` 在 lib 下已无其它调用方——阅读 session 面收敛干净。

**仍绕开的写面(均属合法设计,不是漏网)**:
- tick 账本:`reading_time_tracker.dart:123`(构造点 navigation.part.dart:1395 / reader_pdf_page.dart:168 / manga_fushi_page.dart:1007,1264)
- sync 落地:`fushi/lib/src/sync/aggregate_sync_service.dart:674/698/721`(deficit-lift)
- **第二条同步通道**:`fushi/lib/src/sync/sync_manager.dart:903` `_writeStatisticsToDb`→`setReadingStatistic`(ttu 风格双向同步,与 aggregate 独立)
- 备份合并裸 SQL:`fushi/lib/src/sync/backup_merge_engine.dart:680`(reading)/`:161`(hourly)

## 2. 视频侧

生产写入**只有一处接线**:`video_fushi_page.dart:3036-3073` 构造全仓唯一的 `VideoWatchTracker`,三路回调:`:3044` addVideoWatchStatistic、`:3065` addVideoHourlyWatchTime、`:3073` addActivityEvent(kActivityWatch)。远端视频不记统计(`:3036` 守卫)。

**漂移面确认存在,形状与阅读侧不同**——不是"多个页面各抄一遍",而是**同一个 tracker 三路各带各的 dateKey**(`fushi/lib/src/media/video/video_watch_tracker.dart:198-204`):
- 日聚合+小时桶用 `splitWatchTime` 的**逐桶 dateKey**(`:200/:202`,跨午夜归两天——正确性依赖于此);
- activity 行在 `stop()`(`:144`)用 **stop 时刻 dateKey** + session 总量;
- 字幕字数逐 cue 落投影(`:175`)、session 累计再进 activity(`:173`)。

ed2f36443f 的理由注释(`core:database_statistics.part.dart:245-248`):"video_watch_statistics 的 flush 是**桶粒度**(dateKey 按各桶归属,跨午夜正确性依赖于此),与 activity 的 session 总量数值天然不同,强行统一会引入跨午夜归属 bug"。

**视频单入口应长什么样**:不是 `recordWatchSession` 一个方法,而是两个粒度各一个,消掉"同一 flush 两次独立 await 各自 fail-open"(`video_watch_tracker.dart:193-221`,hourly 与 daily 可能不同步丢):
- `recordWatchFlush({title, bookUid, List<(dateKey,hour,ms)> buckets, subtitleChars})` — 同一事务内逐桶写 addVideoWatchStatistic + addVideoHourlyWatchTime,桶归属不变;
- activity 行保持 session 事件语义(stop 时刻),可包成 `recordWatchSessionEnd` 求对称,但**不得**从它派生投影。跨午夜口径差是**故意的**,收敛目标是"每张表的数字来自同一份 split 输出、同一事务",不是三表同源派生。

## 3. 查词/制卡侧——最需要收敛,漂移是确定性的

两表平行写(不在同一事务、各自吞异常):
- 成对写 5 处:`dictionary_page_mixin.dart:505+515`(mixin 入口,video/texthooker 复用)、`reader_fushi/mining.part.dart:386+398`、`fushi/lib/src/lookup/overlay_bridge_handlers.dart:406+409`
- **只写全局漏 per-book(确定性单边偏差)2 处**:`reader_pdf_page.dart:624`、`manga_fushi_page.dart:2757`
- 查词只写 counters 4 处:`base_source_page.dart:1254`、`dictionary_page_mixin.dart:544`、`clipboard_panel_controller.dart:324`、`global_lookup_controller.dart:1068`
- 身份覆写仅 EPUB(`reader_fushi_page.dart:1316`)与视频(`video_fushi_page.dart:1577`),PDF/漫画/texthooker/歌词全落 `''` 桶
- 删除不对称:`core:database_content_misc.part.dart:215/248` 清 counters 立墓碑但**不动 mining_statistics**;恒等式 `MiningStatistics.count == Σ mineCount` 无任何约束/对账,删一本书后永久破裂

**裁定:适合收敛,且是 P4 剩余里收益最高的一块**。加 `recordMiningEvent({sourceType, bookKey, title, at})` 复合入口(同事务 addMiningCount + addMineCountPerBook,dateKey 从 at 派生),PDF/漫画改走它并顺手补书身份(根因修复而非续写单边)。查词侧单表单点,已无漂移,不需复合入口——只需把 dateKey 派生统一到 `statDateKeyOf`。

## 4. ActivityEvents「提升为唯一写入口」的裁定

**文档一句话与代码现实有偏差,不能硬套**。代码真相三条:
1. galgame 域明文反向:"activity_events 是时间线,**不能反过来充当时长统计投影**"(`core:database_statistics.part.dart:547`),事实表是 galgame_sessions;
2. 视频域 activity 行(session 粒度、stop 日归属)**结构性不含**派生桶粒度投影所需的信息——从它派生必引入跨午夜 bug(ed2f36443f 注释写死);
3. 小时桶是 tick 粒度独立测量,与 session 不同构(BUG-892/1052 架构)。

**裁定**:「唯一写入口」的正确读法是 **recordReadingSession 模式的推广**——DB 层复合入口成为各域 session 落库的唯一入口,事务内写 activity 事实行 + 从同一份数字派生投影;而**不是**让投影从 activity_events 表读出来派生(那才是"ActivityEvents 成为事实源"的字面读法,会砸掉三条代码现实)。推荐架构:
- session 事实 = ActivityEvents(read/watch)+ GalgameSessions(game 时长)双事实并存,各管各粒度;
- 投影 = 复合入口内派生(写侧单真相),读侧不变;
- **附带发现的真缺口**:`GalgamePlayTracker` 在 lib 无构造点、`insertGalgameSession` 无生产调用方(我已独立复核)——galgame 时长账本整个没人写,`getActivityDailyTotals(kActivityGame)` 的 duration 恒 0。接线它属于 P4 同族(写入口缺失),但建议独立成任务。

## 5. wire 冻结面(写侧收敛不许碰)

- `StatBucket`:`fushi/lib/src/sync/aggregate_merge_service.dart:171`(纯内存合并载体,非 wire 类型);字段集不一致抛错 `:179-186`。三处字段集 = 事实 wire 契约:reading `aggregate_sync_service.dart:263-275`(charactersRead/readingTimeMs/lastStatisticModified,**pagesRead 刻意不进**,`core:tables.dart:164`)、video `:301-313`、lookup/mining `:448-458`。
- 真 wire 类型:`fushi/lib/src/sync/aggregate_snapshot.dart:17`(7 个 Record 类,version 1,加性兼容规则 `:30-43`)。
- 上行 materialize:`aggregate_sync_service.dart:580`(`_foldVideoStatRows :509`、`_foldHourlyTotals :361`、`_foldLookupMiningRows :547`)。
- MAX-union 落地面:`applySnapshotToLocal :662`(墓碑过滤 `:668-681`,deficit-lift `:710-728`——全仓唯一实现);never-shrinks 保险 `foldIntoLocal :800`。
- 备份合并 SQL 投影:`backup_merge_engine.dart:682-859`。
- **硬约束**:落地面的 `set*` 直写投影**必须保持绕开新复合入口**(sync 落地不得生成 activity 行、MAX 语义不得变累加);上述 fold/merge/apply 一行不动。

## 6. 测试盘点与需新增

已有覆盖(详见列表):`fushi/test/database/reading_statistics_test.dart:270`(recordReadingSession)、`lookup_mining_counters_test.dart`、`video_statistics_test.dart`、`activity_events_test.dart`、`statistics_delete_test.dart:310`(墓碑)、`fushi/test/sync/aggregate_snapshot_test.dart:151`(四不变量)、`aggregate_sync_service_cloud_test.dart:63`(deficit-lift 唯一直测)、`backup_merge_import_test.dart`、`fushi_library_host_service_aggregate_test.dart`(单实现守卫)。

需新增:
1. `recordWatchFlush`:同份桶两表落地、跨午夜桶归属保持、单事务原子性;activity dateKey=stop 日的**刻意差异**断言(防后人"顺手统一");
2. `recordMiningEvent`:两计数同事务、新写入下恒等式成立、PDF/漫画路径走新入口(带身份)定向测试;
3. 源码扫描守卫:lib 下(sync/backup 目录豁免)禁止直调 addReadingStatistic / addMiningCount / addMineCountPerBook / addVideoWatchStatistic / `addActivityEvent(eventType 字面量)`——按仓库纪律做变异实测;
4. sync 落地不产 activity 行的负向断言(applySnapshotToLocal 后 activity_events 行数不变);
5. wire 快照 roundtrip 逐字节不变(现有 aggregate_snapshot_test 已兜,收敛 PR 里跑全量确认)。

## 7. 风险与分期

**可安全落地(不碰 wire)**:
- A1 制卡复合入口 + PDF/漫画补身份——纯写侧,风险最低,收益最高;
- A2 视频 `recordWatchFlush`(桶粒度事务化)+ 可选 `recordWatchSessionEnd`——回调签名改动局限在 tracker 与 video_fushi_page 接线一处;
- A3 守卫测试 + dateKey 派生统一到 `statDateKeyOf`。

**需先拍板再动**:
- B1 galgame 时长账本接线(GalgamePlayTracker 无人构造)——功能缺口非重构,独立任务;
- B2 删除对称性:`deleteActivityEventsForTitle`/`clearAllActivityEvents`(`core:database_statistics.part.dart:370/374`)**零生产调用方**——删书/清统计后首页时间轴仍显示该书事件。行为变更用户可见,需决策;
- B3 备份分类缺口:`backup_service.dart:566-575` `_statisticsTables` 不含 activity_events/galgame_sessions(取消勾选"统计"仍随整库导出);merge-import 静默丢弃这两表(`backup_merge_engine.dart` 零处理,无设计注释,疑似遗漏而非决策)。

**必须停在边界(碰 wire,另行立项)**:StatBucket 字段集任何增减、pagesRead 进 wire、per-uid/bookKey 粒度上 wire、投影表塌缩(接收端物化回事实行 = 重写 aggregate_sync 落地层)、`sync_manager.dart:903` 第二通道的去留。

**侦察副产物**(顺带上报,不属本任务):`deletion_disclosure.dart:50` 自承删书后 reading_statistics/hourly 无人清理;`VideoWatchTracker._flush` fail-open 下 hourly 与 daily 可能不同步丢(`video_watch_tracker.dart:193-221`);texthooker 制卡落 `''` 桶。
