import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/sync/collection_book_identity_index.dart';
import 'package:fushi_engine/sync/sync_manifest_codec.dart';

/// 互联标签同步（小说 / 漫画 / 字幕书 / 视频 / 合集 / 游戏六类宿主一条通道）。
///
/// 此前互联只在「下载远端书 / 视频的那一刻」按书 / 视频清单搬一次标签：下载之后
/// 任何一端再加 / 删 / 改名都不会到达对端，字幕书、合集（只增不删）、游戏标签则
/// 从来不跨端。这里把全部宿主的标签时钟收成一份清单，走与合集清单同形的读-合并-写：
///
/// client：GET host 清单 → [applyTagManifest] 并入本机 → 本机清单未被 host 覆盖
/// （[tagManifestCovers]）才 POST → host 同样 [applyTagManifest] 并入自己 DB。
///
/// 合并语义是既有的 LWW-element-set（`FushiDatabase.mergeRemoteTagClocks`）：逐宿主
/// 逐标签名 max(加入戳) > max(移除戳) ⇒ 在，否则不在（相等移除胜）。按名合并、与
/// 应用顺序无关，重放幂等，无需基线。
///
/// 宿主跨端身份（清单里的 `key`）：
/// - epub：wire bookKey（[CollectionBookIdentityIndex]，与合集清单同一换算）；
/// - srt：`SrtBooks.uid`；video：`VideoBooks.bookUid`（本就跨端稳定）；
/// - collection：`<collectionType>:<name>`（合集自然键，与合集清单对齐）；
/// - game：游戏跨端身份 + 别名（`GameIdentityIndex`）。
///
/// 只发布本机**存在**的宿主，只应用能解析到本机宿主的条目：本机没有的书 / 视频 /
/// 游戏不落孤儿映射，等它到了本机后下一轮自然补上。
class TagManifest implements CanonicalJsonManifest {
  const TagManifest({
    this.version = currentVersion,
    this.tags = const <TagManifestTag>[],
    this.entries = const <TagManifestEntry>[],
  });

  static const int currentVersion = 1;
  static const String _label = 'tag manifest';

  final int version;

  /// 被引用标签的定义（本机新建同名标签时沿用颜色；已有标签不改色）。
  final List<TagManifestTag> tags;

  final List<TagManifestEntry> entries;

  factory TagManifest.fromJson(Object? json) {
    final Map<String, dynamic> map = requireManifestObject(json, _label);
    final int version = requireManifestVersion(
      map,
      currentVersion: currentVersion,
      label: _label,
    );
    final Object? rawTags = map['tags'];
    return TagManifest(
      version: version,
      tags: <TagManifestTag>[
        if (rawTags is List)
          for (final Object? t in rawTags) TagManifestTag.fromJson(t),
      ],
      entries: <TagManifestEntry>[
        for (final Object? e in requireManifestList(map, 'entries', _label))
          TagManifestEntry.fromJson(e),
      ],
    );
  }

  @override
  Map<String, dynamic> toJson() => contentJson();

  @override
  Map<String, dynamic> contentJson() {
    final List<TagManifestTag> sortedTags = List<TagManifestTag>.of(tags)
      ..sort((TagManifestTag a, TagManifestTag b) => a.name.compareTo(b.name));
    final List<TagManifestEntry> sortedEntries =
        List<TagManifestEntry>.of(entries)
          ..sort((TagManifestEntry a, TagManifestEntry b) {
            final int byKind = a.kind.compareTo(b.kind);
            return byKind != 0 ? byKind : a.key.compareTo(b.key);
          });
    return <String, dynamic>{
      'version': version,
      'tags': <Map<String, dynamic>>[
        for (final TagManifestTag t in sortedTags) t.toJson(),
      ],
      'entries': <Map<String, dynamic>>[
        for (final TagManifestEntry e in sortedEntries) e.toJson(),
      ],
    };
  }

  @override
  String canonicalJson() => canonicalManifestJson(this);
}

class TagManifestTag {
  const TagManifestTag({required this.name, required this.colorValue});

  factory TagManifestTag.fromJson(Object? json) {
    final Map<String, dynamic> map = requireManifestObject(json, 'tag');
    final Object? name = map['name'];
    final Object? color = map['color'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('tag manifest: bad tag name');
    }
    return TagManifestTag(name: name, colorValue: color is int ? color : 0);
  }

  final String name;
  final int colorValue;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'color': colorValue,
  };
}

class TagManifestEntry {
  const TagManifestEntry({
    required this.kind,
    required this.key,
    this.aliases = const <String>[],
    this.addedAt = const <String, int>{},
    this.tombstones = const <String, int>{},
  });

  factory TagManifestEntry.fromJson(Object? json) {
    final Map<String, dynamic> map = requireManifestObject(json, 'tag entry');
    final Object? kind = map['kind'];
    final Object? key = map['key'];
    if (kind is! String || kind.isEmpty || key is! String || key.isEmpty) {
      throw const FormatException('tag manifest: bad entry kind/key');
    }
    final Object? aliases = map['aliases'];
    return TagManifestEntry(
      kind: kind,
      key: key,
      aliases: <String>[
        if (aliases is List)
          for (final Object? a in aliases)
            if (a is String && a.isNotEmpty) a,
      ],
      addedAt: _clockMap(map['added']),
      tombstones: _clockMap(map['removed']),
    );
  }

  /// [TagHostKind.dbValue]；未知值（对端未来新增的宿主种类）原样保留、应用时跳过。
  final String kind;

  /// 宿主跨端身份（见 [TagManifest] 类注释）。
  final String key;

  /// 同一宿主的其它跨端身份（目前只有游戏用：外部 id / 各种标题）。
  final List<String> aliases;

  /// 当前标签「名 → 加入毫秒戳」。
  final Map<String, int> addedAt;

  /// 移除墓碑「名 → 移除毫秒戳」。
  final Map<String, int> tombstones;

  Iterable<String> get allKeys => <String>[key, ...aliases];

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'key': key,
    if (aliases.isNotEmpty) 'aliases': aliases,
    'added': _sortedClock(addedAt),
    'removed': _sortedClock(tombstones),
  };

  static Map<String, int> _clockMap(Object? raw) {
    if (raw is! Map) return const <String, int>{};
    return <String, int>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        if (e.key is String &&
            (e.key as String).isNotEmpty &&
            e.value is int &&
            (e.value as int) >= 0)
          e.key as String: e.value as int,
    };
  }

  static Map<String, int> _sortedClock(Map<String, int> m) {
    final List<String> names = m.keys.toList()..sort();
    return <String, int>{for (final String n in names) n: m[n]!};
  }
}

/// 合集在标签清单里的跨端身份（自然键）。
String collectionTagWireKey(String collectionType, String name) =>
    '$collectionType:$name';

/// [collectionTagWireKey] 的逆；格式不对返回 null。collectionType 取值
/// （collection / playlist）不含冒号，按第一个冒号切分无歧义。
({String collectionType, String name})? parseCollectionTagWireKey(String key) {
  final int i = key.indexOf(':');
  if (i <= 0 || i == key.length - 1) return null;
  return (collectionType: key.substring(0, i), name: key.substring(i + 1));
}

/// 从本机 DB 构建标签清单（只含本机存在的宿主）。
Future<TagManifest> loadLocalTagManifest(FushiDatabase db) async {
  final CollectionBookIdentityIndex identities =
      await CollectionBookIdentityIndex.load(db);
  final List<TagManifestEntry> entries = <TagManifestEntry>[];

  void addEntries(
    TagHostKind kind,
    Map<String, TagClockSet> clocks,
    ({String key, List<String> aliases})? Function(String localKey) identify,
  ) {
    for (final MapEntry<String, TagClockSet> e in clocks.entries) {
      if (e.value.addedAt.isEmpty && e.value.tombstones.isEmpty) continue;
      final ({String key, List<String> aliases})? id = identify(e.key);
      if (id == null) continue;
      entries.add(
        TagManifestEntry(
          kind: kind.dbValue,
          key: id.key,
          aliases: id.aliases,
          addedAt: e.value.addedAt,
          tombstones: e.value.tombstones,
        ),
      );
    }
  }

  final Set<String> bookKeys = <String>{
    for (final EpubBookRow b in await db.getAllEpubBooks()) b.bookKey,
  };
  addEntries(
    TagHostKind.epub,
    await db.allTagClocksForKind(TagHostKind.epub),
    (String bookKey) => bookKeys.contains(bookKey)
        ? (
            key: identities.wireKey(MediaKind.epub.dbValue, bookKey),
            aliases: const <String>[],
          )
        : null,
  );

  final Set<String> srtUids = <String>{
    for (final SrtBookRow b in await db.getAllSrtBooks()) b.uid,
  };
  addEntries(
    TagHostKind.srt,
    await db.allTagClocksForKind(TagHostKind.srt),
    (String uid) =>
        srtUids.contains(uid) ? (key: uid, aliases: const <String>[]) : null,
  );

  final Set<String> videoUids = <String>{
    for (final VideoBookRow v in await db.allVideoBooks()) v.bookUid,
  };
  addEntries(
    TagHostKind.video,
    await db.allTagClocksForKind(TagHostKind.video),
    (String uid) =>
        videoUids.contains(uid) ? (key: uid, aliases: const <String>[]) : null,
  );

  // 合集：同自然键历史重名行只发布 min id 那一行（与合集清单 / 应用端对齐）。
  final Map<String, String> collectionWireById = <String, String>{};
  final Set<String> seenCollections = <String>{};
  final List<MediaCollectionRow> collections = List<MediaCollectionRow>.of(
    await db.getAllMediaCollections(),
  )..sort((MediaCollectionRow a, MediaCollectionRow b) => a.id.compareTo(b.id));
  for (final MediaCollectionRow c in collections) {
    if (c.name.isEmpty || c.collectionType.isEmpty) continue;
    final String wire = collectionTagWireKey(c.collectionType, c.name);
    if (!seenCollections.add(wire)) continue;
    collectionWireById[collectionTagEntryKey(c.id)] = wire;
  }
  addEntries(
    TagHostKind.collection,
    await db.allTagClocksForKind(TagHostKind.collection),
    (String entryKey) => switch (collectionWireById[entryKey]) {
      final String wire => (key: wire, aliases: const <String>[]),
      null => null,
    },
  );

  final Set<String> gameIds = <String>{
    for (final GalgameRow g in await db.getAllGalgames()) g.id,
  };
  addEntries(
    TagHostKind.game,
    await db.allTagClocksForKind(TagHostKind.game),
    (String gameId) =>
        gameIds.contains(gameId) ? identities.games.wireIdentity(gameId) : null,
  );

  final Set<String> referenced = <String>{
    for (final TagManifestEntry e in entries) ...e.addedAt.keys,
  };
  return TagManifest(
    tags: <TagManifestTag>[
      for (final BookTagRow t in await db.getAllTags())
        if (referenced.contains(t.name))
          TagManifestTag(name: t.name, colorValue: t.colorValue),
    ],
    entries: entries,
  );
}

/// 把对端清单并入本机 DB，返回实际改动的宿主数。解析不到本机宿主的条目跳过；
/// 每个宿主的合并各自一个事务（按名 LWW，重放幂等）。
Future<int> applyTagManifest(FushiDatabase db, TagManifest remote) async {
  if (remote.entries.isEmpty) return 0;
  final CollectionBookIdentityIndex identities =
      await CollectionBookIdentityIndex.load(db);
  final Map<String, int> colors = <String, int>{
    for (final TagManifestTag t in remote.tags) t.name: t.colorValue,
  };
  Set<String>? srtUids;
  Set<String>? videoUids;
  Set<String>? bookKeys;
  int changed = 0;
  for (final TagManifestEntry e in remote.entries) {
    String? localKey;
    TagHostKind? kind;
    if (e.kind == TagHostKind.epub.dbValue) {
      kind = TagHostKind.epub;
      bookKeys ??= <String>{
        for (final EpubBookRow b in await db.getAllEpubBooks()) b.bookKey,
      };
      for (final String k in e.allKeys) {
        final String? bookKey =
            identities.localBookKey(k) ?? (bookKeys.contains(k) ? k : null);
        if (bookKey != null) {
          localKey = bookKey;
          break;
        }
      }
    } else if (e.kind == TagHostKind.srt.dbValue) {
      kind = TagHostKind.srt;
      srtUids ??= <String>{
        for (final SrtBookRow b in await db.getAllSrtBooks()) b.uid,
      };
      if (srtUids.contains(e.key)) localKey = e.key;
    } else if (e.kind == TagHostKind.video.dbValue) {
      kind = TagHostKind.video;
      videoUids ??= <String>{
        for (final VideoBookRow v in await db.allVideoBooks()) v.bookUid,
      };
      if (videoUids.contains(e.key)) localKey = e.key;
    } else if (e.kind == TagHostKind.collection.dbValue) {
      kind = TagHostKind.collection;
      final ({String collectionType, String name})? nk =
          parseCollectionTagWireKey(e.key);
      if (nk != null) {
        final MediaCollectionRow? row = await db.getMediaCollectionByNaturalKey(
          nk.name,
          nk.collectionType,
        );
        if (row != null) localKey = collectionTagEntryKey(row.id);
      }
    } else if (e.kind == TagHostKind.game.dbValue) {
      kind = TagHostKind.game;
      localKey = identities.games.resolve(e.allKeys);
    }
    if (kind == null || localKey == null) continue;
    final bool didChange = await db.mergeRemoteTagClocks(
      kind,
      localKey,
      remoteAddedAt: e.addedAt,
      remoteTombstones: e.tombstones,
      newTagColors: colors,
    );
    if (didChange) changed++;
  }
  return changed;
}

/// [remote] 是否已包含 [local] 的全部标签知识（逐宿主逐名：远端的加入 / 移除戳
/// 不比本机旧）。true ⇒ client 无需 POST（避免每轮无谓回写）。宿主按 kind + 任一
/// 身份键（主键或别名）对齐，游戏在两端主键不同时也不会被误判成「对端缺它」。
bool tagManifestCovers(TagManifest remote, TagManifest local) {
  final Map<String, TagManifestEntry> byKey = <String, TagManifestEntry>{};
  for (final TagManifestEntry r in remote.entries) {
    for (final String k in r.allKeys) {
      byKey.putIfAbsent('${r.kind}\u0000$k', () => r);
    }
  }
  for (final TagManifestEntry l in local.entries) {
    TagManifestEntry? r;
    for (final String k in l.allKeys) {
      r = byKey['${l.kind}\u0000$k'];
      if (r != null) break;
    }
    if (r == null) return false;
    for (final MapEntry<String, int> a in l.addedAt.entries) {
      final int? ra = r.addedAt[a.key];
      final int? rt = r.tombstones[a.key];
      if (!((ra != null && ra >= a.value) || (rt != null && rt >= a.value))) {
        return false;
      }
    }
    for (final MapEntry<String, int> t in l.tombstones.entries) {
      final int? ra = r.addedAt[t.key];
      final int? rt = r.tombstones[t.key];
      if (!((rt != null && rt >= t.value) || (ra != null && ra > t.value))) {
        return false;
      }
    }
  }
  return true;
}
