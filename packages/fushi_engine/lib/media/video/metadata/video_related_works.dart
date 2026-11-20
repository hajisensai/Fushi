/// 刮削源给出的「作品 → 相关作品」系列关系（续作 / 前传 / 外传 / 剧场版…）：
/// 从 provider 本来就拿到的响应里抽出来，落进 `collection_relations`
/// （见 `video_collection_relation_sync.dart`）。
///
/// 纯函数，不联网：AniDB 读 anime XML 的 `<relatedanime>`（刮削时的响应或已落盘的
/// `AnimeDoc_{aid}.xml`），MAL 读 Jikan `anime/{id}/full` 的 `relations`（刮削时的
/// 响应或 `video_metadata_raw_snapshots` 里的 details 快照）。TMDB 详情只有
/// `belongs_to_collection` 的合集 id、没有其余成员（要另打 `/collection/{id}`），
/// 按「不新增网络请求面」不抽。
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
/// 返回 null = 这份载荷**没带**关系信息（AniDB 只有目录、TMDB、未知源），调用方
/// 不应据此清掉已有的关系行；返回空表 = 源明确说没有相关作品。
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
