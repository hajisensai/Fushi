import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/sync/collection_book_identity_index.dart';
import 'package:fushi_engine/sync/sync_manifest_codec.dart';
import 'package:fushi_engine/sync/tag_sync.dart'
    show collectionTagWireKey, parseCollectionTagWireKey;

/// 互联作品图谱同步（`media_links`，spec `docs/specs/2026-10-24-cross-media-links.md`）。
///
/// 与标签清单同形的读-合并-写：client GET host 清单 → [applyMediaLinkManifest]
/// 并入本机 → 本机清单未被 host 覆盖（[mediaLinkManifestCovers]）才 POST → host
/// 用同一内核并入。合并是整行 LWW（`mediaLinkRemoteWins`：updatedAt 大者胜，相等
/// 时墓碑 > 用户确认 > AI 生效 > 建议，再相等按内容指纹），与应用顺序无关、重放
/// 幂等。删除 / 否决是墓碑行（`deletedAt`），随清单照常传播——对端否决过的建议不会
/// 在本机复活。
///
/// **`confirmedBy`（v159，AI 库管家设计稿 §5.3）**：条目可选字段，`user` / `ai` /
/// `none`（建议或墓碑）。`confirmed` 照旧写（= `confirmedBy == user`，给旧版对端读）。
/// - 缺字段 = 旧版对端：`confirmed == true` 按 `user`；`confirmed == false` 是**未知**
///   而不是「建议」——旧版不认识 AI 生效，会把它当建议原样回传，这种条目不得把本机
///   的 AI 生效冲掉（`FushiDatabase.mergeRemoteMediaLink` 的 `confirmerKnown`）。
/// - AI 生效不推进 `updatedAt`（停在它依据的状态上），所以一边否决、一边 AI 生效时，
///   否决晚于 AI 那一端的基线就是否决胜；同一时刻用户确认压过 AI 生效。
///
/// 端点跨端身份（与标签清单同一套换算）：
/// - book / audiobook：wire bookKey（[CollectionBookIdentityIndex]）；本机没有这本书
///   时按 wire 键原样落库（bookKey 由标题派生，书到了本机自然对上）；
/// - video_episode：`VideoBooks.bookUid`；music_*：内容派生 uid——本就跨端稳定，透传；
/// - video_collection：合集自然键 `<collectionType>:<name>`；本机没有该合集跳过；
/// - game：游戏跨端身份 + 别名（`GameIdentityIndex`）；本机没有该游戏跳过。
///
/// 跳过的条目下一轮（宿主到了本机之后）自然补上；未知种类 / 关系（对端未来新增）
/// 原样跳过。
class MediaLinkManifest implements CanonicalJsonManifest {
  const MediaLinkManifest({
    this.version = currentVersion,
    this.links = const <MediaLinkManifestEntry>[],
  });

  static const int currentVersion = 1;
  static const String _label = 'media link manifest';

  final int version;
  final List<MediaLinkManifestEntry> links;

  factory MediaLinkManifest.fromJson(Object? json) {
    final Map<String, dynamic> map = requireManifestObject(json, _label);
    final int version = requireManifestVersion(
      map,
      currentVersion: currentVersion,
      label: _label,
    );
    return MediaLinkManifest(
      version: version,
      links: <MediaLinkManifestEntry>[
        for (final Object? e in requireManifestList(map, 'links', _label))
          MediaLinkManifestEntry.fromJson(e),
      ],
    );
  }

  @override
  Map<String, dynamic> toJson() => contentJson();

  @override
  Map<String, dynamic> contentJson() {
    final List<MediaLinkManifestEntry> sorted =
        List<MediaLinkManifestEntry>.of(links)..sort(
          (MediaLinkManifestEntry a, MediaLinkManifestEntry b) =>
              a.sortKey.compareTo(b.sortKey),
        );
    return <String, dynamic>{
      'version': version,
      'links': <Map<String, dynamic>>[
        for (final MediaLinkManifestEntry e in sorted) e.toJson(),
      ],
    };
  }

  @override
  String canonicalJson() => canonicalManifestJson(this);
}

/// 清单里的一个端点：种类落库值 + 跨端主键 + 别名（目前只有游戏有别名）。
class MediaLinkWireEndpoint {
  const MediaLinkWireEndpoint({
    required this.kind,
    required this.key,
    this.aliases = const <String>[],
  });

  factory MediaLinkWireEndpoint.fromJson(Object? json) {
    final Map<String, dynamic> map = requireManifestObject(
      json,
      'media link endpoint',
    );
    final Object? kind = map['kind'];
    final Object? key = map['key'];
    if (kind is! String || kind.isEmpty || key is! String || key.isEmpty) {
      throw const FormatException('media link manifest: bad endpoint');
    }
    final Object? aliases = map['aliases'];
    return MediaLinkWireEndpoint(
      kind: kind,
      key: key,
      aliases: <String>[
        if (aliases is List)
          for (final Object? a in aliases)
            if (a is String && a.isNotEmpty) a,
      ],
    );
  }

  final String kind;
  final String key;
  final List<String> aliases;

  Iterable<String> get allKeys => <String>[key, ...aliases];

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'key': key,
    if (aliases.isNotEmpty) 'aliases': aliases,
  };
}

class MediaLinkManifestEntry {
  const MediaLinkManifestEntry({
    required this.from,
    required this.relation,
    required this.to,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    bool isUserConfirmed = false,
    String? confirmedBy,
    this.confirmerKnown = true,
    this.role,
    this.episodeRange,
    this.confidence,
    this.reason,
    this.deletedAt,
  }) : confirmer = isUserConfirmed ? MediaLinkConfirmer.user : confirmedBy;

  /// wire 上「建议 / 墓碑，没有生效方」的 `confirmedBy` 值（与「缺字段」区分开）。
  static const String confirmedByNone = 'none';

  factory MediaLinkManifestEntry.fromJson(Object? json) {
    final Map<String, dynamic> map = requireManifestObject(json, 'media link');
    final Object? relation = map['relation'];
    final Object? created = map['createdAt'];
    final Object? updated = map['updatedAt'];
    if (relation is! String ||
        relation.isEmpty ||
        created is! int ||
        updated is! int) {
      throw const FormatException('media link manifest: bad link');
    }
    final Object? source = map['source'];
    final Object? confidence = map['confidence'];
    final Object? deleted = map['deletedAt'];
    final bool legacyConfirmed = map['confirmed'] == true;
    final Object? rawBy = map['confirmedBy'];
    // 未知值（对端未来新增）按缺字段处理：只认 confirmed。
    final String? by =
        rawBy == MediaLinkConfirmer.user ||
            rawBy == MediaLinkConfirmer.ai ||
            rawBy == confirmedByNone
        ? rawBy as String
        : null;
    return MediaLinkManifestEntry(
      from: MediaLinkWireEndpoint.fromJson(map['from']),
      relation: relation,
      to: MediaLinkWireEndpoint.fromJson(map['to']),
      source: source is String && source.isNotEmpty
          ? source
          : MediaLinkSource.manual,
      isUserConfirmed: legacyConfirmed,
      confirmedBy: by == confirmedByNone ? null : by,
      confirmerKnown: by != null || legacyConfirmed,
      createdAt: created,
      updatedAt: updated,
      role: _optString(map['role']),
      episodeRange: _optString(map['episodeRange']),
      confidence: confidence is num ? confidence.toDouble() : null,
      reason: _optString(map['reason']),
      deletedAt: deleted is int ? deleted : null,
    );
  }

  final MediaLinkWireEndpoint from;
  final String relation;
  final MediaLinkWireEndpoint to;
  final String source;

  /// 生效方（[MediaLinkConfirmer]）；null = 建议（或 [confirmerKnown] 为 false 时
  /// 「旧版对端没说」）。
  final String? confirmer;

  /// 对端说没说 `confirmedBy`（见类注释）。
  final bool confirmerKnown;
  final int createdAt;
  final int updatedAt;
  final String? role;
  final String? episodeRange;
  final double? confidence;
  final String? reason;
  final int? deletedAt;

  bool get isUserConfirmed => confirmer == MediaLinkConfirmer.user;

  /// 与 `mediaLinkRemoteWins` 同口径的版本（时钟 → 名次 → 内容指纹）。
  MediaLinkVersion get version => (
    updatedAt: updatedAt,
    rank: mediaLinkStateRank(deleted: deletedAt != null, confirmer: confirmer),
    content: mediaLinkContentKey(
      source: source,
      confidence: confidence,
      reason: reason,
      role: role,
      episodeRange: episodeRange,
      createdAt: createdAt,
      deletedAt: deletedAt,
    ),
  );

  String get sortKey =>
      '${from.kind}\u0000${from.key}\u0000$relation\u0000'
      '${to.kind}\u0000${to.key}';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'from': from.toJson(),
    'relation': relation,
    'to': to.toJson(),
    'source': source,
    'confirmed': isUserConfirmed,
    if (confirmerKnown) 'confirmedBy': confirmer ?? confirmedByNone,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (role != null) 'role': role,
    if (episodeRange != null) 'episodeRange': episodeRange,
    if (confidence != null) 'confidence': confidence,
    if (reason != null) 'reason': reason,
    if (deletedAt != null) 'deletedAt': deletedAt,
  };

  static String? _optString(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;
}

/// 本机端点 ↔ 跨端身份的双向换算（一次同步内复用同一份索引）。
class _MediaLinkIdentities {
  _MediaLinkIdentities._(
    this._books,
    this._collectionWireById,
    this._db,
    this._gameIds,
  );

  static Future<_MediaLinkIdentities> load(FushiDatabase db) async {
    final Map<String, String> collectionWireById = <String, String>{};
    final Set<String> seen = <String>{};
    final List<MediaCollectionRow> collections =
        List<MediaCollectionRow>.of(await db.getAllMediaCollections())..sort(
          (MediaCollectionRow a, MediaCollectionRow b) => a.id.compareTo(b.id),
        );
    for (final MediaCollectionRow c in collections) {
      if (c.name.isEmpty || c.collectionType.isEmpty) continue;
      final String wire = collectionTagWireKey(c.collectionType, c.name);
      // 同自然键历史重名行只认 min id 那一行（与标签 / 合集清单对齐）。
      if (!seen.add(wire)) continue;
      collectionWireById[collectionTagEntryKey(c.id)] = wire;
    }
    return _MediaLinkIdentities._(
      await CollectionBookIdentityIndex.load(db),
      collectionWireById,
      db,
      <String>{for (final GalgameRow g in await db.getAllGalgames()) g.id},
    );
  }

  final CollectionBookIdentityIndex _books;
  final Map<String, String> _collectionWireById;
  final FushiDatabase _db;
  final Set<String> _gameIds;

  /// 本机端点 → 跨端身份；无法换算（本机没有该合集 / 游戏）返回 null。
  MediaLinkWireEndpoint? wire(String kind, String localKey) {
    switch (MediaLinkKind.tryParse(kind)) {
      case MediaLinkKind.book:
      case MediaLinkKind.audiobook:
        return MediaLinkWireEndpoint(
          kind: kind,
          key: _books.wireKey(MediaKind.epub.dbValue, localKey),
        );
      case MediaLinkKind.videoEpisode:
      case MediaLinkKind.musicAlbum:
      case MediaLinkKind.musicTrack:
        return MediaLinkWireEndpoint(kind: kind, key: localKey);
      case MediaLinkKind.videoCollection:
        final String? wire = _collectionWireById[localKey];
        return wire == null
            ? null
            : MediaLinkWireEndpoint(kind: kind, key: wire);
      case MediaLinkKind.game:
        if (!_gameIds.contains(localKey)) return null;
        final ({String key, List<String> aliases}) id = _books.games
            .wireIdentity(localKey);
        return MediaLinkWireEndpoint(
          kind: kind,
          key: id.key,
          aliases: id.aliases,
        );
      case null:
        return null;
    }
  }

  /// 跨端身份 → 本机端点；本机无法落地返回 null（见 [MediaLinkManifest] 类注释）。
  Future<MediaLinkEndpoint?> local(MediaLinkWireEndpoint e) async {
    final MediaLinkKind? kind = MediaLinkKind.tryParse(e.kind);
    switch (kind) {
      case MediaLinkKind.book:
      case MediaLinkKind.audiobook:
        for (final String k in e.allKeys) {
          final String? bookKey = _books.localBookKey(k);
          if (bookKey != null) return (kind: kind!, key: bookKey);
        }
        return (kind: kind!, key: e.key);
      case MediaLinkKind.videoEpisode:
      case MediaLinkKind.musicAlbum:
      case MediaLinkKind.musicTrack:
        return (kind: kind!, key: e.key);
      case MediaLinkKind.videoCollection:
        final ({String collectionType, String name})? nk =
            parseCollectionTagWireKey(e.key);
        if (nk == null) return null;
        final MediaCollectionRow? row = await _db
            .getMediaCollectionByNaturalKey(nk.name, nk.collectionType);
        return row == null
            ? null
            : (kind: kind!, key: collectionTagEntryKey(row.id));
      case MediaLinkKind.game:
        final String? id = _books.games.resolve(e.allKeys);
        return id == null ? null : (kind: kind!, key: id);
      case null:
        return null;
    }
  }
}

/// 从本机 DB 构建作品图谱清单（含建议与墓碑；端点无法换算的行不发布）。
Future<MediaLinkManifest> loadLocalMediaLinkManifest(FushiDatabase db) async {
  final _MediaLinkIdentities ids = await _MediaLinkIdentities.load(db);
  final List<MediaLinkManifestEntry> links = <MediaLinkManifestEntry>[];
  for (final MediaLinkRow r in await db.allMediaLinks()) {
    final MediaLinkWireEndpoint? from = ids.wire(r.fromKind, r.fromKey);
    final MediaLinkWireEndpoint? to = ids.wire(r.toKind, r.toKey);
    if (from == null || to == null) continue;
    links.add(
      MediaLinkManifestEntry(
        from: from,
        relation: r.relation,
        to: to,
        source: r.source,
        confirmedBy: mediaLinkConfirmerOf(r),
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        role: r.role,
        episodeRange: r.episodeRange,
        confidence: r.confidence,
        reason: r.reason,
        deletedAt: r.deletedAt,
      ),
    );
  }
  return MediaLinkManifest(links: links);
}

/// 把对端清单并入本机 DB，返回实际改动的行数。无法落地的条目跳过。
Future<int> applyMediaLinkManifest(
  FushiDatabase db,
  MediaLinkManifest remote,
) async {
  if (remote.links.isEmpty) return 0;
  final _MediaLinkIdentities ids = await _MediaLinkIdentities.load(db);
  int changed = 0;
  for (final MediaLinkManifestEntry e in remote.links) {
    final MediaLinkRelation? relation = MediaLinkRelation.tryParse(e.relation);
    if (relation == null) continue;
    final MediaLinkEndpoint? from = await ids.local(e.from);
    final MediaLinkEndpoint? to = await ids.local(e.to);
    if (from == null || to == null) continue;
    if (from.kind == to.kind && from.key == to.key) continue;
    // 两端在本机换算后重新规范化：无方向关系在对端按对端本地键排的序，到本机
    // 可能要换个方向才落到同一行。
    final MediaLinkId id = mediaLinkIdFor(relation, from, to);
    final bool didChange = await db.mergeRemoteMediaLink(
      MediaLinkRow(
        fromKind: id.fromKind,
        fromKey: id.fromKey,
        relation: id.relation,
        toKind: id.toKind,
        toKey: id.toKey,
        role: e.role,
        episodeRange: e.episodeRange,
        source: e.source,
        confidence: e.confidence,
        isUserConfirmed: e.isUserConfirmed,
        confirmedBy: e.confirmer,
        reason: e.reason,
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
        deletedAt: e.deletedAt,
      ),
      confirmerKnown: e.confirmerKnown,
    );
    if (didChange) changed++;
  }
  // 否决管一整对：对端带来的否决（或本机的 AI 生效遇上对端的否决）可能落在同一对
  // 的另一种关系 / 方向上，逐 id 的 LWW 管不到——合并完按不变量把这一对上的 AI 生效
  // 写成墓碑（FushiDatabase.enforceMediaLinkVetoes）。
  changed += await db.enforceMediaLinkVetoes();
  return changed;
}

/// [remote] 是否已包含 [local] 的全部连接知识（每条本机连接在远端都有对应行，
/// 且远端 updatedAt 不比本机旧）。true ⇒ client 无需 POST。端点按种类 + 任一身份
/// 键对齐；无方向关系两端互换也算对上。
bool mediaLinkManifestCovers(
  MediaLinkManifest remote,
  MediaLinkManifest local,
) {
  bool endpointMatches(MediaLinkWireEndpoint a, MediaLinkWireEndpoint b) {
    if (a.kind != b.kind) return false;
    final Set<String> keys = a.allKeys.toSet();
    return b.allKeys.any(keys.contains);
  }

  for (final MediaLinkManifestEntry l in local.links) {
    final bool undirected =
        MediaLinkRelation.tryParse(l.relation)?.directed == false;
    final bool covered = remote.links.any((MediaLinkManifestEntry r) {
      if (r.relation != l.relation) return false;
      // 按 `mediaLinkRemoteWins` 的全序：远端比本机旧时本机会赢，远端还没有本机的
      // 知识。例外：远端是旧版（没说 confirmedBy）、同一时钟上的未删未确认行，而本机
      // 是 AI 生效——旧版存不下 AI 生效，POST 过去也只会原样当建议，不算缺知识。
      if (compareMediaLinkVersions(r.version, l.version) < 0) {
        final bool legacyHoldsAi =
            !r.confirmerKnown &&
            r.updatedAt == l.updatedAt &&
            r.deletedAt == null &&
            l.deletedAt == null &&
            l.confirmer == MediaLinkConfirmer.ai;
        if (!legacyHoldsAi) return false;
      }
      if (endpointMatches(r.from, l.from) && endpointMatches(r.to, l.to)) {
        return true;
      }
      return undirected &&
          endpointMatches(r.from, l.to) &&
          endpointMatches(r.to, l.from);
    });
    if (!covered) return false;
  }
  return true;
}
