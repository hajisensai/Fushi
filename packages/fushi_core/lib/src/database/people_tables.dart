import 'package:drift/drift.dart';

// ── 作品图谱 L5（schema v131）：声优 / 角色聚合人物页 + 动画 ↔ 原作进度 ─────────
//
// docs/specs/2026-10-24-cross-media-links.md §5 / §6。三张表都只是**连接与缓存**：
// 人物本体仍是各模块已有的行（视频 `video_metadata_people`、游戏 VNDB 配音缓存、
// 音乐 `music_artists`），这里不另起一套「人物」实体去取代它们。

/// 游戏的 VNDB 配音表缓存：一部游戏一行，[castJson] 是 `/vn` 的 `va` 字段解析后的
/// 列表（角色 + 声优 + 声优的外部链接）。编解码在 `fushi_engine` 的
/// `vndb_voice_cast.dart`（`encodeGameVoiceCast` / `decodeGameVoiceCast`）。
///
/// 为什么不塞进 `galgame_sources.data_json`：那是元数据 draft 快照，经合并 /
/// 覆盖层 / 刮削重写；配音表是人物页按声优反查的索引源，跟 draft 生命周期不同。
///
/// **纯缓存**（由 VNDB 重新取得），设备本地；没有外键（设备本地表覆盖恢复后按
/// `INSERT … SELECT *` 回灌，外键会让孤儿行打断整批回灌）——删游戏由
/// `deleteGalgame` 同事务清掉；万一留下孤儿行，人物页反查时找不到游戏、跳过。
/// 「取过但没有配音」也落一行（空列表），避免每次打开详情页都重新请求。
@DataClassName('GameVoiceCastRow')
class GameVoiceCasts extends Table {
  /// `galgames.id`。
  TextColumn get gameId => text()();

  /// 取数时用的 VNDB VN id（`v17`）：游戏换绑到另一部 VN 时据此判失效。
  TextColumn get vndbId => text()();

  /// `encodeGameVoiceCast` 的 JSON 列表。
  TextColumn get castJson => text()();

  IntColumn get fetchedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{gameId};
}

/// 人物身份桥：「这两个节点是同一个人」的边（与「检查过」标记），供人物页把各模块
/// 的人物行按**可靠外部 id** 合并成一个人（不靠名字模糊匹配自动合并）。
///
/// 节点是 `fushi_engine` `person_identity.dart` 的节点串：外部 id
/// （`id:anidb:167`、`id:musicbrainz:<uuid>`、`id:wikidata:Q1155136` …）或本地人物
/// 引用（`ref:video:<personKey>` / `ref:game:<vndb staff id>` / `ref:music:<artistUid>`）。
///
/// 按 [source]：
/// - `wikidata`：Wikidata 桥接结果（同一 Wikidata 条目上的两个外部 id）。
///   [subject] == [object] 的自环行是「查过」标记（含查无结果），[createdAt] 是
///   查询时刻，过期重查。纯缓存。
/// - `manual`：用户在人物页确认「是同一人」（名字相同的建议）。两端按字典序排好
///   （subject < object）。[deletedAt] 非空 = 用户否决 / 取消合并（墓碑：同一对
///   不再建议）。
///
/// VNDB 声优条目自带的外部链接（AniDB / Wikidata / MusicBrainz）不进这张表——它们
/// 随 [GameVoiceCasts] 的缓存一起走。
@DataClassName('PersonIdentityBridgeRow')
class PersonIdentityBridges extends Table {
  TextColumn get subject => text()();
  TextColumn get object => text()();

  /// `wikidata` / `manual`（开放文本，未知来源读侧忽略）。
  TextColumn get source => text()();
  IntColumn get createdAt => integer()();

  /// 否决 / 取消合并时刻（只对 manual 有意义）；NULL = 存活。
  IntColumn get deletedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => <Column>{subject, object, source};
}

/// 动画进度 ↔ 原作进度的**手动对应点**：「改编作第 [episodeNumber] 集 ≈ 原作第
/// [sourceNumber] 卷 / 章」。挂在一条作品图谱 `adaptation` 连接的两端上（原作端
/// [sourceKind] / [sourceKey]，改编端 [adaptationKind] / [adaptationKey]，键与
/// `media_links` 同一套本地键），连接本身删了这些行就不再显示（不级联删，连接恢复
/// 后对应点还在）。
///
/// 由对应点估算「看到第 N 集 ≈ 原作第 M 卷」：取集号 ≤ N 的最后一个对应点（见
/// `fushi_engine` `adaptation_progress.dart`）。文本相似度推断（依赖 L4
/// `fushi_corpus`）尚未实现，届时推断结果另记来源、不写进这张手动表。
@DataClassName('AdaptationProgressAnchorRow')
class AdaptationProgressAnchors extends Table {
  /// 原作端（`MediaLinkKind.dbValue`，通常是 `book`）。
  TextColumn get sourceKind => text()();
  TextColumn get sourceKey => text()();

  /// 改编端（`video_collection` / `video_episode`）。
  TextColumn get adaptationKind => text()();
  TextColumn get adaptationKey => text()();

  /// 改编作集号（1 起）。
  IntColumn get episodeNumber => integer()();

  /// `volume` | `chapter`（开放文本，未知值读侧按卷显示）。
  TextColumn get sourceUnit => text()();

  /// 原作卷号 / 章号（1 起）。
  IntColumn get sourceNumber => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{
    sourceKind,
    sourceKey,
    adaptationKind,
    adaptationKey,
    episodeNumber,
  };

  @override
  List<String> get customConstraints => <String>[
    'CHECK (episode_number >= 1)',
    'CHECK (source_number >= 1)',
  ];
}
