/// 整库地图 `library.map`（只读；AI 管库 v3 设计稿
/// `docs/specs/2026-11-22-ai-library-agent-design.md` §3.2）。
///
/// 给长程整理 agent 一份紧凑的全库一览：
/// - `summary`：各域条目 / 散条目 / 合集（按来源）计数、关系边按状态计数、作品数；
/// - `books` / `manga` / `video` / `games`：本域合集与条目两张列式表；
/// - `links`：作品（关系图连通分量）+ 每条存活的连接 + 端点标题。
///
/// 引用格式（§3.1）：条目 `<mediaType>:<entryKey>`（与 `media_collection_items` 两列
/// 同值），合集 `C<id>`，关系端点 `<MediaLinkKind.dbValue>:<key>`。
///
/// 只给标题级事实：不给完整路径（视频只给所在文件夹的末级名）、文件内容、阅读记录。
/// 上锁的作品（`media_locked_flags`，含上锁合集的成员）一律不出现——见 [loadLibraryMap]
/// 的 `lock` 参数。
///
/// 全部是整表一次读、内存里 join：条目与合集复用整理器的 [loadLibraryOrganizeFacts]
/// （同一份标题 / 作者 / 年份 / 文件夹口径），作品复用 [loadWorkGraph]。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart';
import 'package:fushi_engine/privacy/media_lock.dart';

/// 地图视图（wire 值 = [wireName]）。
enum LibraryMapView {
  summary('summary'),
  books('books'),
  manga('manga'),
  video('video'),
  games('games'),
  links('links');

  const LibraryMapView(this.wireName);

  final String wireName;

  /// 域视图对应的库页域；`summary` / `links` 为 null。
  CollectionShelfDomain? get domain => switch (this) {
    LibraryMapView.books => CollectionShelfDomain.books,
    LibraryMapView.manga => CollectionShelfDomain.manga,
    LibraryMapView.video => CollectionShelfDomain.video,
    LibraryMapView.games => CollectionShelfDomain.games,
    LibraryMapView.summary || LibraryMapView.links => null,
  };

  static LibraryMapView? tryParse(String? raw) {
    for (final LibraryMapView v in LibraryMapView.values) {
      if (v.wireName == raw) return v;
    }
    return null;
  }
}

/// `library.map` 的参数。
class LibraryMapQuery {
  const LibraryMapQuery({
    this.view = LibraryMapView.summary,
    this.q,
    this.offset = 0,
    this.limit = defaultLimit,
  });

  /// 每页默认行数（§3.2）。
  static const int defaultLimit = 400;

  /// 每页行数上限：再大一页就会撑爆模型上下文，分页本来就是为此存在。
  static const int maxLimit = 2000;

  /// 解析 wire 参数：`{view, q?, offset?, limit?}`。`view` 缺省 = `summary`；认不出的
  /// `view`、负的 `offset`、非正的 `limit` 抛 [FormatException]（路由转成参数错误）。
  /// `limit` 超过 [maxLimit] 时截到上限。
  factory LibraryMapQuery.fromJson(Map<String, Object?> json) {
    final Object? rawView = json['view'];
    final LibraryMapView? view = rawView == null
        ? LibraryMapView.summary
        : LibraryMapView.tryParse(rawView is String ? rawView : null);
    if (view == null) {
      throw FormatException('unknown view: $rawView');
    }
    final Object? rawQ = json['q'];
    if (rawQ != null && rawQ is! String) {
      throw const FormatException('q must be a string');
    }
    final int offset = _intArg(json['offset'], 'offset') ?? 0;
    final int limit = _intArg(json['limit'], 'limit') ?? defaultLimit;
    if (offset < 0) throw const FormatException('offset must be >= 0');
    if (limit <= 0) throw const FormatException('limit must be > 0');
    final String? q = (rawQ as String?)?.trim();
    return LibraryMapQuery(
      view: view,
      q: q == null || q.isEmpty ? null : q,
      offset: offset,
      limit: limit > maxLimit ? maxLimit : limit,
    );
  }

  final LibraryMapView view;

  /// 标题过滤（按 [foldMediaTitle] 折叠后做子串匹配）；null = 不过滤。
  final String? q;
  final int offset;
  final int limit;

  static int? _intArg(Object? raw, String name) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num && raw == raw.truncate()) return raw.toInt();
    if (raw is String) {
      final int? v = int.tryParse(raw.trim());
      if (v != null) return v;
    }
    throw FormatException('$name must be an integer');
  }
}

/// 条目表的列。
const List<String> libraryMapItemColumns = <String>[
  'ref',
  'title',
  'creator',
  'year',
  'folder',
  'collections',
  'endpoint',
];

/// 合集表的列。`endpoint`：含视频成员的合集在关系图里的端点（`video_collection:<id>`）。
const List<String> libraryMapCollectionColumns = <String>[
  'ref',
  'name',
  'type',
  'origin',
  'memberCount',
  'members',
  'pinned',
  'isFolder',
  'endpoint',
];

/// 作品表的列。`isWork`：true = 关系图里的一部作品（已生效连接 / 系列合集连成的
/// 连通分量）；false = 不属于任何作品、只被建议态或卫星连接串起来的一组端点。
const List<String> libraryMapWorkColumns = <String>[
  'work',
  'name',
  'isWork',
  'members',
];

/// 连接表的列。`state`：`user`（用户确认）/ `ai`（AI 生效）/ `suggested`（建议）。
const List<String> libraryMapEdgeColumns = <String>[
  'from',
  'to',
  'relation',
  'state',
  'source',
  'role',
];

/// 条目引用 `<mediaType>:<entryKey>`。
String libraryItemRef(String mediaType, String entryKey) =>
    '$mediaType:$entryKey';

/// 合集引用 `C<id>`。
String libraryCollectionRef(int id) => 'C$id';

/// 关系端点引用 `<MediaLinkKind.dbValue>:<key>`。
String libraryEndpointRef(MediaLinkEndpoint e) => '${e.kind.dbValue}:${e.key}';

/// 读整库地图（§3.2）。
///
/// [lock]：上锁快照。省略时现读一份 [MediaLockSnapshot.load]，上锁的作品（及上锁
/// 合集与其成员）一律不进结果——即使用户本次会话在界面上解锁了，也不交给模型。
/// 调用方确实要把已解锁的作品给模型看时显式传 [MediaLockSnapshot.none]。
Future<Map<String, Object?>> loadLibraryMap(
  FushiDatabase db,
  LibraryMapQuery query, {
  MediaLockSnapshot? lock,
}) async {
  final MediaLockSnapshot locks = lock ?? await MediaLockSnapshot.load(db);
  final String? fq = query.q == null ? null : foldMediaTitle(query.q!);
  final String? filter = fq == null || fq.isEmpty ? null : fq;
  final CollectionShelfDomain? domain = query.view.domain;
  if (domain != null) {
    return _domainView(db, query, domain, locks, filter);
  }
  return switch (query.view) {
    LibraryMapView.links => _linksView(db, query, locks, filter),
    _ => _summaryView(db, locks),
  };
}

// ── 域视图 ────────────────────────────────────────────────────────────

/// 一个域的可见事实（上锁的已去掉）。
class _DomainMap {
  _DomainMap(this.collections, this.entries);

  final List<OrganizeCollectionFact> collections;
  final List<OrganizeEntry> entries;
}

Future<_DomainMap> _loadDomain(
  FushiDatabase db,
  CollectionShelfDomain domain,
  MediaLockSnapshot locks,
) async {
  final LibraryOrganizeFacts facts = await loadLibraryOrganizeFacts(
    db,
    domain,
    includeFolderMembers: true,
  );
  return _DomainMap(
    <OrganizeCollectionFact>[
      for (final OrganizeCollectionFact c in facts.collections)
        if (!locks.isCollectionLocked(c.id)) c,
    ],
    <OrganizeEntry>[
      for (final OrganizeEntry e in facts.entries)
        if (!_memberLocked(locks, e.mediaType, e.entryKey)) e,
    ],
  );
}

/// 合集成员 / 条目是否上锁（成员行键域：epub = uid，快照两种键都认）。认不出的
/// 种类按上锁处理（宁可多藏）。
bool _memberLocked(MediaLockSnapshot locks, String mediaType, String key) =>
    switch (MediaKind.tryParse(mediaType)) {
      MediaKind.epub => locks.isBookLocked(key),
      MediaKind.srt => locks.isSrtBookLocked(key),
      MediaKind.video => locks.isVideoLocked(key),
      MediaKind.game => locks.isGameLocked(key),
      null => true,
    };

String _refOfMemberKey(String memberKey) {
  final int nul = memberKey.indexOf('\u0000');
  return nul < 0
      ? memberKey
      : '${memberKey.substring(0, nul)}:${memberKey.substring(nul + 1)}';
}

Future<Map<String, Object?>> _domainView(
  FushiDatabase db,
  LibraryMapQuery query,
  CollectionShelfDomain domain,
  MediaLockSnapshot locks,
  String? filter,
) async {
  final _DomainMap map = await _loadDomain(db, domain, locks);
  final Map<String, String> bookKeyByUid = domain == CollectionShelfDomain.video
      ? const <String, String>{}
      : <String, String>{
          for (final EpubBookMeta b in await db.getEpubBookMetas())
            if (b.uid.isNotEmpty) b.uid: b.bookKey,
        };
  final Set<int> visibleCollections = <int>{
    for (final OrganizeCollectionFact c in map.collections) c.id,
  };

  // 过滤：命中的条目 + 命中的合集带出它的全部成员；合集表 = 命中的合集 + 命中条目
  // 所在的合集。
  List<OrganizeCollectionFact> collections = map.collections;
  List<OrganizeEntry> entries = map.entries;
  if (filter != null) {
    final Set<int> hitCollections = <int>{
      for (final OrganizeCollectionFact c in map.collections)
        if (foldMediaTitle(c.name).contains(filter)) c.id,
    };
    entries = <OrganizeEntry>[
      for (final OrganizeEntry e in map.entries)
        if (_entryMatches(e, filter) ||
            e.collectionIds.any(hitCollections.contains))
          e,
    ];
    final Set<int> shown = <int>{
      ...hitCollections,
      for (final OrganizeEntry e in entries) ...e.collectionIds,
    };
    collections = <OrganizeCollectionFact>[
      for (final OrganizeCollectionFact c in map.collections)
        if (shown.contains(c.id)) c,
    ];
  }

  collections = <OrganizeCollectionFact>[...collections]
    ..sort(
      (OrganizeCollectionFact a, OrganizeCollectionFact b) =>
          a.id.compareTo(b.id),
    );
  // 条目按所在的第一个合集聚在一起（散条目排最后），组内按折叠标题。
  final List<({OrganizeEntry e, int group, String folded, String ref})> sorted =
      <({OrganizeEntry e, int group, String folded, String ref})>[
        for (final OrganizeEntry e in entries)
          (
            e: e,
            group: <int>[
              for (final int id in e.collectionIds)
                if (visibleCollections.contains(id)) id,
            ].fold<int>(-1, (int a, int b) => a < 0 || b < a ? b : a),
            folded: foldMediaTitle(e.item.title),
            ref: libraryItemRef(e.mediaType, e.entryKey),
          ),
      ]..sort((a, b) {
        if (a.group != b.group) {
          if (a.group < 0) return 1;
          if (b.group < 0) return -1;
          return a.group.compareTo(b.group);
        }
        final int byTitle = a.folded.compareTo(b.folded);
        return byTitle != 0 ? byTitle : a.ref.compareTo(b.ref);
      });

  // 一页 = 合集行在前、条目行在后的一条连续序列切片。
  final int total = collections.length + sorted.length;
  final int start = query.offset > total ? total : query.offset;
  final int end = start + query.limit > total ? total : start + query.limit;
  final List<List<Object?>> collectionRows = <List<Object?>>[];
  final List<List<Object?>> itemRows = <List<Object?>>[];
  for (int i = start; i < end; i++) {
    if (i < collections.length) {
      collectionRows.add(_collectionRow(collections[i], locks));
    } else {
      final OrganizeEntry e = sorted[i - collections.length].e;
      itemRows.add(_itemRow(e, visibleCollections, bookKeyByUid));
    }
  }
  return <String, Object?>{
    'view': query.view.wireName,
    if (query.q != null) 'q': query.q,
    'total': total,
    'collectionCount': collections.length,
    'itemCount': sorted.length,
    'offset': start,
    'nextOffset': end < total ? end : null,
    'collections': <String, Object?>{
      'columns': libraryMapCollectionColumns,
      'rows': collectionRows,
    },
    'items': <String, Object?>{
      'columns': libraryMapItemColumns,
      'rows': itemRows,
    },
  };
}

bool _entryMatches(OrganizeEntry e, String filter) =>
    foldMediaTitle(e.item.title).contains(filter) ||
    (e.item.creator != null &&
        foldMediaTitle(e.item.creator!).contains(filter));

List<Object?> _collectionRow(
  OrganizeCollectionFact c,
  MediaLockSnapshot locks,
) {
  List<String> refs(Iterable<String> memberKeys) {
    final List<String> out = <String>[
      for (final String k in memberKeys)
        if (_visibleMemberKey(k, locks)) _refOfMemberKey(k),
    ]..sort();
    return out;
  }

  final List<String> members = refs(c.memberKeys);
  final bool hasVideo = c.memberKeys.any(
    (String k) => k.startsWith('${MediaKind.video.dbValue}\u0000'),
  );
  return <Object?>[
    libraryCollectionRef(c.id),
    c.name,
    c.collectionType,
    c.origin.dbValue,
    members.length,
    members,
    refs(c.pinnedMemberKeys),
    c.isFolder,
    hasVideo ? libraryEndpointRef(videoCollectionEndpoint(c.id)) : null,
  ];
}

bool _visibleMemberKey(String memberKey, MediaLockSnapshot locks) {
  final int nul = memberKey.indexOf('\u0000');
  if (nul < 0) return false;
  return !_memberLocked(
    locks,
    memberKey.substring(0, nul),
    memberKey.substring(nul + 1),
  );
}

List<Object?> _itemRow(
  OrganizeEntry e,
  Set<int> visibleCollections,
  Map<String, String> bookKeyByUid,
) {
  final String ref = libraryItemRef(e.mediaType, e.entryKey);
  final MediaLinkEndpoint? endpoint = libraryItemEndpoint(
    e.mediaType,
    e.entryKey,
    bookKeyByUid,
  );
  final String? endpointRef = endpoint == null
      ? null
      : libraryEndpointRef(endpoint);
  final String? folder = e.item.folder;
  return <Object?>[
    ref,
    e.item.title,
    e.item.creator == null || e.item.creator!.isEmpty ? null : e.item.creator,
    e.item.year,
    folder == null || folder.isEmpty ? null : folder,
    <String>[
      for (final int id in e.collectionIds)
        if (visibleCollections.contains(id)) libraryCollectionRef(id),
    ],
    endpointRef == ref ? null : endpointRef,
  ];
}

/// 合集成员行 `(mediaType, entryKey)` → 关系端点（与 `work_graph_loader.dart` 的成员
/// 换算同口径）：epub uid → `book:<bookKey>`；视频 → `video_episode:<bookUid>`；
/// 游戏 → `game:<id>`；字幕书在调用方能给出配对书时归到那本书，否则没有端点。
MediaLinkEndpoint? libraryItemEndpoint(
  String mediaType,
  String entryKey,
  Map<String, String> bookKeyByUid,
) => switch (MediaKind.tryParse(mediaType)) {
  MediaKind.epub => switch (bookKeyByUid[entryKey]) {
    final String bookKey => (kind: MediaLinkKind.book, key: bookKey),
    null => null,
  },
  MediaKind.video => (kind: MediaLinkKind.videoEpisode, key: entryKey),
  MediaKind.game => (kind: MediaLinkKind.game, key: entryKey),
  MediaKind.srt || null => null,
};

// ── summary ───────────────────────────────────────────────────────────

Future<Map<String, Object?>> _summaryView(
  FushiDatabase db,
  MediaLockSnapshot locks,
) async {
  final Map<String, Object?> domains = <String, Object?>{};
  for (final CollectionShelfDomain d in CollectionShelfDomain.values) {
    final _DomainMap map = await _loadDomain(db, d, locks);
    final Set<int> visible = <int>{
      for (final OrganizeCollectionFact c in map.collections) c.id,
    };
    final Map<String, int> byOrigin = <String, int>{
      for (final CollectionOrigin o in CollectionOrigin.values) o.dbValue: 0,
    };
    for (final OrganizeCollectionFact c in map.collections) {
      byOrigin[c.origin.dbValue] = byOrigin[c.origin.dbValue]! + 1;
    }
    domains[_domainWireName(d)] = <String, Object?>{
      'items': map.entries.length,
      'loose': map.entries
          .where((OrganizeEntry e) => !e.collectionIds.any(visible.contains))
          .length,
      'collections': map.collections.length,
      'collectionsByOrigin': byOrigin,
    };
  }
  final _LinkWorld world = await _loadLinkWorld(db, locks);
  final Map<String, int> byState = <String, int>{
    _stateUser: 0,
    _stateAi: 0,
    _stateSuggested: 0,
  };
  for (final _Edge e in world.edges) {
    byState[e.state] = byState[e.state]! + 1;
  }
  return <String, Object?>{
    'view': LibraryMapView.summary.wireName,
    'domains': domains,
    'links': <String, Object?>{'total': world.edges.length, ...byState},
    'works': world.works.length,
  };
}

String _domainWireName(CollectionShelfDomain d) => switch (d) {
  CollectionShelfDomain.books => LibraryMapView.books.wireName,
  CollectionShelfDomain.manga => LibraryMapView.manga.wireName,
  CollectionShelfDomain.video => LibraryMapView.video.wireName,
  CollectionShelfDomain.games => LibraryMapView.games.wireName,
};

// ── links ─────────────────────────────────────────────────────────────

const String _stateUser = 'user';
const String _stateAi = 'ai';
const String _stateSuggested = 'suggested';

/// 一条存活、两端都可见的连接。
class _Edge {
  _Edge(this.from, this.relation, this.to, this.state, this.source, this.role);

  final MediaLinkEndpoint from;
  final MediaLinkRelation relation;
  final MediaLinkEndpoint to;
  final String state;
  final String source;
  final String? role;
}

/// 一组端点：一部作品，或不属于作品、只被建议态 / 卫星连接串起来的端点。
class _Group {
  _Group({required this.isWork, required this.members});

  final bool isWork;
  final List<MediaLinkEndpoint> members;
  final List<_Edge> edges = <_Edge>[];
}

class _LinkWorld {
  _LinkWorld(this.edges, this.works);

  final List<_Edge> edges;

  /// 关系图里可见成员（去掉上锁的）仍 ≥ 2 的作品。只剩一个可见成员的不算作品：
  /// 它的另一半是上锁的作品，报成「作品」等于泄露那里有东西；剩下的那个端点照常
  /// 按非作品端点处理。
  final List<Work> works;
}

bool _endpointLocked(MediaLockSnapshot locks, MediaLinkEndpoint e) =>
    switch (e.kind) {
      MediaLinkKind.book ||
      MediaLinkKind.audiobook => locks.isBookLocked(e.key),
      MediaLinkKind.videoEpisode => locks.isVideoLocked(e.key),
      MediaLinkKind.videoCollection => switch (int.tryParse(e.key)) {
        final int id => locks.isCollectionLocked(id),
        null => false,
      },
      MediaLinkKind.game => locks.isGameLocked(e.key),
      MediaLinkKind.musicAlbum => locks.isMusicAlbumLocked(e.key),
      MediaLinkKind.musicTrack => locks.isMusicTrackLocked(e.key),
    };

Future<_LinkWorld> _loadLinkWorld(
  FushiDatabase db,
  MediaLockSnapshot locks, {
  WorkGraph? graph,
}) async {
  final List<_Edge> edges = <_Edge>[];
  for (final MediaLinkRow row in await db.allMediaLinks()) {
    if (row.deletedAt != null) continue; // 墓碑（删除 / 否决）不给。
    final MediaLinkKind? fromKind = MediaLinkKind.tryParse(row.fromKind);
    final MediaLinkKind? toKind = MediaLinkKind.tryParse(row.toKind);
    final MediaLinkRelation? relation = MediaLinkRelation.tryParse(
      row.relation,
    );
    if (fromKind == null || toKind == null || relation == null) continue;
    final MediaLinkEndpoint from = (kind: fromKind, key: row.fromKey);
    final MediaLinkEndpoint to = (kind: toKind, key: row.toKey);
    if (_endpointLocked(locks, from) || _endpointLocked(locks, to)) continue;
    edges.add(
      _Edge(
        from,
        relation,
        to,
        switch (mediaLinkConfirmerOf(row)) {
          MediaLinkConfirmer.user => _stateUser,
          MediaLinkConfirmer.ai => _stateAi,
          _ => _stateSuggested,
        },
        row.source,
        row.role,
      ),
    );
  }
  final WorkGraph g = graph ?? await loadWorkGraph(db);
  final List<Work> works = <Work>[
    for (final Work w in g.works)
      if (w.members
              .where((MediaLinkEndpoint m) => !_endpointLocked(locks, m))
              .length >=
          2)
        w,
  ];
  return _LinkWorld(edges, works);
}

Future<Map<String, Object?>> _linksView(
  FushiDatabase db,
  LibraryMapQuery query,
  MediaLockSnapshot locks,
  String? filter,
) async {
  final WorkGraph graph = await loadWorkGraph(db);
  final _LinkWorld world = await _loadLinkWorld(db, locks, graph: graph);

  // 作品组：关系图里的每部作品一组（成员去掉上锁的）。
  final List<_Group> groups = <_Group>[];
  final Map<MediaLinkEndpoint, _Group> groupOfMember =
      <MediaLinkEndpoint, _Group>{};
  for (final Work w in world.works) {
    final _Group g = _Group(
      isWork: true,
      members: <MediaLinkEndpoint>[
        for (final MediaLinkEndpoint m in w.members)
          if (!_endpointLocked(locks, m)) m,
      ],
    );
    groups.add(g);
    for (final MediaLinkEndpoint m in g.members) {
      groupOfMember[m] = g;
    }
  }

  // 连接归组：
  // - 一端在作品里：归那部作品（两端各在一部作品里时归 from 那部——系列连接
  //   「前作 → 续作」挂在前作上，卫星连接「作品 → 音乐」挂在作品上）；
  // - 两端都不在作品里：两端并成一个非作品组（建议态连接、孤立条目的卫星连接）。
  final _UnionFind<MediaLinkEndpoint> loose = _UnionFind<MediaLinkEndpoint>();
  final List<_Edge> looseEdges = <_Edge>[];
  for (final _Edge e in world.edges) {
    final _Group? owner = groupOfMember[e.from] ?? groupOfMember[e.to];
    if (owner != null) {
      owner.edges.add(e);
    } else {
      loose.union(e.from, e.to);
      looseEdges.add(e);
    }
  }
  final Map<MediaLinkEndpoint, _Group> looseByRoot =
      <MediaLinkEndpoint, _Group>{};
  final List<MediaLinkEndpoint> looseEndpoints = loose.elements.toList()
    ..sort(compareMediaLinkEndpoints);
  for (final MediaLinkEndpoint ep in looseEndpoints) {
    (looseByRoot[loose.find(ep)] ??= _Group(
      isWork: false,
      members: <MediaLinkEndpoint>[],
    )).members.add(ep);
  }
  for (final _Edge e in looseEdges) {
    looseByRoot[loose.find(e.from)]!.edges.add(e);
  }
  groups.addAll(
    looseByRoot.values.toList()..sort(
      (_Group a, _Group b) =>
          compareMediaLinkEndpoints(a.members.first, b.members.first),
    ),
  );
  for (final _Group g in groups) {
    g.edges.sort(_compareEdges);
  }

  final _EndpointTitles titles = await _EndpointTitles.load(
    db,
    <MediaLinkEndpoint>{
      for (final _Group g in groups) ...g.members,
      for (final _Edge e in world.edges) ...<MediaLinkEndpoint>[e.from, e.to],
    },
  );

  // 编号按全量顺序给（过滤 / 翻页不改编号）。
  List<(int, _Group)> numbered = <(int, _Group)>[
    for (int i = 0; i < groups.length; i++) (i + 1, groups[i]),
  ];
  if (filter != null) {
    bool hit(MediaLinkEndpoint e) =>
        foldMediaTitle(titles.of(e) ?? '').contains(filter);
    numbered = <(int, _Group)>[
      for (final (int, _Group) n in numbered)
        if (n.$2.members.any(hit) ||
            n.$2.edges.any((_Edge e) => hit(e.from) || hit(e.to)))
          n,
    ];
  }

  final int total = numbered.length;
  final int start = query.offset > total ? total : query.offset;
  final int end = start + query.limit > total ? total : start + query.limit;
  final List<(int, _Group)> page = numbered.sublist(start, end);
  final Set<MediaLinkEndpoint> shown = <MediaLinkEndpoint>{};
  final List<List<Object?>> workRows = <List<Object?>>[];
  final List<List<Object?>> edgeRows = <List<Object?>>[];
  for (final (int number, _Group g) in page) {
    shown.addAll(g.members);
    workRows.add(<Object?>[
      number,
      _groupName(g, titles),
      g.isWork,
      <String>[
        for (final MediaLinkEndpoint m in g.members) libraryEndpointRef(m),
      ],
    ]);
    for (final _Edge e in g.edges) {
      shown
        ..add(e.from)
        ..add(e.to);
      edgeRows.add(<Object?>[
        libraryEndpointRef(e.from),
        libraryEndpointRef(e.to),
        e.relation.dbValue,
        e.state,
        e.source,
        e.role,
      ]);
    }
  }
  final List<MediaLinkEndpoint> titled = shown.toList()
    ..sort(compareMediaLinkEndpoints);
  return <String, Object?>{
    'view': LibraryMapView.links.wireName,
    if (query.q != null) 'q': query.q,
    'total': total,
    'offset': start,
    'nextOffset': end < total ? end : null,
    'works': <String, Object?>{
      'columns': libraryMapWorkColumns,
      'rows': workRows,
    },
    'edges': <String, Object?>{
      'columns': libraryMapEdgeColumns,
      'rows': edgeRows,
    },
    'titles': <String, String>{
      for (final MediaLinkEndpoint e in titled)
        if (titles.of(e) case final String t) libraryEndpointRef(e): t,
    },
  };
}

int _compareEdges(_Edge a, _Edge b) {
  final int byFrom = compareMediaLinkEndpoints(a.from, b.from);
  if (byFrom != 0) return byFrom;
  final int byRelation = a.relation.dbValue.compareTo(b.relation.dbValue);
  if (byRelation != 0) return byRelation;
  return compareMediaLinkEndpoints(a.to, b.to);
}

/// 组名：作品优先取视频合集（作品 / 季）的名字，其次取第一个有标题的成员。
String? _groupName(_Group g, _EndpointTitles titles) {
  for (final MediaLinkEndpoint m in g.members) {
    if (m.kind == MediaLinkKind.videoCollection) {
      if (titles.of(m) case final String t) return t;
    }
  }
  for (final MediaLinkEndpoint m in g.members) {
    if (titles.of(m) case final String t) return t;
  }
  return null;
}

/// 端点 → 标题（只读被引用到的那些；本机没有的条目没有标题）。
class _EndpointTitles {
  _EndpointTitles(this._titles);

  final Map<MediaLinkEndpoint, String> _titles;

  String? of(MediaLinkEndpoint e) => _titles[e];

  static Future<_EndpointTitles> load(
    FushiDatabase db,
    Set<MediaLinkEndpoint> endpoints,
  ) async {
    Set<String> keysOf(Set<MediaLinkKind> kinds) => <String>{
      for (final MediaLinkEndpoint e in endpoints)
        if (kinds.contains(e.kind)) e.key,
    };
    final Map<MediaLinkEndpoint, String> out = <MediaLinkEndpoint, String>{};
    void put(MediaLinkKind kind, String key, String? title) {
      if (title == null || title.trim().isEmpty) return;
      out[(kind: kind, key: key)] = title.trim();
    }

    final Set<String> bookKeys = keysOf(<MediaLinkKind>{
      MediaLinkKind.book,
      MediaLinkKind.audiobook,
    });
    if (bookKeys.isNotEmpty) {
      for (final EpubBookMeta b in await db.getEpubBookMetas()) {
        if (!bookKeys.contains(b.bookKey)) continue;
        put(MediaLinkKind.book, b.bookKey, b.title);
        put(MediaLinkKind.audiobook, b.bookKey, b.title);
      }
    }
    final Set<String> videos = keysOf(<MediaLinkKind>{
      MediaLinkKind.videoEpisode,
    });
    if (videos.isNotEmpty) {
      for (final TypedResult r
          in await (db.selectOnly(db.videoBooks)
                ..addColumns(<Expression<Object>>[
                  db.videoBooks.bookUid,
                  db.videoBooks.title,
                ])
                ..where(db.videoBooks.bookUid.isIn(videos)))
              .get()) {
        put(
          MediaLinkKind.videoEpisode,
          r.read(db.videoBooks.bookUid)!,
          r.read(db.videoBooks.title),
        );
      }
    }
    final Set<String> collections = keysOf(<MediaLinkKind>{
      MediaLinkKind.videoCollection,
    });
    if (collections.isNotEmpty) {
      for (final MediaCollectionRow c in await db.getAllMediaCollections()) {
        final String key = '${c.id}';
        if (collections.contains(key)) {
          put(MediaLinkKind.videoCollection, key, c.name);
        }
      }
    }
    final Set<String> games = keysOf(<MediaLinkKind>{MediaLinkKind.game});
    if (games.isNotEmpty) {
      for (final GalgameRow g in await db.getAllGalgames()) {
        if (!games.contains(g.id)) continue;
        put(MediaLinkKind.game, g.id, _customGameName(g) ?? g.name);
      }
    }
    final Set<String> albums = keysOf(<MediaLinkKind>{
      MediaLinkKind.musicAlbum,
    });
    if (albums.isNotEmpty) {
      for (final TypedResult r
          in await (db.selectOnly(db.musicAlbums)
                ..addColumns(<Expression<Object>>[
                  db.musicAlbums.albumUid,
                  db.musicAlbums.title,
                ])
                ..where(db.musicAlbums.albumUid.isIn(albums)))
              .get()) {
        put(
          MediaLinkKind.musicAlbum,
          r.read(db.musicAlbums.albumUid)!,
          r.read(db.musicAlbums.title),
        );
      }
    }
    final Set<String> tracks = keysOf(<MediaLinkKind>{
      MediaLinkKind.musicTrack,
    });
    if (tracks.isNotEmpty) {
      for (final TypedResult r
          in await (db.selectOnly(db.musicTracks)
                ..addColumns(<Expression<Object>>[
                  db.musicTracks.trackUid,
                  db.musicTracks.title,
                ])
                ..where(db.musicTracks.trackUid.isIn(tracks)))
              .get()) {
        put(
          MediaLinkKind.musicTrack,
          r.read(db.musicTracks.trackUid)!,
          r.read(db.musicTracks.title),
        );
      }
    }
    return _EndpointTitles(out);
  }
}

/// 游戏的用户改名（`customDataJson.name`，与整理器的游戏标题同口径）。
String? _customGameName(GalgameRow g) {
  final String? raw = g.customDataJson;
  if (raw == null || raw.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map && decoded['name'] is String) {
      final String n = (decoded['name'] as String).trim();
      return n.isEmpty ? null : n;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// 端点并查集（只给非作品组用，规模 = 不在作品里的连接端点数）。
class _UnionFind<T> {
  final Map<T, T> _parent = <T, T>{};

  Iterable<T> get elements => _parent.keys;

  T find(T x) {
    T root = _parent.putIfAbsent(x, () => x);
    while (root != _parent[root]) {
      root = _parent[root] as T;
    }
    T cur = x;
    while (cur != root) {
      final T next = _parent[cur] as T;
      _parent[cur] = root;
      cur = next;
    }
    return root;
  }

  void union(T a, T b) {
    final T ra = find(a);
    final T rb = find(b);
    if (ra != rb) _parent[rb] = ra;
  }
}
