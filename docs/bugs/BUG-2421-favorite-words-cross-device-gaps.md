## BUG-2421 · 收藏的单词跨端看不到：wire 丢归属 + 云同步绑死统计开关 + 备份按统计表删除
- **报告**：2026-09-10（用户：「两端收藏的单词看不到」。表述含糊，未说明是在哪个页面找、两端各指哪两端——**待用户补一张截图确认**，见下方「待确认」。）
- **真实性**：⚠️ 部分确认。**「本端收藏后本端看不到」没有证据**：收藏夹页 `collections_page.dart:326` 走 `db.getAllFavoriteWords()`，**零过滤**（无 profile / 语言 / 来源 / 软删除条件，BUG-462 当年就是补这条），落行 `:398-414`，无 `bookKey`/`title` 的行进「未归合集」平铺**不会被隐藏**；`FavoriteWords` 表（`tables.dart:714-737`）本身也没有 profile 列、语言列或 `deletedAt` 列。三个写入点（`base_source_page.dart:1395`、`dictionary_page_mixin.dart:622`、`overlay_bridge_handlers.dart:277`）都写同一个 `appModel.database`。
  但沿同步/备份链路查出**三个真实缺口**，任何一个都能让用户说出「收藏的单词看不到」：
  - **缺口 A（最可能命中）：同步 wire 丢 `bookKey`/`title`。** `FavoriteWordRecord`（`aggregate_snapshot.dart:504-533`）只带 6 个字段，没有归属两项；回灌 `aggregate_sync_service.dart:1145-1151` 调 `addFavoriteWord` 也不传 → 对端落库的行 `bookKey=null, title=''`。后果：统计页那本书/那个视频的「收藏 N」**永远是 0**（`stat_shared.dart:665-667` 把空 title 的行直接 `continue` 跳过），收藏夹里这些词也全部掉进「未归合集」、没有媒体节头。用户按书/视频维度找自己收藏的词 → 看不到，尽管总表里其实在。
  - **缺口 B：云通道的收藏同步被绑死在「同步统计」开关上。** `sync_orchestrator.dart:697` 条件是 `syncStats && deviceId.isNotEmpty`，注释明写「复用 syncStats 开关」；而互联通道 `:689` 是 `syncStats || syncFavorites`。**用户只要关过「同步统计」，云端收藏词一条都不走**，UI 上没有任何地方提示收藏跟着统计一起停了。
  - **缺口 C：备份把 `favorite_words` 归类成统计表。** `backup_service.dart:574-581` 的 `_statisticsTables` 含 `favorite_words`，导出/导入时不勾选 statistics 类别 → **整表 DELETE**。而同为用户收藏内容的 `favorite_sentences` 被明确 gate 在 `books`（`:600` 注释：favorites content, gated on `books`）。同一类内容两种归属，且与 `database_content_misc.part.dart:459,624` 里「绝不触碰用户内容：收藏词/句」的原则直接矛盾。走备份迁移到另一端的用户会整批丢收藏词。
  - **顺带一个数据正确性欠账**：`addFavoriteWord`（`database_statistics.part.dart:869`）硬写 `createdAt: DateTime.now()`，丢弃 peer 传来的 `r.createdAt`。收藏夹按 createdAt 倒序、统计按 dateKey 分桶，同一个词在两端的「收藏时间」于是不一致；而它还是「删除 vs 重新收藏」的仲裁判据（`aggregate_sync_service.dart:1139-1142`、`filterTombstoned :324-340`），被本机 now 顶掉会让墓碑仲裁语义漂移。
  - 另注：galgame 浮动词典收藏恒写 `kStatSourceBook` 且不传 `bookKey`/`title`（`overlay_bridge_handlers.dart:275-307`，为与书内收藏共享唯一键），这些词在按媒体找时同样找不到——与缺口 A 同形，但成因是本地的、不是同步。
- **[ ] ① 未修复** — 已定位未动手。四条互相独立的最小修复方向：
  1. `FavoriteWordRecord` 补 `bookKey`/`title` 两个可选字段（老端解 JSON 缺键回退 null/''，向后兼容），回灌时透传给 `addFavoriteWord`——一处 wire + 一处 apply，消除「跨端来的收藏没有归属」这个特殊情况。
  2. 把 `favorite_words` 从 `_statisticsTables` 移到内容侧，与 `favorite_sentences` 同一档（gate 在 `books`）。
  3. 云通道给收藏解绑 `syncStats`：`sync_orchestrator.dart:697` 改用 `syncFavorites`，`sync_auto_trigger.dart:296` 云通道读独立键（缺键继承旧值，沿用互联那套 `_interconnectAggregateFlag` 的继承纪律，不复位存量用户）。
  4. `addFavoriteWord` 增加可选 `createdAt`，同步回灌传 peer 的值，本地收藏路径不传即保持 `now()`。
- **[ ] ② 未加自动化测试** — 随 ① 一起补：wire 往返必须保住归属（缺口 A）、不勾统计的备份不得删 `favorite_words`（缺口 C）、关统计不得停收藏同步（缺口 B）。
- **待确认（阻塞 ① 的优先级排序，不阻塞修复本身）**：请用户补一张截图 + 说明是在**哪个页面**找不到（收藏夹总表 / 统计页的 per-book「收藏 N」/ 书内某处），以及「两端」具体指哪两端、走的是云同步还是局域网互联。三个缺口都该修，但先修哪个取决于他实际撞的是哪一个。
