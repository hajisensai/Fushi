/// 刮削源给出的「作品 → 相关作品」系列关系（续作 / 前传 / 外传 / 剧场版…）：
/// 从 provider 本来就拿到的响应里抽出来，落进 `collection_relations`
/// （见 `video_collection_relation_sync.dart`）。
///
/// 纯函数，不联网：AniDB 读 anime XML 的 `<relatedanime>`（刮削时的响应或已落盘的
/// `AnimeDoc_{aid}.xml`），MAL 读 Jikan `anime/{id}/full` 的 `relations`（刮削时的
/// 响应或 `video_metadata_raw_snapshots` 里的 details 快照），TMDB 电影读刮削时随
/// 详情附上的合集成员（[kTmdbCollectionPartsPayloadKey]，`/collection/{id}` 的精简
/// 结果，随 details 快照落盘）。TMDB 剧集的各季不算系列关系。
library;

import 'package:fushi_compute/fushi_compute.dart'
    show FfcXmlElement, parseAniDbAnimeXml;
import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart';

/// `collection_relations.relation_type` 的落库值（与 app 侧
/// `CollectionRelationType.wire` 一一对应，冻结）。
abstract final class CollectionRelationWire {
  static const String prequel = 'prequel';
  static const String sequel = 'sequel';
  static const String sideStory = 'side_story';
  static const String movie = 'movie';
  static const String spinOff = 'spin_off';
  static const String other = 'other';
}

/// AniDB anime XML 里 `rawPayload` 携带相关作品的键（随 details 快照落库，存量
/// 补填也能从快照读）。
const String kAniDbRelatedPayloadKey = 'related';

/// TMDB 电影详情 `rawPayload` 里附带的合集成员键（刮削时对 `belongs_to_collection`
/// 多打一次 `/collection/{id}`，只留 `id` / `title` / `release_date`；随 details
/// 快照落盘，存量补填只读快照）。前缀 `fushi_` 免得与 TMDB 自己的字段撞名。
const String kTmdbCollectionPartsPayloadKey = 'fushi_collection_parts';

/// `/collection/{id}` 响应 → [kTmdbCollectionPartsPayloadKey] 的精简成员表（只收
/// 电影条目；个别条目 `media_type` 缺省照电影算，与「整套下载」同口径）。
List<Map<String, Object?>> tmdbCollectionPartsFromResponse(
  Map<String, Object?> collection,
) => <Map<String, Object?>>[
  for (final Object? node in metadataList(collection['parts']))
    if (metadataObject(node) case final Map<String, Object?> raw)
      if (metadataString(raw['media_type']) == null ||
          metadataString(raw['media_type']) == 'movie')
        if (metadataInt(raw['id']) case final int id)
          <String, Object?>{
            'id': id,
            'title':
                metadataString(raw['title']) ??
                metadataString(raw['original_title']) ??
                '',
            'release_date': metadataString(raw['release_date']) ?? '',
          },
];

/// TMDB 合集成员 → 电影 [selfId] 的系列关系：按上映日期排（未定档殿后，与「整套
/// 下载」同序），紧挨着的上一部记前传、下一部记续作。只记相邻两部，与 AniDB 只给
/// 直接关系同口径：整条系列靠本机已绑定的节点逐部展开（关系网 BFS），不把 N 部
/// 两两连成 N² 条边。合集里找不到自己（数据不一致）时返回空表。
List<VideoRelatedWork> tmdbRelatedWorksFromCollectionParts(
  String selfId,
  List<Object?> parts,
) {
  final List<({String id, String title, String date})> movies =
      <({String id, String title, String date})>[];
  final Set<String> seen = <String>{};
  for (final Object? node in parts) {
    final Map<String, Object?>? m = metadataObject(node);
    if (m == null) continue;
    final String? id =
        metadataString(m['id']) ?? metadataInt(m['id'])?.toString();
    if (id == null || id.isEmpty || !seen.add(id)) continue;
    movies.add((
      id: id,
      title: metadataString(m['title']) ?? '',
      date: metadataString(m['release_date']) ?? '',
    ));
  }
  // 稳定排序：同日期保持 TMDB 原序。
  final List<int> order = List<int>.generate(movies.length, (int i) => i)
    ..sort((int a, int b) {
      final String da = movies[a].date;
      final String db = movies[b].date;
      if (da.isEmpty != db.isEmpty) return da.isEmpty ? 1 : -1;
      final int byDate = da.compareTo(db);
      return byDate != 0 ? byDate : a.compareTo(b);
    });
  final List<({String id, String title, String date})> sorted =
      <({String id, String title, String date})>[
        for (final int i in order) movies[i],
      ];
  final int self = sorted.indexWhere(
    (({String id, String title, String date}) m) => m.id == selfId,
  );
  if (self < 0) return const <VideoRelatedWork>[];
  return <VideoRelatedWork>[
    if (self > 0)
      VideoRelatedWork(
        provider: 'tmdb',
        externalId: sorted[self - 1].id,
        relationType: CollectionRelationWire.prequel,
        title: sorted[self - 1].title,
      ),
    if (self + 1 < sorted.length)
      VideoRelatedWork(
        provider: 'tmdb',
        externalId: sorted[self + 1].id,
        relationType: CollectionRelationWire.sequel,
        title: sorted[self + 1].title,
      ),
  ];
}

/// 一条相关作品：目标在 [provider] 里的 id、关系落库值、源给的标题。
final class VideoRelatedWork {
  const VideoRelatedWork({
    required this.provider,
    required this.externalId,
    required this.relationType,
    required this.title,
  });

  /// `anidb` / `mal`（即 `collection_relations.source`）。
  final String provider;

  /// 目标在该源的 id（`collection_relations.subject_id`）。
  final String externalId;

  /// [CollectionRelationWire] 之一。
  final String relationType;

  /// 源给的标题（可能为空串：源没给时由调用方兜底）。
  final String title;

  Map<String, Object?> toPayload() => <String, Object?>{
    'id': externalId,
    'type': relationType,
    'title': title,
  };

  @override
  bool operator ==(Object other) =>
      other is VideoRelatedWork &&
      other.provider == provider &&
      other.externalId == externalId &&
      other.relationType == relationType &&
      other.title == title;

  @override
  int get hashCode => Object.hash(provider, externalId, relationType, title);

  @override
  String toString() =>
      'VideoRelatedWork($provider:$externalId $relationType "$title")';
}

/// AniDB `<relatedanime type="…">` → 落库值。
///
/// - Sequel / Prequel 原样；Side Story → side_story；
/// - Parent Story（目标是本篇、本条是它的外传）、Full Story、Summary、
///   Alternative Setting / Version、Same Setting、Character、Other → other；
/// - 认不出的类型也归 other（AniDB 新增类型时不丢边）。
String aniDbRelationWire(String type) => switch (type.trim().toLowerCase()) {
  'sequel' => CollectionRelationWire.sequel,
  'prequel' => CollectionRelationWire.prequel,
  'side story' => CollectionRelationWire.sideStory,
  _ => CollectionRelationWire.other,
};

/// Jikan `relations[].relation` → 落库值；`Adaptation`（指向漫画 / 小说原作）等
/// 非 anime 关系由调用方按 `entry.type` 先滤掉。
String malRelationWire(String relation) =>
    switch (relation.trim().toLowerCase()) {
      'sequel' => CollectionRelationWire.sequel,
      'prequel' => CollectionRelationWire.prequel,
      'side story' => CollectionRelationWire.sideStory,
      'spin-off' || 'spin off' => CollectionRelationWire.spinOff,
      _ => CollectionRelationWire.other,
    };

/// 从 anime XML 根元素取 `<relatedanime>` 全部条目（同一 aid 只留第一条）。
List<VideoRelatedWork> aniDbRelatedWorksFromRoot(FfcXmlElement root) {
  final Set<String> seen = <String>{};
  final List<VideoRelatedWork> out = <VideoRelatedWork>[];
  for (final FfcXmlElement related
      in root.getElement('relatedanime')?.findElements('anime') ??
          const <FfcXmlElement>[]) {
    final int? id = int.tryParse((related.getAttribute('id') ?? '').trim());
    if (id == null || id <= 0 || !seen.add('$id')) continue;
    out.add(
      VideoRelatedWork(
        provider: 'anidb',
        externalId: '$id',
        relationType: aniDbRelationWire(related.getAttribute('type') ?? ''),
        title: related.innerText.trim(),
      ),
    );
  }
  return out;
}

/// 已落盘的 `AnimeDoc_{aid}.xml` → 相关作品。不是 `<anime>` 根（错误响应、封禁
/// 页）或解析失败返回 null（与「没有相关作品」的空表区分开）。
List<VideoRelatedWork>? aniDbRelatedWorksFromXml(String xml) {
  final FfcXmlElement root;
  try {
    root = parseAniDbAnimeXml(xml);
  } on Object {
    return null;
  }
  if (root.localName != 'anime') return null;
  return aniDbRelatedWorksFromRoot(root);
}

/// Jikan `anime/{id}/full` 的 `data`（或其快照）→ 相关作品：只取 `entry.type ==
/// anime` 的条目，同一 MAL id 只留第一条。
List<VideoRelatedWork> malRelatedWorksFromItem(Map<String, Object?> item) {
  final Set<String> seen = <String>{};
  final List<VideoRelatedWork> out = <VideoRelatedWork>[];
  for (final Object? node in metadataList(item['relations'])) {
    final Map<String, Object?>? relation = metadataObject(node);
    if (relation == null) continue;
    final String? kind = metadataString(relation['relation']);
    if (kind == null) continue;
    for (final Object? entryNode in metadataList(relation['entry'])) {
      final Map<String, Object?>? entry = metadataObject(entryNode);
      if (entry == null) continue;
      if (metadataString(entry['type'])?.toLowerCase() != 'anime') continue;
      final int? id = metadataInt(entry['mal_id']);
      if (id == null || id <= 0 || !seen.add('$id')) continue;
      out.add(
        VideoRelatedWork(
          provider: 'mal',
          externalId: '$id',
          relationType: malRelationWire(kind),
          title: metadataString(entry['name']) ?? '',
        ),
      );
    }
  }
  return out;
}

/// 刮削结果的 `rawPayload`（或 details 快照）→ 相关作品。
///
/// 返回 null = 这份载荷**没带**关系信息（AniDB 只有目录、TMDB 剧集 / 合集请求失败
/// 或旧快照、未知源），调用方不应据此清掉已有的关系行；返回空表 = 源明确说没有
/// 相关作品（TMDB 电影 `belongs_to_collection` 为 null = 不属于任何系列）。
List<VideoRelatedWork>? relatedWorksFromRawPayload(
  String provider,
  Map<String, Object?>? payload,
) {
  if (payload == null) return null;
  switch (provider) {
    case 'anidb':
      final Object? raw = payload[kAniDbRelatedPayloadKey];
      if (raw is! List) return null;
      final Set<String> seen = <String>{};
      return <VideoRelatedWork>[
        for (final Object? node in raw)
          if (metadataObject(node) case final Map<String, Object?> m)
            if (metadataString(m['id']) ?? metadataInt(m['id'])?.toString()
                case final String id when id.isNotEmpty && seen.add(id))
              VideoRelatedWork(
                provider: 'anidb',
                externalId: id,
                relationType: _knownWire(metadataString(m['type'])),
                title: metadataString(m['title']) ?? '',
              ),
      ];
    case 'mal':
      if (payload['relations'] is! List) return null;
      return malRelatedWorksFromItem(payload);
    case 'tmdb':
      // 只有电影详情带这个键（剧集没有），剧集 → null。
      if (!payload.containsKey('belongs_to_collection')) return null;
      if (metadataObject(payload['belongs_to_collection']) == null) {
        return const <VideoRelatedWork>[];
      }
      final Object? parts = payload[kTmdbCollectionPartsPayloadKey];
      final String? selfId =
          metadataString(payload['id']) ??
          metadataInt(payload['id'])?.toString();
      if (parts is! List || selfId == null) return null;
      return tmdbRelatedWorksFromCollectionParts(selfId, parts);
    default:
      return null;
  }
}

String _knownWire(String? raw) => switch (raw) {
  CollectionRelationWire.prequel ||
  CollectionRelationWire.sequel ||
  CollectionRelationWire.sideStory ||
  CollectionRelationWire.movie ||
  CollectionRelationWire.spinOff => raw!,
  _ => CollectionRelationWire.other,
};
