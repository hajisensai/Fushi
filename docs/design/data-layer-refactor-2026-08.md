# 数据层重构 2026-08(审计落地)

审计结论(2026-08-09,schema v75 / 61 表)与逐项处置。原审计六项,经真实代码路径复核后
**两项撤销、两项落地、两项出分期方案**——撤销的两项写明证据,防止后人再拿同样的直觉开工。

## 撤销项(复核后不是 bug,不做)

### A. 「ReadingStatistics 按 title 聚合 = 互串」——撤销

写入方只有三个:`manga_fushi_page` / `reader_fushi navigation.part` / `reader_pdf_page`,
全部是 epub_books 系书籍。书标题在导入时经 `book_title_conflict.dart` 强制去重,且
`bookKey = sanitizeTtuFilename(title)` 对合法标题是单射——**title 与 bookKey 互为双射**,
按 title 聚合与按 bookKey 聚合等价,不存在视频侧 v39 修的那个「同名不同书互串」场景。
SRT 书标题可重复,但 SRT 阅读不写 reading_statistics(无写入方)。加 bookKey 列零增益。

### B. 「MediaItems 是库表的影子表,应塌缩」——撤销

MediaItems 是 jidoujisho 血统「最近打开流」,承载**无库行的在线/外部媒体**
(base64Image/url 载荷是重开的必要数据,不是冗余),喂 `history_reader_page` 与互联
host(`app_model_library_host_service`)。`reader_history/books.part.dart:632` 注释明确
两套 mediaIdentifier 语义刻意分开。塌成 `(mediaType, entryKey, openedAt)` + join 会
直接砍掉在线媒体历史。不动。

## 落地项

### P1. 查词/制卡计数与视频统计的身份残留(v39 的另一半)——schema v76

v39 把 `video_watch_statistics` 从 `{title,dateKey}` 迁到 `{bookUid,dateKey}`(用户拍板
根治同名视频互串),但三处残留:

1. **`lookup_mining_counters` 唯一键 `{title,sourceType,dateKey}` 不含 bookKey**:
   `addLookupCount`/`addMineCountPerBook` 匹配现有行时忽略 bookKey → 同名不同视频的
   查词/制卡计数合进同一行(bookKey 停在先写者)。
2. **`video_stat_aggregates.dart` 展示层按 `s.title` 分组**:v39 只修了存储,统计页至今
   把同名视频合并成一张 tile。
3. **`deleteVideoStatisticsForTitle` 按 title 连坐删**:删 A 视频统计把同名 B 的
   per-uid 行一起删掉。

方案(镜像 v39 全套决策,不发明新形状):

- v76 迁移:`lookup_mining_counters` 表重建(v39 同款 create-copy-drop-rename),
  `book_key` 改 NOT NULL DEFAULT ''(NULL→''),唯一键改
  `{book_key, title, source_type, date_key}`。回填**用库表 JOIN 而非重算函数**:
  book 行按 epub_books.title 唯一匹配取 bookKey,video 行按 video_books.title 唯一
  匹配取 bookUid;同名多行/无匹配保持 ''(读取端按 title 回退,v39 同语义)。
  ''+title 仍在唯一键内 → 遗留行互不合并、no-book 行('' + title='')每日一行不变。
- 写入方:匹配键补 bookKey(null 视作 '');新写入必带身份(书=bookKey,视频=bookUid,
  无书='')。
- sync/备份写回(`setLookupCount`/`setMineCountPerBook`):wire 契约冻结在 title 粒度
  (`LookupMiningRecord.bookKey` 是显式「不参与合并键」的 metadata),落地端镜像
  `setVideoWatchStatistic` 的 v39 决策:删该 (title,sourceType,dateKey) 全部行 → 写单一
  '' 权威行。启用同步的库退化回 title 粒度,与视频统计同为已知限制,不另发明协议。
- 展示层:`video_stat_aggregates` 分组键改 `bookUid ?? title`(遗留 NULL 行按 title
  归属);lookup 计数 tile 同理。
- 删除:视频删除改 per-uid + 该 title 的 NULL 遗留行(遗留行无身份,归属不可判,连坐
  仅限遗留数据并注释说明);墓碑维持 (title, sourceType)——wire 是 title 粒度,更细的
  墓碑对同步复活无判别力,只加假精度。

### P2. Preferences 键收口(不迁移存量,只堵增量)

142 个裸字符串 key 散落全库。全量迁移到类型化门面 = 百文件级机械 churn,与并发 agent
冲突面太大且不消灭任何 bug。做**注册表 + 守卫**:`preference_keys.dart` 枚举全部已知
key(含类型注解),守卫测试扫描源码中的 `getPreference/setPreference` 字面量,不在注册表
里的新 key 报红——存量冻结,增量必须过注册表。凭据类 key(`media_source_secret_*`)
在注册表中单独分组标注红线。

### C. 「5 张标签映射表应合并成一张」——撤销

看似重复,实为**有文档的刻意差异**:`GalgameTagMappings` 注释明写「刻意不带
addedAt——加一个没有消费者的时钟列只会让人误以为它在同步」;`CollectionTagMappings`
同款取舍;epub/video 映射表带 LWW add 时钟因为它们**真的进 sync**。合并成
`(mediaType, entryKey, tagId, addedAt?)` 一张表 = 把三种拍板过的语义差压进一个表里
造特例(addedAt 对 game/collection 无意义、宿主键 int/string 混型、FK cascade 全丢
改手工清孤儿)。仓库已经打过这场官司,别重开。

### D. database.dart God 类拆分(7300 行/~360 方法)——值得做,但推迟到静默点

纯机械(@DriftAccessor 分片 + 门面委托保调用点零改),零行为风险。不现在做的唯一
理由是**调度**:此刻有约 20 个在飞 draft PR,database.dart 是公共热点文件,360 个
方法搬家会让每一个在飞 PR 合并时撞冲突。应在一批 PR 合净后的静默点作为独立 PR
一次做完(先拆 DAO、后收调用点,两步两 PR)。

## 分期项(本轮出方案与骨架,不落地,理由写死)

### P3. 书身份 bookKey(=sanitized title)→ 稳定 uid

不落地的硬理由:
- sync `assetKey` / 备份合并自然键 / 互联 wire 全部冻结在 sanitize(title) 上,本地 PK
  换 uid 必须保持这些通道 title 粒度不变 → 需要「本地 uid + wire 仍走派生 key」的双层
  设计,牵 ~10 张 FK 表 + extractDir 磁盘布局 + 数百调用点。
- v76 式一步迁移做不到:content-hash 回填要逐书读文件,GB 级库在 onUpgrade 里静默卡启动,
  需要进度 UI(独立工程)。
- 当前模型是**自洽的**:导入期强制标题去重 + display_title 展示/身份分离 + 远端下载改键
  迁移,丑但没有活 bug。换句话说这是债,不是火。

分期骨架(后续任务按此执行):
1. Stage 1:EpubBooks 加 `uid` 列(导入时生成,迁移回填随机 uid),**同 PR 内**把
   ReaderPositions/Bookmarks/RevealedImages/BookCustomCss 的读写切到 uid(FK 重建),
   bookKey 降级为 sync/备份专用派生属性。
2. Stage 2:ShelfEntries/MediaCollectionItems entryKey 换 uid(含远端下载改键路径删除)。
3. Stage 3:sync 协议升级 per-uid(对端能力协商,旧端回退 title)。

### P4. 统计投影表塌缩为事实表

不落地的硬理由:`StatBucket` wire 要求两端字段集一致(加减字段互抛错),投影表是
MAX-union 同步的落地面;塌缩后接收端必须把 title 粒度快照物化回事实行(现有
deficit-lift 的推广),等于重写 aggregate_sync 落地层。`galgame_sessions` 的「刻意无
投影」哲学是对的,但它**不进 sync**——书/视频统计进,这是本质差别。分期:先把
`ActivityEvents` 提升为唯一写入口、投影表改由事实表派生(写侧单真相),wire 端不动;
协议升级另行立项。

## 验证

- v76 迁移测试(migration_v76_lookup_counter_identity_test.dart):旧 schema 造数
  (同名双视频计数合并行、NULL bookKey、no-book 行)→ 升级 → 断言回填/键形/不丢行。
- lookup_mining_counters_test.dart 补:同名双视频各记各行;'' 权威行覆写语义。
- 展示层分组:video_stat_aggregates 单测(同名双视频两张 tile,NULL 遗留行按 title 归属)。
- 守卫:preference_keys 注册表守卫变异实测(往源码塞新 key 字面量 → 守卫红)。
- 全量 `flutter analyze` + `dart run tool/flutter_test_failures.dart --no-pub`。
