import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/book_series_grouper.dart'
    show isOnlineMangaSourceMetadata;
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/sync/collection_book_identity_index.dart';
import 'package:path/path.dart' as p;

/// 读一个库页域的整理输入（spec §7.3）：散条目 + 非目录合集里的成员 + 本域合集 +
/// 拒绝表 + 已占用的合集名。全部是整表一次读、内存里 join，不逐条查库。
///
/// [onlyEntryKeys]（成员行键 `mediaType NUL entryKey`）：自动整理 / 「整理所选」只把
/// 这些条目发给 AI（散的或在整理器合集里的都一样）；其余条目一条都不发——同意说明
/// 讲的是「这些条目」，而且整域带上会把一本新书的自动整理撑成几次请求。
/// 本域合集照常全部带上（只发名字与前几个成员标题），让 AI 能把新条目并进去。
///
/// [allowedKeys]：设备本地「允许再次建议」的分组键，从拒绝表里减掉。
///
/// [includeFolderMembers]：目录合集里的条目也进 [LibraryOrganizeFacts.entries]（默认
/// 不进：整理器不动它们）。整库地图（`library_agent/library_map.dart`）要的是全库
/// 一览，打开它；整理器的调用方保持默认。
Future<LibraryOrganizeFacts> loadLibraryOrganizeFacts(
  FushiDatabase db,
  CollectionShelfDomain domain, {
  Set<String>? onlyEntryKeys,
  Set<String> allowedKeys = const <String>{},
  bool includeFolderMembers = false,
}) async {
  final CollectionBookIdentityIndex identities =
      await CollectionBookIdentityIndex.load(db);
  final List<MediaCollectionRow> allCollections = await db
      .getAllMediaCollections();
  final List<MediaCollectionItemRow> allItems = await db
      .getAllCollectionItems();
  final Map<int, MediaCollectionRow> collectionById = <int, MediaCollectionRow>{
    for (final MediaCollectionRow c in allCollections) c.id: c,
  };
  // 成员行键 → 所在合集（全部 / 整理器的）。
  final Map<String, List<int>> collectionsOfMember = <String, List<int>>{};
  final Map<int, List<MediaCollectionItemRow>> itemsByCollection =
      <int, List<MediaCollectionItemRow>>{};
  for (final MediaCollectionItemRow i in allItems) {
    (collectionsOfMember['${i.mediaType}\u0000${i.entryKey}'] ??= <int>[]).add(
      i.collectionId,
    );
    (itemsByCollection[i.collectionId] ??= <MediaCollectionItemRow>[]).add(i);
  }
  final Map<int, Set<String>> aiEvicted = await _aiEvictedMembers(
    db,
    allCollections,
  );

  final List<_Candidate> candidates = await switch (domain) {
    CollectionShelfDomain.books ||
    CollectionShelfDomain.manga => _bookCandidates(db, identities, domain),
    CollectionShelfDomain.video => _videoCandidates(db, collectionsOfMember),
    CollectionShelfDomain.games => _gameCandidates(db),
  };
  final Map<String, _Candidate> candidateByMember = <String, _Candidate>{
    for (final _Candidate c in candidates) c.memberKey: c,
  };

  // 本域合集 = 至少一个成员是本域候选条目的合集。
  final Set<int> domainCollectionIds = <int>{
    for (final _Candidate c in candidates) ...?collectionsOfMember[c.memberKey],
  };
  final List<OrganizeCollectionFact> collections = <OrganizeCollectionFact>[
    for (final int id in domainCollectionIds.toList()..sort())
      if (collectionById[id] case final MediaCollectionRow row)
        OrganizeCollectionFact(
          id: row.id,
          name: row.name,
          collectionType: row.collectionType,
          origin: row.sourceFolderPath != null
              ? CollectionOrigin.folder
              : CollectionOrigin.parse(row.origin),
          organizeKey: row.organizeKey,
          organizeAliases: decodeOrganizeAliases(row.organizeAliases),
          memberKeys: <String>{
            for (final MediaCollectionItemRow i
                in itemsByCollection[row.id] ??
                    const <MediaCollectionItemRow>[])
              '${i.mediaType}\u0000${i.entryKey}',
          },
          pinnedMemberKeys: <String>{
            for (final MediaCollectionItemRow i
                in itemsByCollection[row.id] ??
                    const <MediaCollectionItemRow>[])
              if (i.pinnedByUser) '${i.mediaType}\u0000${i.entryKey}',
          },
          aiEvictedMemberKeys: aiEvicted[row.id] ?? const <String>{},
          memberIdentities: <String, OrganizeWorkIdentity>{
            for (final MediaCollectionItemRow i
                in itemsByCollection[row.id] ??
                    const <MediaCollectionItemRow>[])
              if (candidateByMember['${i.mediaType}\u0000${i.entryKey}']
                  case final _Candidate c when !c.identity.isEmpty)
                '${i.mediaType}\u0000${i.entryKey}': c.identity,
          },
          sampleTitles: <String>[
            for (final MediaCollectionItemRow i
                in (itemsByCollection[row.id] ??
                        const <MediaCollectionItemRow>[])
                    .take(5))
              if (candidateByMember['${i.mediaType}\u0000${i.entryKey}']
                  case final _Candidate c)
                c.item.title,
          ],
        ),
  ];
  final Map<int, OrganizeCollectionFact> factById =
      <int, OrganizeCollectionFact>{
        for (final OrganizeCollectionFact c in collections) c.id: c,
      };

  final List<OrganizeEntry> entries = <OrganizeEntry>[];
  for (final _Candidate c in candidates) {
    final List<int> holders = <int>[...?collectionsOfMember[c.memberKey]]
      ..sort();
    // 目录合集的成员由磁盘目录决定（设计稿 §7）：在目录合集里的条目不交给 AI 动。
    if (!includeFolderMembers &&
        holders.any((int id) => factById[id]?.isFolder ?? false)) {
      continue;
    }
    final int? managed = <int>[
      for (final int id in holders)
        if (factById[id]?.origin.isOrganizerManaged == true) id,
    ].fold<int?>(null, (int? a, int b) => a == null || b < a ? b : a);
    if (onlyEntryKeys != null && !onlyEntryKeys.contains(c.memberKey)) {
      continue;
    }
    entries.add(
      OrganizeEntry(
        mediaType: c.mediaType,
        entryKey: c.entryKey,
        tombstoneKey: c.tombstoneKey,
        companions: c.companions,
        externalWorkKey: c.externalWorkKey,
        managedCollectionId: managed,
        collectionIds: holders,
        item: AiOrganizeItem(
          title: c.item.title,
          creator: c.item.creator,
          year: c.item.year,
          folder: c.item.folder,
          season: c.item.season,
          episode: c.item.episode,
        ),
        groupTitle: c.groupTitle,
        identity: c.identity,
      ),
    );
  }

  // 拒绝表（减掉本机放行的）与已占用的名字（活合集 + 删除墓碑；值是占着它的分组键
  // 集合，空集 = 被不带键的合集占着）。
  final Map<String, String> rejectedNames = Map<String, String>.of(
    await db.getRejectedOrganizeGroups(),
  )..removeWhere((String k, String _) => allowedKeys.contains(k));
  final Map<String, Set<String>> taken = <String, Set<String>>{
    for (final MediaCollectionRow c in allCollections)
      '${c.name}\u0000${c.collectionType}': <String>{
        if (c.organizeKey != null) c.organizeKey!,
        ...decodeOrganizeAliases(c.organizeAliases),
      },
  };
  for (final CollectionMemberTombstoneRow t
      in await db.getAllCollectionMemberTombstones()) {
    if (t.mediaType.isNotEmpty || t.entryKey.isNotEmpty) continue;
    taken.putIfAbsent(
      '${t.collectionName}\u0000${t.collectionType}',
      () => decodeOrganizeAliases(t.organizeKey),
    );
  }
  return LibraryOrganizeFacts(
    domain: domain,
    entries: entries,
    collections: collections,
    rejectedKeys: rejectedNames.keys.toSet(),
    rejectedNames: rejectedNames,
    takenNames: taken,
  );
}

/// 本机整理记录里 AI 移出 / 挪走过的（合集, 成员）对（含已撤销的：撤销 = 用户否决，
/// 成员行已 pinned；没撤销的 = 已移出过一次）。按记录里的合集自然键对到当前合集 id。
/// 设计稿 §7「同一对只移出一次」的本机判据；跨端靠成员墓碑（防并回）与 pinned 同步。
Future<Map<int, Set<String>>> _aiEvictedMembers(
  FushiDatabase db,
  List<MediaCollectionRow> collections,
) async {
  final Map<String, int> idByNatural = <String, int>{
    for (final MediaCollectionRow c in collections)
      '${c.name}\u0000${c.collectionType}': c.id,
  };
  final Map<int, Set<String>> out = <int, Set<String>>{};
  final List<LibraryOrganizeChangeRow> rows = await (db.select(
    db.libraryOrganizeChanges,
  )..where((t) => t.kind.isIn(const <String>['evict', 'move']))).get();
  for (final LibraryOrganizeChangeRow r in rows) {
    final Object? decoded = _json(r.payloadJson);
    if (decoded is! Map) continue;
    String name = r.collectionName;
    String type = r.collectionType;
    if (r.kind == 'move') {
      final Object? from = decoded['from'];
      if (from is! Map || from['name'] is! String || from['type'] is! String) {
        continue;
      }
      name = from['name'] as String;
      type = from['type'] as String;
    }
    final int? id = idByNatural['$name\u0000$type'];
    if (id == null) continue;
    final Object? members = decoded['members'];
    if (members is! List) continue;
    for (final Object? m in members) {
      if (m is Map && m['t'] is String && m['k'] is String) {
        (out[id] ??= <String>{}).add('${m['t']}\u0000${m['k']}');
      }
    }
  }
  return out;
}

/// 内部候选：一个条目在被分类为散 / 整理器成员之前的样子。
class _Candidate {
  _Candidate({
    required this.mediaType,
    required this.entryKey,
    required this.tombstoneKey,
    required this.item,
    this.externalWorkKey,
    this.groupTitle,
    this.identity = OrganizeWorkIdentity.none,
    List<OrganizeMemberRow>? companions,
  }) : companions = companions ?? <OrganizeMemberRow>[];

  final String mediaType;
  final String entryKey;
  final String tombstoneKey;
  final AiOrganizeItem item;
  final String? externalWorkKey;
  final String? groupTitle;
  final OrganizeWorkIdentity identity;
  final List<OrganizeMemberRow> companions;

  String get memberKey => '$mediaType\u0000$entryKey';
}

Future<List<_Candidate>> _bookCandidates(
  FushiDatabase db,
  CollectionBookIdentityIndex identities,
  CollectionShelfDomain domain,
) async {
  final bool manga = domain == CollectionShelfDomain.manga;
  final List<_Candidate> out = <_Candidate>[];
  final Map<String, _Candidate> byBookKey = <String, _Candidate>{};
  for (final EpubBookRow book in await db.getAllEpubBooks()) {
    if (book.uid.isEmpty) continue;
    if (isOnlineMangaSourceMetadata(book.sourceMetadata)) continue;
    final bool isManga =
        BookFormat.parseOrEpub(book.format) == BookFormat.manga;
    if (isManga != manga) continue;
    final _Candidate c = _Candidate(
      mediaType: MediaKind.epub.dbValue,
      entryKey: book.uid,
      tombstoneKey:
          '${MediaKind.epub.dbValue}\u0000${identities.wireKey(MediaKind.epub.dbValue, book.uid)}',
      item: AiOrganizeItem(title: book.title, creator: book.author),
    );
    out.add(c);
    byBookKey[book.bookKey] = c;
  }
  for (final SrtBookRow srt in await db.getAllSrtBooks()) {
    final OrganizeMemberRow row = OrganizeMemberRow(
      mediaType: MediaKind.srt.dbValue,
      entryKey: srt.uid,
      tombstoneKey: '${MediaKind.srt.dbValue}\u0000${srt.uid}',
    );
    final _Candidate? paired = srt.bookKey.isEmpty
        ? null
        : byBookKey[srt.bookKey];
    if (paired != null) {
      paired.companions.add(row);
      continue;
    }
    if (manga) continue; // 独立 SRT 书住书架。
    out.add(
      _Candidate(
        mediaType: row.mediaType,
        entryKey: row.entryKey,
        tombstoneKey: row.tombstoneKey,
        item: AiOrganizeItem(title: srt.title, creator: srt.author),
      ),
    );
  }
  return out;
}

Future<List<_Candidate>> _videoCandidates(
  FushiDatabase db,
  Map<String, List<int>> collectionsOfMember,
) async {
  // 刮削作品（按 bookUid 或按合集挂）+ 外部 id，一次读完。
  final Map<String, ({String title, int? year, String? key})> workByBook =
      <String, ({String title, int? year, String? key})>{};
  final Map<int, ({String title, int? year, String? key})> workByCollection =
      <int, ({String title, int? year, String? key})>{};
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT w.id, w.book_uid, w.collection_id, w.title, w.year, w.media_type, '
        'i.provider, i.external_id '
        'FROM video_metadata_works w '
        'LEFT JOIN video_metadata_provider_identities i ON i.work_id = w.id',
      )
      .get();
  final Map<int, Map<String, String>> idsByWork = <int, Map<String, String>>{};
  final Map<int, QueryRow> workRow = <int, QueryRow>{};
  for (final QueryRow r in rows) {
    final int id = r.read<int>('id');
    workRow[id] = r;
    final String? provider = r.readNullable<String>('provider');
    final String? external = r.readNullable<String>('external_id');
    if (provider != null && external != null && external.isNotEmpty) {
      (idsByWork[id] ??= <String, String>{})[provider] = external;
    }
  }
  workRow.forEach((int id, QueryRow r) {
    final Map<String, String> ids = idsByWork[id] ?? const <String, String>{};
    final String mediaType = r.readNullable<String>('media_type') ?? 'tv';
    final String? key = ids['anilist'] != null
        ? 'anilist:${ids['anilist']}'
        : ids['tmdb'] != null
        ? 'tmdb:$mediaType:${ids['tmdb']}'
        : ids['anidb'] != null
        ? 'anidb:${ids['anidb']}'
        : null;
    final ({String title, int? year, String? key}) work = (
      title: r.read<String>('title'),
      year: r.readNullable<int>('year'),
      key: key,
    );
    final String? bookUid = r.readNullable<String>('book_uid');
    final int? collectionId = r.readNullable<int>('collection_id');
    if (bookUid != null) workByBook[bookUid] = work;
    if (collectionId != null) workByCollection[collectionId] = work;
  });

  final List<_Candidate> out = <_Candidate>[];
  for (final VideoBookRow v in await db.allVideoBooks()) {
    final String memberKey = '${MediaKind.video.dbValue}\u0000${v.bookUid}';
    // 权威作品身份（BUG-5480）：刮削作品只认挂在这一条本身上的（下面按合集补的那份
    // 是「它在这个合集里」推出来的，不能拿来判它该不该留在这个合集）。
    final OrganizeWorkIdentity identity = OrganizeWorkIdentity(
      externalWorkKey: workByBook[v.bookUid]?.key,
      seriesKey: remoteSeriesKeyOfStreamSpec(v.streamSpecJson),
    );
    ({String title, int? year, String? key})? work = workByBook[v.bookUid];
    if (work == null) {
      for (final int cid in collectionsOfMember[memberKey] ?? const <int>[]) {
        work = workByCollection[cid];
        if (work != null) break;
      }
    }
    // 媒体服务器 / 在线源条目的路径是自定义标识（`media-server://<条目 id>/…`），
    // 目录段是条目 id 而不是文件夹，不能当 `folder` 发给 AI。
    final bool remote =
        v.videoPath.startsWith('http://') ||
        v.videoPath.startsWith('https://') ||
        isMediaServerVideoPath(v.videoPath) ||
        isAnimeSourceVideoPath(v.videoPath);
    final String fileName = remote
        ? v.title
        : p.basenameWithoutExtension(v.videoPath);
    final VideoNameInfo info = parseVideoFilename(fileName);
    final String folder = remote ? '' : p.basename(p.dirname(v.videoPath));
    out.add(
      _Candidate(
        mediaType: MediaKind.video.dbValue,
        entryKey: v.bookUid,
        tombstoneKey: memberKey,
        externalWorkKey: work?.key,
        groupTitle: work?.title,
        identity: identity,
        item: AiOrganizeItem(
          title: work != null && work.title.isNotEmpty
              ? '${work.title} — ${v.title}'
              : v.title,
          year: work?.year,
          folder: folder == '.' ? null : folder,
          season: info.season,
          episode: info.episode,
        ),
      ),
    );
  }
  return out;
}

/// 游戏：元数据来源按游戏逐个读（`getGalgameSources`，游戏库通常几十到几百个）。
Future<List<_Candidate>> _gameCandidates(FushiDatabase db) async {
  final List<_Candidate> out = <_Candidate>[];
  for (final GalgameRow g in await db.getAllGalgames()) {
    String title = g.name;
    String? developer;
    final Object? custom = _json(g.customDataJson);
    for (final GalgameSourceRow s in await db.getGalgameSources(g.id)) {
      final Object? data = _json(s.dataJson);
      if (data is Map) {
        final Object? name = data['name'];
        if (name is String && name.isNotEmpty && title == g.name) title = name;
        final Object? dev = data['developer'];
        if (dev is String && dev.isNotEmpty) developer ??= dev;
      }
    }
    if (custom is Map && custom['name'] is String) {
      final String n = (custom['name'] as String).trim();
      if (n.isNotEmpty) title = n;
    }
    out.add(
      _Candidate(
        mediaType: MediaKind.game.dbValue,
        entryKey: g.id,
        tombstoneKey: '${MediaKind.game.dbValue}\u0000${g.id}',
        item: AiOrganizeItem(
          title: title,
          creator: developer,
          year: int.tryParse((g.releaseDate ?? '').split('-').first),
        ),
      ),
    );
  }
  return out;
}

/// 本机在 [sinceMs] 之后新入库的条目（成员行键），给自动整理当 `onlyEntryKeys`。
///
/// 书 / 视频按 `local_added_at`（本机开始拥有的时刻，互联下载的书也是本机落地那一刻），
/// 游戏按 `added_at`。不看 `imported_at`：那是对端的原始入库时刻。
Future<Set<String>> organizeEntryKeysAddedSince(
  FushiDatabase db,
  CollectionShelfDomain domain,
  int sinceMs,
) async {
  final String epub = MediaKind.epub.dbValue;
  final List<(String, String)> queries = switch (domain) {
    CollectionShelfDomain.books => <(String, String)>[
      (
        epub,
        "SELECT uid AS k FROM epub_books WHERE uid != '' "
            "AND format != 'manga' AND local_added_at > ?",
      ),
      (
        MediaKind.srt.dbValue,
        "SELECT uid AS k FROM srt_books WHERE book_key = '' "
            'AND local_added_at > ?',
      ),
    ],
    CollectionShelfDomain.manga => <(String, String)>[
      (
        epub,
        "SELECT uid AS k FROM epub_books WHERE uid != '' "
            "AND format = 'manga' AND local_added_at > ?",
      ),
    ],
    CollectionShelfDomain.video => <(String, String)>[
      (
        MediaKind.video.dbValue,
        'SELECT book_uid AS k FROM video_books WHERE local_added_at > ?',
      ),
    ],
    CollectionShelfDomain.games => <(String, String)>[
      (
        MediaKind.game.dbValue,
        'SELECT id AS k FROM galgames WHERE added_at > ?',
      ),
    ],
  };
  final Set<String> out = <String>{};
  for (final (String mediaType, String sql) in queries) {
    for (final QueryRow r
        in await db
            .customSelect(
              sql,
              variables: <Variable<Object>>[Variable<int>(sinceMs)],
            )
            .get()) {
      out.add('$mediaType\u0000${r.read<String>('k')}');
    }
  }
  return out;
}

Object? _json(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}
