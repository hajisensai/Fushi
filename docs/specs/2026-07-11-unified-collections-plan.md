# 统一合集系统（Jellyfin 式）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 本文件是 **master plan**：Phase 1 已按 bite-sized 任务展开到可直接执行；Phase 2–6 定义了文件、行为契约与关键签名，**每个 phase 开工前必须先用 writing-plans skill 展开成同粒度的子计划**（单独文件放本目录），再执行。这是 writing-plans 的 Scope Check 条款对多子系统大改的标准处理。

**Goal:** 砍掉手动「系列」系统与 playlistJson 内嵌多集模型，换成 Jellyfin 式统一合集：书籍/视频共用「容器 + 成员引用」模型，播放列表也是合集（有序），多集视频每集拆成独立库条目。

**Architecture:** 新增两张表 `MediaCollections`（容器：collection=无序跨媒体 / playlist=有序）+ `MediaCollectionItems`（成员引用，复合 PK 允许一条目属于多个合集，删容器 cascade 只删引用不删条目）——照抄 Jellyfin 的 BoxSet/Playlist「一切皆 item + LinkedChildren」模型。schema v37→v38 迁移把旧 Series 转成 collection、把每条多集 VideoBooks 行拆成 N 条独立行 + 一个 playlist 合集，并改写收藏句/制卡的集坐标。UI 层一套 Jellyfin 式合集详情页（头部元数据 + Play/继续 + 成员区按类型分派：playlist=可拖拽有序列表点行连播，collection=按媒体类型分组网格），库网格里合集折叠成卡（复用现有文件夹式封面堆叠 + playlist 用 2×2 拼贴）。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12 / Drift（schema v38）/ Riverpod / Slang i18n（改 key 必须走 `hibiki/tool/i18n_sync.dart`）

---

## 实现进度

- **Phase 1（DB 基建）✅ 已实现**（commit `86301329e`，PR #27）。全量 `flutter analyze`（lib+test）clean、`flutter test` 全绿。
  - **phasing 修正**：Phase 1 改为**纯 additive**——不删旧 Series DAO / `setSeriesForEntry` / `playlistJson`（UI 仍在用，删了编译不过、CI 红）。删除挪到 Phase 6（UI 迁移后）。
  - **`collection_grouping.dart` 延到 Phase 4**：其接口取决于 Phase 4 UI 消费方，提前按猜测建抽象是 YAGNI 反模式。`collection_continue.dart` 已实现（契约明确）。
  - **对抗审查（4 镜头）修掉 9 处迁移缺陷**：①completedAt 不照抄每集（避免未看集标完成+完成数 N 倍膨胀）②created_at 秒→毫秒（drift DateTime 默认秒）③favorite 改写去掉 source!='video' 假阴性 ④拆集先于系列转换（playlist-in-series 提顶层，非孤儿）+ 空系列不建空合集 ⑤legacy playlist 当前集续播点从 parent.last_position_ms 兜底 ⑥cover_path 第 0 集承接 ⑦JSON 字段软转防砖 ⑧favorite 改写并入拆集同一事务（原子性）⑨迁移测试补真越界/负数/无 source 收藏/legacy 兜底覆盖。
  - **迁移 DAO 契约微调**：`deleteMediaCollection` / `removeFromCollection` / `removeEntryFromAllCollections` 显式删成员不依赖 FK cascade（测试 FK OFF 与生产 FK ON 行为一致）。`splitPlaylistVideoBooksV38` 顶部 `_columnExists('video_books','playlist_json')` 守卫（极简测试种子缺列不崩）。
- **Phase 2（导入流）✅ 已实现**（commit `f3a302830`，PR #27）。全量 `flutter analyze`（lib+test）clean、`test/media/video`+`test/media/source` 1508 绿。
  - `VideoBookRepository.importSplitPlaylist`：导入拆集单一真相源，与 v38 迁移落库形状字节对齐（每集独立行 + playlist 合集 + 首集承接封面 + 整批一事务）。对话框（m3u8 手动/拖入、文件夹扫描）+ 来源扫描器都改走它。
  - `deleteVideoBook` 顺带 `removeEntryFromAllCollections('video', uid)`（删集清合集引用、移空自删）。
  - 扫描器判重：`playlistBookUid` 单行存在 → 同名 playlist 合集存在（basename 派生，同旧碰撞语义，且不随 manifest 集路径编辑而变 → 重扫幂等）；源码守卫同步更新。
  - **已知中间态（feature 分支可接受）**：导入的 playlist 合集在库页**尚不显示**（home_video_page `_loadVideoOrder` 仍读旧 `getAllSeries`，未读 `getAllMediaCollections`），多集导入后暂时表现为 N 张散集卡 + 一个隐藏合集。Phase 4 接库页读合集 + 折叠后恢复。
- **Phase 3（播放器）✅ 已实现**（commit `07a1f9dee`，PR #27）。全量 `flutter test` **10770 绿**、`flutter analyze`（lib+test）clean。
  - 落地了下面「pushReplacement 低风险架构」：player 加 `playlistCollectionId`；`_init` 从 `getCollectionItems` 建 `_episodes`(`_PlaylistEpisodeRef`) + 当前集照 `_loadSingle` 加载；本地换集 = pushReplacement 到兄弟集单视频页（`widget.bookUid` 恒当前集，整套单视频机制 0 处改）；`_persistPosition` 恒单视频；收藏/制卡 `sectionIndex` 走 `_favoriteSectionIndex`（本地 null / 远端多集 `_currentEpisode`）；`VideoEpisodePanel` 改 `episodeTitles`；删死方法 `_loadEpisode`/`_encodeEpisodes`；6 处源码守卫更新到新模型。收藏跳回 `collections_page` 免改。
  - **⚠️ 待真机验证**：pushReplacement 换集的 media_kit/WebView 生命周期顺滑度（铁律）。Phase 4 接库合集卡+详情页 → 传 `playlistCollectionId` 后可端到端真机验证。
  - **踩坑记录**：python 文本模式写文件在 Windows 会把 LF 变 CRLF，`dart format` 保留既有 EOL 不纠正 → 本地工作副本 CRLF 让读源码的 `\n` 守卫本地假红（但 `.gitattributes text=auto eol=lf` 让 git 存 LF，CI 实为绿）。以后 python 改文件用二进制写或写后 `sed -i 's/\r$//'`。database.dart 是 git-binary(NUL字节 CRLF)不参与 eol 归一，勿转 LF。
- **Phase 4（库UI+合集详情页）/ 5（远端+同步备份）/ 6（清理+守卫）：未实现，spec 已就绪**（见计划 §4 各 Phase）。
  - 已完成 Phase 3/2 的实现就绪 recon spec（当前代码 file:line + 改造点），Phase 3 见本会话调查（player `_init`/`_episodes`/`_persistPosition`/`_loadEpisode`/`episode.part`/`video_episode_panel`/`collections_page` resolve/`lookup_favorite`+`lookup_mining`/cue 路径全部锚点）。
  - **为何暂缓**：Phase 3 改的是 ~2900 行 WebView2/media_kit 播放器 god-file 的每集模型（进度/字幕/音轨/延迟/cue/收藏/制卡键全部从 playlistJson 转合集成员行），Phase 4 加新详情页 + 库网格折叠；二者**强耦合**（Phase 4 折叠前无人给 player 传 playlistCollectionId，单独任一phase不可端到端验证），且都属项目铁律「播放/布局改动声明修好前必须真机复测留证据」。应作为**带真机验证的专门 session**逐 phase 落地（player 换集/续播/连播/剧集面板/收藏跳转 + 库合集卡/详情页 Jellyfin 展示），不宜一次性盲写堆叠未验证的 god-file 改动。
  - **Phase 3 架构已定（读码后关键 breakthrough，execution-ready）**：
    - **实测 blast radius**：`widget.bookUid`（=当前活动视频键）在 player + parts 里出现 **50 处**（subtitle.part 13 / lookup_favorite 6 / danmaku 3 等）。若用「原地换集 + `_activeBookUid` 影子」需改这 50 处 → god-file 高风险且无法全真机验证。
    - **决策：`pushReplacement` 换集**——每个本地集就是它自己那条 VideoBooks 行的一个**单视频页**；换集 = `Navigator.pushReplacement` 到兄弟集的新 VideoHibikiPage（带同 `playlistCollectionId`）。于是 `widget.bookUid` 到处都仍指「当前集」，**整套单视频 load/cue/收藏/制卡/持久化机制原样复用、0 处改动**（blast radius 50→~0）。远端播放列表保持原地（host 驱动 episodeIndex，不走 pushReplacement）。代价：换集是整页重建（媒体 controller 重建，有一次短暂过场），比原地 `controller.load` 略不顺——可接受，且真机验证后可再优化。auto-advance 到已看过的下一集会从其保存位续播（旧策略是从 0）——细微差异，记录。
    - **改动清单（execution-ready）**：① 加 `playlistCollectionId:int?` 到 VideoHibikiPage + `.remote`/`neutralized`/`neutralizedRemote`；② repo 加直通 `getCollectionItems`/`getMediaCollectionById`；③ `_episodes` 类型 `List<PlaylistEntry>`→新 `List<_PlaylistEpisodeRef>{bookUid?,title,path}`（local: 从 `getCollectionItems`→逐个 `getByBookUid` 成员行建；remote: info.episodes 建，bookUid=null）；④ `_init` 播放列表分支：本地读集合成员建 `_episodes` + `_currentEpisode`=`indexWhere(bookUid==widget.bookUid)` + `_playlistTitle`=合集名，然后**照单视频 `_loadSingle(row)` 加载当前集**（删 playlistJson 解析 + `_loadEpisode` 本地路径）；⑤ `_switchEpisode` 本地分支→pushReplacement（先 `_persistPosition(widget.bookUid,curPos)` 落当前集，再 replace）；⑥ `_persistPosition` 本地恒单视频（删 `updateEntryPosition`+`updatePlaylistJson`+`_encodeEpisodes`）；⑦ `nextPlaylistIndexAfterCompletion(_episodes,cur)` 改签名 `(int count,int cur)` 或内联；prewarm 用 `_episodes[next].path`；⑧ `VideoEpisodePanel` 参数 `episodes:List<PlaylistEntry>`→`episodeTitles:List<String>`（只用 .title）；⑨ lookup_favorite/mining `sectionIndex`：本地恒 null（每集独立=单视频语义）/远端多集用 `_currentEpisode`；`bookKey` 仍 `widget.bookUid`（已是当前集 uid）；⑩ 删 `_loadEpisode`（本地不再用）；`updateCurrentEpisode` 本地不再调；⑪ 测试：video_episode_panel/auto_advance/m3u8_playlist(nextIndex 签名)/video_favorite_open_target 等更新。
    - **收藏跳回 collections_page 免改**：迁移已把视频收藏 bookKey 重写成**集 uid**（各集是单视频行、playlistJson=null）→ `resolveVideoFavoriteAudioClip`/`OpenTarget` 走 `episodeCount<=0` 单视频分支、用 `row.videoPath` 直指该集文件，天然正确，Phase 3 不改（Phase 4 可选给它补 `playlistCollectionId` 让跳回也带面板）。
  - **未直接下手码的原因**：`pushReplacement` 换集的媒体 controller / WebView 生命周期跨路由替换的顺滑度**必须真机（Windows 离屏 / 安卓模拟器）复测**才能声明可用（铁律）；且 Phase 3+4 强耦合需一并验证。架构既定，实现是机械照做 + 真机验证，宜作专门 session 一次跑完不留半截 god-file。

## 0. 已拍板的用户决策（2026-07-11）

| # | 决策 | 用户选择 |
|---|---|---|
| D1 | 砍掉 Series/ShelfEntries.seriesId 系列系统，换 Jellyfin 式引用表 | ✅ 确认（「那套系统不好，我要砍掉」） |
| D2 | 旧系列数据处理 | ✅ 迁移成合集（成员关系照搬） |
| D3 | 多集视频模型 | ✅ 拆，每集独立条目；播放列表=引用容器 |

## 1. 目标 / 非目标

**目标**
1. 书籍（epub/srt）和视频共用同一套合集系统；播放列表是 `collectionType='playlist'` 的合集。
2. Jellyfin 式展示：库网格合集卡（拼贴/堆叠封面 + 数量角标）→ 详情页（封面头部 + 播放/继续 + 成员列表）；playlist 成员点任意一行从该行连播。
3. 管理入口收敛：条目长按/批量多选 →「添加到合集」对话框（下拉选已有，首项新建）——照抄 Jellyfin collectionEditor 模式；保留书架现有拖拽合并手势（后端从建 Series 换成建 collection）。
4. 拆集后消灭双轨特例：所有视频行统一用 `lastPositionMs` 进度、统一走单视频 cue 落库路径、`completedAt`/观看统计天然变成每集粒度（顺带修掉「整季时长记到首开集标题」的既有统计 bug）。

**非目标（v1 明确不做）**
- 嵌套合集（合集装合集）。迁移遇到「播放列表本身在系列里」的行：拆出的 playlist 合集提到顶层，原系列失去该成员（迁移日志记录）。
- 合集级标签（迁移时把播放列表行的标签映射复制到每集行上，标签筛选行为不变）。
- Shuffle 随机播放、合集封面上传自定义（只支持「选某成员作封面」= `coverSource`）。
- FavoriteWords（收藏词）无集维度，历史行的 `bookKey` 指向已删除的整季 uid，不迁移（只影响 per-book 统计聚合，不影响功能）；文内记录为已知残留。

## 2. 数据结构（先把数据定对）

### 2.1 新表（`packages/hibiki_core/lib/src/database/tables.dart` 末尾追加）

命名用 `MediaCollections` 而非 `Collections`——现有 `CollectionsPage` 是「收藏内容」页（书签/收藏句/制卡/收藏词），必须避开撞名。

```dart
/// 统一合集（Jellyfin BoxSet/Playlist 式容器）。取代旧 Series 表 +
/// ShelfEntries.seriesId（两者自 v38 起冻结为遗留残留，勿再读写）。
/// collection = 无序跨媒体合集（展示时按成员 sortIndex → importedAt 排序）；
/// playlist   = 有序播放列表（sortIndex 即播放序，点任一成员从该处连播）。
@DataClassName('MediaCollectionRow')
class MediaCollections extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// 'collection' | 'playlist'
  TextColumn get collectionType =>
      text().withDefault(const Constant('collection'))();

  /// 自定义封面成员：'mediaType|entryKey'；null = 自动
  /// （playlist 取前 4 成员封面 2×2 拼贴；collection 取首成员封面堆叠）。
  TextColumn get coverSource => text().nullable()();

  /// 合集卡自身在库网格中的排序权重（与散条目同层混排，语义同旧 Series.sortOrder）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
}

/// 合集成员引用（Jellyfin LinkedChildren）。复合 PK 按合集去重：同一条目
/// 可以属于多个合集；删合集 cascade 只删引用行，绝不删条目本身。
@DataClassName('MediaCollectionItemRow')
class MediaCollectionItems extends Table {
  IntColumn get collectionId => integer()
      .references(MediaCollections, #id, onDelete: KeyAction.cascade)();

  /// 'epub' | 'srt' | 'video'（同 ShelfEntries.mediaType 值域）。
  TextColumn get mediaType => text()();

  /// 逻辑外键：epub=bookKey / srt=uid / video=bookUid。不加 DB FK——
  /// 与 ShelfEntries.entryKey 同理由（远端条目无本地行）。
  TextColumn get entryKey => text()();

  /// 合集内序：playlist 的播放顺序 / collection 的展示顺序。
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {collectionId, mediaType, entryKey};
}
```

### 2.2 旧结构处置（Never break userspace：无损冻结，不 DROP）

- `Series` 表、`ShelfEntries.seriesId` 列：**物理保留、代码冻结**（同 ttu 残留惯例）。表定义加注释标注 v38 起废弃；删除 Series 的全部 DAO 方法（`createSeries`/`updateSeriesName`/`updateSeriesSortOrder`/`deleteSeries`/`getAllSeries`/`getSeriesById`/`getShelfEntriesBySeries`）与 `setSeriesForEntry`。
- `ShelfEntries` 的 **sortOrder 职责保留**（书架/视频库自定义排序真相源不变）：`getAllShelfEntries`/`batchUpsertShelfOrder`/`deleteShelfEntry`/`migrateShelfEntryKey` 保留，`migrateShelfEntryKey` 不再搬 seriesId。
- `VideoBooks.playlistJson`/`currentEpisode` 列：物理保留、迁移后置 NULL/0、代码冻结（v38 后不再有 episodeCount≥2 的行）。

### 2.3 每集拆分的身份派生（纯函数，落 `hibiki_core`）

现有 `singleVideoBookUid`/`uniqueVideoBookUid` 在 app 层（`video_import_dialog.dart`），迁移在 core 层跑，把派生逻辑下沉成 core 单一真相源，app 层改为委托：

```dart
/// packages/hibiki_core/lib/src/utils/video_book_uid.dart（新文件）
/// 单视频 bookUid：'video/<sanitize(文件名去扩展名)>'。与旧 app 层实现逐字一致。
String coreSingleVideoBookUid(String filePath);

/// 冲突去重：已占用则加 ' (2)' / ' (3)' 后缀。[taken] 为现存 uid 集合。
String coreUniqueVideoBookUid(String base, Set<String> taken);
```

### 2.4 「继续看」推导（无新增状态，纯函数）

不给合集加 currentEpisode 类指针列（消灭状态同步问题），照 Jellyfin Next-Up 语义按成员数据推导：

```dart
/// hibiki/lib/src/media/collections/collection_continue.dart（新文件）
/// 规则：取排序位置最靠后的「有痕迹」成员（有进度或已完成）；
/// 它已完成→下一个（没有下一个就它自己）；全无痕迹→第 0 个。
int continueMemberIndex(List<({int? positionMs, bool completed})> members) {
  int last = -1;
  for (int i = 0; i < members.length; i++) {
    if (members[i].completed || (members[i].positionMs ?? 0) > 0) last = i;
  }
  if (last == -1) return 0;
  if (members[last].completed && last + 1 < members.length) return last + 1;
  return last;
}
```

### 2.5 折叠归属规则（条目可属多合集时库网格折进哪张卡）

Jellyfin 不折叠（合集独立 tab），Hibiki 书架/视频库必须折叠（否则一季 12 集刷屏）。规则（纯函数 + 单测）：**条目折进包含它的 id 最小的合集卡**；其余合集卡照常显示、详情页照常含该条目。合集卡出现在某 surface（书架/视频 tab）的条件：**含 ≥1 个该 surface 媒体类型的成员**（跨媒体合集两边都出现）。

## 3. Schema v38 迁移设计

`database.dart` 迁移阶梯追加（全部 `_tableExists`/`_columnExists` 幂等守卫，只建表/改写数据，不 DROP）：

```dart
if (from < 38) {
  // 1) 建新表
  if (!await _tableExists('media_collections')) {
    await m.createTable(mediaCollections);
  }
  if (!await _tableExists('media_collection_items')) {
    await m.createTable(mediaCollectionItems);
  }
  // 2) Series → collection（名称/排序/建时照搬；成员按旧 sortOrder 转 sortIndex）
  await migrateSeriesToCollectionsV38();
  // 3) 拆多集：每条 playlistJson 行 → N 条独立行 + 1 个 playlist 合集，
  //    并改写 mined_sentences / preferences.favorite_sentences 的集坐标
  await splitPlaylistVideoBooksV38();
}
```

### 3.1 `migrateSeriesToCollectionsV38()`（database.dart 内私有，幂等）

- `SELECT * FROM series ORDER BY id`；对每行 `INSERT INTO media_collections(name, collection_type, sort_order, created_at) VALUES (name, 'collection', sort_order, created_at)`。
- `SELECT media_type, entry_key, sort_order FROM shelf_entries WHERE series_id = ? ORDER BY sort_order, entry_key` → 逐条 `INSERT INTO media_collection_items(..., sort_index = 枚举序)`。
- 幂等锚：迁移开始前若 `media_collections` 非空则跳过（v38 只会跑一次；防重入靠这个 + from<38 门槛）。
- 迁移后把 `shelf_entries.series_id` 全置 NULL（数据层面完成「砍」，列物理保留）。

### 3.2 `splitPlaylistVideoBooksV38()`（核心拆集，database.dart 内私有）

对 `SELECT * FROM video_books WHERE playlist_json IS NOT NULL`，解析 JSON，`entries.length >= 2` 的每行：

1. **建集行**：第 i 集 →
   - `bookUid` = `coreUniqueVideoBookUid(coreSingleVideoBookUid(entry.path), taken)`（taken=全库现存 uid + 本次已分配）；
   - `title=entry.title`，`videoPath=entry.path`，`lastPositionMs=entry.positionMs`，`importedAt=parent.importedAt + i`（保持排序稳定），`coverPath=null`（懒提取，见 Phase 2），`subtitleSource`/`secondarySubtitleSource`/`subtitleFormat`/`embeddedSubtitleTrack`/`audioTrackId`/`delayMs` 照抄 parent（原本就是各集共享一列），`sourceId` 照抄，`playlistJson=null`，`currentEpisode=0`；
   - `completedAt = parent.completedAt`（**全部集照抄**：旧完成标记本来就是整本粒度，用户看到的「已完成」状态迁移后不回退——保用户可见状态优先于语义精确）。
2. **建 playlist 合集**：`name=parent.title`，`collection_type='playlist'`，`created_at=parent.importedAt`，`sort_order=` parent 的 `shelf_entries.sort_order`（无行则 0）；成员= N 集按序 `sort_index=i`。
3. **改写集坐标引用**：
   - `mined_sentences`：`WHERE book_key = parentUid AND section_index = i` → `book_key = episodeUid[i], section_index = 0`；`section_index IS NULL`（旧数据）→ 归到 `episodeUid[parent.currentEpisode]`。
   - `preferences` 表 `favorite_sentences` JSON（收藏句在 Preferences 不在表）：逐条 `bookKey==parentUid` → `bookKey=episodeUid[sectionIndex.clamp(0,N-1)], sectionIndex=0`。
   - `video_book_tag_mappings`：parent 的每条映射复制到全部 N 个集行（唯一约束冲突 INSERT OR IGNORE）。
   - `audio_cues`：**无需迁移**（播放列表 cue 从不落库——盘点确认）。
   - `favorite_words` / `lookup_mining_counters` / `video_watch_statistics`：不迁移（无集维度/按 title 聚合，见非目标）。
4. **删 parent 行**（cascade 掉旧标签映射）+ 删 parent 的 `shelf_entries` 行。
5. parent 若有 `series_id`：拆出的 playlist 合集提顶层，不注入原系列对应的 collection（非目标·嵌套），迁移日志记一行。

### 3.3 迁移测试（`packages/hibiki_core/test/migration_v38_collections_test.dart` 新文件）

- 夹具：v37 库预置 1 个 Series（2 本 epub + 1 个视频）+ 1 条 3 集 playlistJson 行（各集不同 positionMs、parent 有 completedAt、2 条 mined_sentences 分属第 0/2 集、收藏句 JSON 2 条、1 条标签映射、shelf_entries 带 sortOrder/seriesId）。
- 断言：升级到 v38 后——series 成员如数进 collection；3 条新视频行身份/进度/completedAt/importedAt 递增正确；playlist 合集成员序正确；mined_sentences/收藏句 bookKey+sectionIndex 改写正确；标签映射×3；parent 行与其 shelf_entries 行消失；重复升级幂等（跑两遍结果一致）。
- 既有 `migration_test.dart` 的 v30 断言（`getAllSeries` 等）随 DAO 删除改为 raw SQL 断言或删除。

## 4. 分阶段任务

### Phase 1 — DB 基建（表 + 迁移 + DAO + 纯函数）【已展开，可直接执行】

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/tables.dart`（追加 §2.1 两表；Series/ShelfEntries.seriesId/playlistJson/currentEpisode 加废弃注释）
- Modify: `packages/hibiki_core/lib/src/database/database.dart`（schemaVersion 37→38；§3 迁移；新 DAO；删 Series DAO）
- Create: `packages/hibiki_core/lib/src/utils/video_book_uid.dart`（§2.3）
- Create: `hibiki/lib/src/media/collections/collection_continue.dart`（§2.4）
- Create: `hibiki/lib/src/media/collections/collection_grouping.dart`（§2.5 折叠归属纯函数，改造自 `shelf_ordering.dart` 的 `groupAndSortShelfEntries`：分桶键从 seriesId 换成「id 最小的所属合集」）
- Test: `packages/hibiki_core/test/migration_v38_collections_test.dart`、`packages/hibiki_core/test/video_book_uid_test.dart`、`hibiki/test/media/collection_continue_test.dart`、`hibiki/test/media/collection_grouping_test.dart`

**新 DAO（database.dart，签名清单——实现按仓库既有 Series 段风格写）：**

```dart
Future<List<MediaCollectionRow>> getAllMediaCollections();
Future<MediaCollectionRow?> getMediaCollectionById(int id);
Future<int> createMediaCollection(String name,
    {String collectionType = 'collection'});
Future<void> renameMediaCollection(int id, String name);
Future<void> updateMediaCollectionSortOrder(int id, int sortOrder);
Future<void> updateMediaCollectionCover(int id, String? coverSource);
Future<void> deleteMediaCollection(int id); // cascade 清成员引用
Future<List<MediaCollectionItemRow>> getCollectionItems(int collectionId);
Future<Map<String, int>> getPrimaryCollectionIdByEntry(); // '<mediaType>|<entryKey>' → 最小 collectionId（折叠用，单查询 GROUP BY MIN）
Future<void> addToCollection(int collectionId, String mediaType,
    String entryKey); // sortIndex = 尾插；重复 INSERT OR IGNORE
Future<void> removeFromCollection(int collectionId, String mediaType,
    String entryKey); // 移空后自动删合集（沿用旧 removeEntryFromSeries 语义）
Future<void> reorderCollectionItems(int collectionId,
    List<({String mediaType, String entryKey})> ordered);
Future<void> removeEntryFromAllCollections(String mediaType, String entryKey); // 删条目时清引用（挂进 deleteVideoBook/deleteEpubBook/deleteSrtBookByUid/deleteAudiobookByBookKey 四处既有 deleteShelfEntry 旁）
```

**Steps（TDD，每步一动作）：**
- [ ] 写 `video_book_uid_test.dart`（uid 派生 = 旧 `playlist_book_uid_test.dart`/`video_book_uid_test.dart` 同款断言 + 去重后缀）→ 跑失败 → 实现 `video_book_uid.dart` → 跑过 → commit
- [ ] 写 `collection_continue_test.dart`（空/全新/中途/末尾完成/全完成 5 用例）→ 失败 → 实现 → 过 → commit
- [ ] tables.dart 加两表 + 废弃注释；database.dart 注册表、schemaVersion=38、空迁移块 → `dart run build_runner build` → commit
- [ ] 写 `migration_v38_collections_test.dart`（§3.3 夹具+断言）→ 失败 → 实现 `migrateSeriesToCollectionsV38` + `splitPlaylistVideoBooksV38` → 过 → commit
- [ ] 新 DAO 方法 + 对应 DAO 测试（`media_collections_dao_test.dart`：CRUD/尾插/移空自删/多合集归属/reorder）→ 过 → commit
- [ ] 写 `collection_grouping_test.dart`（改造自 `shelf_ordering_test.dart`：折叠归属最小 id 规则 + surface 过滤）→ 失败 → 实现 `collection_grouping.dart` → 过 → commit
- [ ] 删 Series 全部 DAO + `setSeriesForEntry`；`migrateShelfEntryKey` 去 seriesId 搬运；修 `shelf_entries_test.dart`/`migration_test.dart` → 全包 `flutter test` 过 → commit

### Phase 2 — 导入流（多集导入产出拆分行 + playlist 合集）

**Files:** `hibiki/lib/src/media/video/video_import_dialog.dart`（`_importPlaylistFromPath`/`_importGroup` 多集分支重写）、`hibiki/lib/src/media/source/media_source_scanner.dart:596-669`（`_importPlaylists` 同步改）、`hibiki/lib/src/media/video/m3u8_playlist.dart`（`parseM3u8` 保留；`PlaylistEntry.positionMs`/`updateEntryPosition`/`nextPlaylistIndexAfterCompletion` 等进入淘汰清单）。

**行为契约：** m3u8/文件夹/扫描器导入多集 → 每集一条 VideoBooks 行（uid=core 派生；逐集 `extractVideoCover`，超过 8 集只同步提取前 8 张、其余留 null 由库页懒补）+ 一个 playlist 合集；单集导入不变；去重键从 `playlistBookUid` 换成「同名 playlist 合集已存在 → 增量补新集尾插」。外部拖字幕到集卡走单视频 attach 路径（`video_subtitle_attach.dart` 的 playlistNeedsPlayer 拒绝分支删除）。

### Phase 3 — 播放器（合集驱动的换集）

**Files:** `video_hibiki_page.dart`（`_init`/`_loadEpisode`/`_persistPosition`/`_episodes` 状态源）、`video_hibiki/episode.part.dart`（换集/自动连播/剧集面板）、`video_episode_panel.dart`（数据源从 `PlaylistEntry` 换成成员行描述符）、`home_video_page.dart` `_open`、`collections_page.dart` 视频收藏跳转（`resolveVideoFavoriteOpenTarget`/`resolveVideoFavoriteAudioClip` 大幅简化——bookUid 直指文件，episodeIndex 维度消失）。

**行为契约：** `VideoHibikiPage` 增加可选 `playlistCollectionId`；有则从 `getCollectionItems` 加载成员行做集列表（`_episodes` 语义改成员描述符 `{bookUid,title,path,positionMs=row.lastPositionMs,completed}`），换集=保存当前行 `lastPositionMs` + 载下一行（每行自己的 subtitleSource/audioTrackId/delayMs 生效）；自动连播/上下集/剧集面板行为不变；`updateCurrentEpisode`/`updatePlaylistJson` 调用删除；watch tracker 换集时按新集 title 重建（修统计粒度 bug）；收藏句/制卡写 `bookKey=当前集 uid, sectionIndex=0`。cue 走单视频 DB 路径（`loadCues`/`saveCues` per 集行）。

### Phase 4 — 库 UI + 合集详情页 + 管理入口（Jellyfin 展示的主体）

**Files:** Create `hibiki/lib/src/pages/implementations/media_collection_detail_page.dart`、`media_collection_pick_dialog.dart`（下拉选已有/首项新建）、`collection_cover.dart`（2×2 拼贴 + 堆叠，改造 `SeriesFolderCover`）；Modify `reader_hibiki_history_page.dart` + parts、`home_video_page.dart`、`shelf_reorder_page.dart`；Delete `series_shelf_card.dart`/`series_detail_page.dart`（组件更名迁移进新文件）。

**行为契约（照抄 Jellyfin 记号）：**
- 库网格：合集卡 = 封面（playlist 2×2 拼贴 / collection 首成员堆叠，`coverSource` 优先）+ 名称 + 成员数角标；折叠规则 §2.5；点卡进详情页。
- 详情页：头部 = 大封面 + 名称 + 类型/成员数元数据行 + 「播放/继续」主按钮（§2.4 推导，playlist 显示「继续看 第 N 集」，collection 显示「继续读/看 <成员名>」）+ 重命名/删除/改封面菜单；成员区 playlist=纵向有序列表（缩略图+标题+每行进度条+拖拽手柄重排，点行=从该行开始连播）、collection=按媒体类型分组的海报网格（书籍组/视频组，Jellyfin renderCollectionItems 分组式）；成员行/卡菜单含「从合集移除」（移除=解链；移空自删合集）。删除合集确认文案明确「不会删除成员本身」。
- 管理入口：书架/视频库批量多选按钮「组合成系列」→「添加到合集」（弹 pick dialog）；书架拖拽合并手势保留、后端改建 collection；`ShelfReorderPage` 的系列内联框/onMerge 泛化为合集。
- i18n：`series_*` 17 个 key 用 `i18n_sync.dart --remove` 删、新增 `collection_*` key 用 `--add`，然后 `dart run slang` + `dart format`。

### Phase 5 — 远端协议 + 同步/备份面

**Files:** `app_model_library_host_service.dart`（`_describeVideo`/`resolveEpisodePath`）、`hibiki_library_host_service.dart`（RemoteVideoInfo/RemoteVideoEpisode）、`sync_orchestrator.dart:640-740`（视频进度同步）、`backup_service.dart`（`_videoPathsForRow`/`_rebaseVideoPlaylistJson`）、`backup_merge_engine.dart`（合并表清单加 `media_collections`/`media_collection_items`）、`data_root_migrator.dart`（去 playlist_json 改写）。

**行为契约：** host 端把 playlist 合集作为一个远端条目下发（保持 `(uid, episodeIndex)` 线协议不变：uid=合集代表键，episodeIndex→按 `getCollectionItems` 序号反查成员行 videoPath——线上契约零破坏，旧 client 对新 host 兼容）；进度同步遍历所有视频行 `lastPositionMs`（拆集后天然覆盖每集，修掉「playlist 进度不进同步」的旧缺口）；备份文件收集按行 videoPath（playlistJson 分支删除）；合并引擎按 `(name,collectionType)` 幂等插合集、按复合 PK 插成员。

### Phase 6 — 清理 + 守卫

删除淘汰清单（`m3u8_playlist.dart` 的 positionMs 系纯函数、`playlistEpisodeCount` 全部消费点、双轨注释）；更新/删除 §盘点列出的 19 个相关测试；加源码扫描守卫测试：生产代码禁止再出现 `playlistJson`（白名单：迁移代码 + 冻结列定义）与 `setSeriesForEntry`。全量 `flutter analyze`（含 test）+ `flutter test` + `dart format .`。

## 5. 破坏面与兼容清单（盘点结论，执行时逐项核销）

| 面 | 现状 | 处置 |
|---|---|---|
| AudioCues | playlist 从不落库，audioFileIndex 对视频恒 0 | 无需迁移；拆后每集走单视频 cue 路径 |
| 每集进度 | playlistJson[].positionMs + prefs 镜像；lastPositionMs 死列 | 迁移搬进各集行 lastPositionMs；prefs 镜像键作废（孤儿无害） |
| completedAt / 观看统计 | 整本粒度；统计记首开集 title | 迁移照抄保可见状态；拆后天然每集粒度 |
| 收藏句（prefs JSON）/ MinedSentences | sectionIndex=集下标 | v38 迁移改写（§3.2.3） |
| FavoriteWords / LookupMiningCounters | 无集维度 | 不迁移，记录已知残留 |
| 远端协议 | (uid, episodeIndex) + playlistJson 反查 | host 换合集反查，线协议不变 |
| 备份/合并/data-root 迁移 | 解析 playlistJson 收路径/rebase | 按行 videoPath；合并清单加新表 |
| ShelfEntries.sortOrder | 书架排序真相源 | 保留不动 |
| Series 表 / seriesId / playlistJson 列 | — | 物理冻结不 DROP；数据清空 |
| **生产 DB 红线** | 用户库已是 v37+，worktree 构建起动会撞降级守卫 | 一切真机验证前先比 schemaVersion；绝不对 `D:\APP\HIBIKI_date` 生产库跑开发构建 |

## 6. 验证计划

1. 每 phase：`dart format .` + 全量 `flutter analyze`（含 test，warning 即 CI 红）+ `flutter test`。
2. 迁移专项：v37 夹具库升级断言（§3.3）+ 双跑幂等；另用**真实书目复刻库**（从 prod DB 只读导出 schema+样本行，遵循 BUG-717 复现范式）在 Windows 离屏跑一次真迁移。
3. 真机路径（声明「修好了」前必做，焦点驱动禁 tap）：Android 模拟器 + Windows 离屏各一遍——旧多集视频升级后：库里出现 playlist 合集卡 → 详情页每集进度正确 → 点第 2 集从其旧 positionMs 续播 → 换集/自动连播 → 收藏句跳转正确；书架旧系列变合集卡、拖拽合并建合集、批量添加到合集；删除合集后成员回散列。
4. 远端：两台设备配对，新 host + 新 client 播放列表播放/换集/续播。

## 7. 风险与开放问题

- **迁移不可回滚**（拆行+删 parent 是破坏性改写）：v38 迁移前自动做 `hibiki.db.bak.v37` 侧备份（沿用降级救援 bak.vN 惯例），失败可手动还原。
- **大播放列表迁移耗时**：纯 SQL+JSON 改写无 ffmpeg，百集级预计 <1s；封面懒补不阻塞迁移。
- **多设备混版本**：v38 设备拆集后，旧版本设备的备份合并会把旧 playlist 行重新插回（merge 引擎 `_insertMissingVideoBooks`）→ Phase 5 给合并引擎加「playlistJson 行进站时先过拆分器」的入站闸。
- 开放：详情页是否要 backdrop 大图头部（Jellyfin 有；本 app 只有竖版封面，v1 用模糊放大封面当 backdrop，实现成本低，效果待真机评估）。

---

## 8. 执行进度与结论（2026-07-11 落地记录）

分支 `worktree-unified-collections-plan`，全部推送到 origin。每 phase 均 `dart format` + `flutter analyze`（lib+test）clean + 相关 `flutter test` 绿；Phase 4b 后跑过一次全量 `flutter test` = **10774 passed / 3 skipped / 0 failed**。

| Phase | 状态 | 关键提交 | 验证 |
|---|---|---|---|
| 1 DB+迁移 | ✅ 已落 | tables.dart + database.dart v38（split→migrate）+ ttu_sanitize/video_book_uid core 副本 + parity guard | 迁移单测 + 幂等双跑 |
| 2 导入拆集 | ✅ 已落 | video_book_repository.importSplitPlaylist / video_import_dialog / media_source_scanner | 导入单测 |
| 3 播放器合集驱动 | ✅ 已落 | video_hibiki_page + episode/lookup_favorite/lookup_mining part：`_episodes` 换 `_PlaylistEpisodeRef`，本地换集 pushReplacement 同集 | 页面单测 + 更新的守卫 |
| 4a 视频库 | ✅ 已落 | collection_grouping（纯函数）+ media_collection_detail_page（有序剧集）+ home_video_page groupByCollections | collection_grouping 单测 + widget |
| 4b 书架 | ✅ 已落 90f213a6e | media_collection_grid_detail_page（无序网格）+ reader_hibiki_history_page/books.part groupByCollections | reader/shelf/series 80 测试 + 全量 10774 |
| 5a 备份合并 | ✅ 已落 4e6ca0b07 | backup_merge_engine._mergeMediaCollections（自然键 remap + 复合 PK 去重） | merge 34 测试（含 2 新合集测试） |
| 5b 远端协议 | ✅ 已确认无需改 | — | 远端视频 75 测试绿 |
| 6 守卫 | ✅ 已落 f0b4f6687 | unified_collections_architecture_guard（4 不变量） | 4 守卫绿 |

### Phase 5b 结论修正（与 §4 计划的偏差，已核实）

计划设想 host 把 playlist 合集作为「一个远端条目 + episodes[]」下发。**执行时核实发现无需实现**：Phase 2 后**生产代码已无任何 playlistJson 写入路径**（单流/单视频写单行 streamSpecJson；多集 m3u8 走 importSplitPlaylist 拆成独立行 + 合集）。故 v38 后每个 VideoBooks 行都是独立单视频，`playlist_json` 恒 NULL：

- host `listVideos()` 天然把每集当独立远端单视频下发；
- 每集进度经 `getVideoPosition(bookUid)` 按各自行 key 存取——**天然每集粒度**，修掉了旧「playlist 进度不进同步」的缺口；
- `_episodesFromRow` / `_resolveEpisodeVideoPath` 的 playlistJson 分支对直接种 playlistJson 的测试仍工作（未破坏），对生产数据是死支（Phase 6 待清）。

远端「把拆出的集重新分组成合集」= 纯 UI 增强，需两台设备 LAN 真机验证（铁律：播放/协议改动真机复测前不宣称完成），且要为浏览协议新增合集下发面——**本轮不做**，与用户「每集独立条目」的拆分选择一致（远端也按独立集呈现，功能完整、进度正确）。

### 尚未完成（诚实清单，需真机后续）

Phase 6 的「删旧 Series API + 冻结表 DROP」**未做**，因其唯一存活消费者是**书架整理页 `ShelfReorderPage`**（书架 + 视频库均可打开的拖拽重排页），它端到端按 `seriesId` 渲染同色分组框 + 拖拽合并写 series。现状：

- 重排页的**排序（sortOrder）仍工作**且反映到主网格（groupByCollections 读 shelf_entries sortOrder）；
- 重排页的**「拖拽合并成系列」写空的 series 表**（迁移后 series 恒空）→ 建出的分组在主网格不显示 = 潜在不一致。

把重排页 series→合集彻底改造（分组框/拖拽合并/进入系列全换合集）是**大型交互式拖拽布局改动**，按 CLAUDE.md 铁律需真机焦点驱动复测（离屏 bg 无法验证拖拽手势），故本轮**只加守卫、不改重排页**。旧 Series DAO（createSeries/setSeriesForEntry/deleteSeries…）、`SeriesDetailPage`、`SeriesReorderFrame`、`series_*` i18n key、`groupAndSortShelfEntries`、`playlistEpisodeCount` 系死函数一并**保留到重排页改造完成后统一删**（冻结表按「Never break userspace」不 DROP）。

**后续接手入口**：重排页改造 = 把 `shelf_reorder_page.dart` + `shelf_ordering.dart` 的 `ShelfGroup`/`groupAndSortShelfEntries` 换成 collection 分组，merge 回调改 `createMediaCollection`+`addToCollection`，`_seriesById` 帧换 `_collectionsById`；改完真机（Android 模拟器 + Windows 离屏焦点驱动）验证拖拽合并建合集、进入合集、移出成员，再删上述死代码 + 加 `setSeriesForEntry` 禁用守卫。
