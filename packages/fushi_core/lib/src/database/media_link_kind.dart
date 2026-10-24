/// 跨模块作品图谱（`media_links`，schema v125，spec
/// `docs/specs/2026-10-24-cross-media-links.md`）的值域。
///
/// 与 `MediaKind` / `TagHostKind` 刻意分开：作品图谱的端点粒度不同（视频分合集与
/// 单集、音乐分专辑与曲目），跨域换算一律走显式映射，禁止 UI 层裸字符串比较。
/// 落库值冻结，新增只追加。
enum MediaLinkKind {
  /// 视频合集（作品 / 季）。本地键 = `MediaCollections.id` 的字符串（与
  /// `collectionTagEntryKey` 同一编码）；跨端身份 = 合集自然键 `<type>:<name>`。
  videoCollection('video_collection'),

  /// 单个视频（单集 / 剧场版文件）。键 = `VideoBooks.bookUid`（本就跨端稳定）。
  videoEpisode('video_episode'),

  /// 书（EPUB / PDF / 漫画同表）。本地键 = `EpubBooks.bookKey`；跨端身份 = wire
  /// bookKey（`CollectionBookIdentityIndex`）。
  book('book'),

  /// 游戏。本地键 = `Galgames.id`；跨端身份 = `GameIdentityIndex.wireIdentity`
  /// （带别名）。
  game('game'),

  /// 音乐专辑。键 = 音乐模块的 `album_uid`（内容派生、跨端稳定；音乐模块落地前
  /// 只有值域，没有本地表）。
  musicAlbum('music_album'),

  /// 音乐曲目。键 = 音乐模块的 `track_uid`（同上）。
  musicTrack('music_track'),

  /// 有声书。键 = `Audiobooks.bookKey`（与其 EPUB 共享 bookKey）。
  audiobook('audiobook');

  const MediaLinkKind(this.dbValue);

  /// 落库 / wire 值（冻结）。
  final String dbValue;

  /// 严格解析：未知 / null → null（同步须容忍对端未来新增的种类原样跳过）。
  static MediaLinkKind? tryParse(String? raw) {
    for (final MediaLinkKind k in MediaLinkKind.values) {
      if (k.dbValue == raw) return k;
    }
    return null;
  }
}

/// 连接关系。方向约定（`from → to`）：
/// - [adaptation]：原作 → 改编（小说 → 动画、动画 → 游戏……）；
/// - [themeSong] / [soundtrack]：音乐（曲目 / 专辑）→ 它所属的视频 / 游戏；
/// - [sameWork]：无方向，落库前按 [canonicalMediaLinkEndpoints] 排序；
/// - [cast]：声优 / 角色关联（人物页 L5 才有本地端点，先只定义值）。
enum MediaLinkRelation {
  adaptation('adaptation', directed: true),
  themeSong('theme_song', directed: true),
  soundtrack('soundtrack', directed: true),
  sameWork('same_work', directed: false),
  cast('cast', directed: true);

  const MediaLinkRelation(this.dbValue, {required this.directed});

  final String dbValue;

  /// false = 无方向关系（两端互换是同一条连接）。
  final bool directed;

  static MediaLinkRelation? tryParse(String? raw) {
    for (final MediaLinkRelation r in MediaLinkRelation.values) {
      if (r.dbValue == raw) return r;
    }
    return null;
  }
}

/// 连接来源（`media_links.source`）的已知值。列本身是开放文本：推断来源按
/// 「来源名」落库，旧版遇到未知来源照常显示、照常同步。
abstract final class MediaLinkSource {
  /// 用户手动连接（永远优先，恒为已确认）。
  static const String manual = 'manual';

  /// VNDB 的 VN 条目自带的关联动画 AniDB id（强判据）。保留值：VNDB kana API 实际
  /// 不提供 anime 字段（2026-10-24 实测），这条判据改由 [wikidata] 桥接。
  static const String vndb = 'vndb';

  /// Wikidata id 桥接：VN（P3180 VNDB id）经 based on / derivative work 到动画，
  /// 读出 AniDB anime id（P5646）后对上本地视频（强判据，仍只作建议）。
  static const String wikidata = 'wikidata';

  /// MAL（Jikan）的 Adaptation 关系 + 本地书 ISBN / 标题匹配（中等判据）。
  static const String mal = 'mal';

  /// AI 辅助裁决（一律只作建议）。
  static const String ai = 'ai';
}

/// 一条连接的端点（种类 + 本地键）。
typedef MediaLinkEndpoint = ({MediaLinkKind kind, String key});

/// 端点全序：先比种类落库值，再比键。无方向关系落库前用它定 from / to，
/// 让 (A, B) 与 (B, A) 落到同一行。
int compareMediaLinkEndpoints(MediaLinkEndpoint a, MediaLinkEndpoint b) {
  final int byKind = a.kind.dbValue.compareTo(b.kind.dbValue);
  if (byKind != 0) return byKind;
  return a.key.compareTo(b.key);
}

/// 把一条连接的两端规范化：有方向关系原样返回；无方向关系按
/// [compareMediaLinkEndpoints] 排成 (小, 大)。
({MediaLinkEndpoint from, MediaLinkEndpoint to}) canonicalMediaLinkEndpoints(
  MediaLinkRelation relation,
  MediaLinkEndpoint from,
  MediaLinkEndpoint to,
) {
  if (relation.directed || compareMediaLinkEndpoints(from, to) <= 0) {
    return (from: from, to: to);
  }
  return (from: to, to: from);
}

/// 一行连接的可见状态。
enum MediaLinkState {
  /// 已确认（手动连接，或用户确认过的推断）：详情页「同一作品」区块显示。
  confirmed,

  /// 推断建议（未确认）：只在「可能相关」建议卡里出现。
  suggested,

  /// 已删除 / 已否决：墓碑。推断不得重复提议同一对条目。
  removed,
}
