/// 作品图（[WorkGraph]）的进程级缓存（AI 库管家 spec
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §4.2「结果随 `media_links` /
/// 合集成员表的 `tableUpdates` 失效重算，不持久化」）。
///
/// 一个数据库一份 [WorkGraphStore]（[WorkGraphStore.of]），详情页「同一作品」区块、
/// 关系网页、库页卡片角标都从这里取同一张图，不各自全库重算：
///
/// - 首个监听者挂上时读库建图（[loadWorkGraph] + 本文件补读的展示索引）；
/// - 监听建图读到的全部表（[workGraphSourceTables]：`media_links`、合集与成员、
///   `epub_books`、`srt_books`、刮削作品与外部身份；展示索引读的表是它的子集）的
///   `tableUpdates`，变更后去抖 [WorkGraphStore.debounce] 再整张重建（导入一批书
///   会连发几百次表变更，只重建一次）；重建进行中又来变更，结束后补建一次；
/// - 没有监听者时不跑去抖计时器，只记「脏」，下一个监听者挂上时补建——页面都关了
///   就不在后台反复读库，测试里也不留悬空计时器。
///
/// 与 `MediaLinksSection` 的 `_tableSub` 同一种订阅形态（`tableUpdates` 手动订阅，
/// 不用 drift `.watch()`，见 BUG-834 范式）；对外是 [ValueListenable]，不依赖
/// Riverpod（区块与弹窗拿到的只是 `FushiDatabase`）。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show QueryRow, ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart';

/// 「同一作品」区块与关系网的媒体分组（spec §4.3：小说 / 漫画 / 动画 / 游戏 /
/// 有声书）。顺序即界面上的分组顺序。
enum WorkMediaGroup { novel, manga, anime, game, audiobook, music }

/// 作品里的一个系列合集（同一合集的各卷在界面上折成一张卡 / 一个节点）。
@immutable
final class WorkSeriesInfo {
  const WorkSeriesInfo({
    required this.id,
    required this.name,
    required this.members,
    this.endpoint,
  });

  /// `MediaCollections.id`。
  final int id;

  /// 合集名（spec §4.2 表：合集卡取合集名）。
  final String name;

  /// 合集本身的图谱端点（视频合集有，书 / 游戏合集没有）。
  final MediaLinkEndpoint? endpoint;

  /// 落在作品图里的成员端点，按 [compareMediaLinkEndpoints] 升序，非空。
  final List<MediaLinkEndpoint> members;

  /// 折叠卡 / 节点点了打开谁：视频合集开合集详情页；书 / 游戏合集开最小端点
  /// （漫画会进作品页，小说是第一卷）。
  MediaLinkEndpoint get openTarget => endpoint ?? members.first;

  /// 卷数（不含合集端点自身）。
  int get volumeCount => members.length;

  /// [e] 是否属于本合集（成员或合集端点）。
  bool covers(MediaLinkEndpoint e) => endpoint == e || members.contains(e);
}

/// 一次建图的结果：作品图 + 界面要的展示索引（书的格式、系列合集的成员与名字、
/// 视频合集的刮削相关作品）。
final class WorkGraphSnapshot {
  WorkGraphSnapshot({
    required this.graph,
    required Map<String, String> bookFormatByKey,
    required List<WorkSeriesInfo> series,
    List<CollectionRelationRow> collectionRelations =
        const <CollectionRelationRow>[],
  }) : _bookFormatByKey = bookFormatByKey,
       _relationsByCollection = _groupRelations(collectionRelations),
       _seriesById = <int, WorkSeriesInfo>{
         for (final WorkSeriesInfo s in series) s.id: s,
       } {
    // 一个端点可能同时在几个系列合集里：归到成员最多的那个（同规模取 id 小者），
    // 与作品代表端点「成员最多的系列合集」同一取向，结果与输入顺序无关。
    final List<WorkSeriesInfo> ordered = series.toList()
      ..sort((WorkSeriesInfo a, WorkSeriesInfo b) {
        final int bySize = b.members.length.compareTo(a.members.length);
        return bySize != 0 ? bySize : a.id.compareTo(b.id);
      });
    for (final WorkSeriesInfo s in ordered) {
      for (final MediaLinkEndpoint e in <MediaLinkEndpoint>[
        ?s.endpoint,
        ...s.members,
      ]) {
        _seriesOfEndpoint.putIfAbsent(e, () => s);
      }
    }
  }

  final WorkGraph graph;
  final Map<String, String> _bookFormatByKey;
  final Map<int, List<CollectionRelationRow>> _relationsByCollection;

  static Map<int, List<CollectionRelationRow>> _groupRelations(
    List<CollectionRelationRow> rows,
  ) {
    final Map<int, List<CollectionRelationRow>> out =
        <int, List<CollectionRelationRow>>{};
    for (final CollectionRelationRow r in rows) {
      (out[r.collectionId] ??= <CollectionRelationRow>[]).add(r);
    }
    for (final List<CollectionRelationRow> list in out.values) {
      list.sort((CollectionRelationRow a, CollectionRelationRow b) {
        final int bySort = a.sortIndex.compareTo(b.sortIndex);
        return bySort != 0 ? bySort : a.id.compareTo(b.id);
      });
    }
    return out;
  }

  /// 视频合集 [collectionId] 的相关作品（`collection_relations`：刮削源的续作 /
  /// 前传 / 外传…与按季拆分建的前后作），按展示顺序。关系网的系列栏从这里取。
  List<CollectionRelationRow> collectionRelationsOf(int collectionId) =>
      _relationsByCollection[collectionId] ?? const <CollectionRelationRow>[];
  final Map<int, WorkSeriesInfo> _seriesById;
  final Map<MediaLinkEndpoint, WorkSeriesInfo> _seriesOfEndpoint =
      <MediaLinkEndpoint, WorkSeriesInfo>{};

  /// 作品 → 它含的媒体分组（按作品身份键缓存：库页几千张卡反复问同几部作品）。
  final Map<MediaLinkEndpoint, Set<WorkMediaGroup>> _groupsByWork =
      <MediaLinkEndpoint, Set<WorkMediaGroup>>{};

  /// 端点折进哪个系列合集（没有返回 null）。
  WorkSeriesInfo? seriesOf(MediaLinkEndpoint e) => _seriesOfEndpoint[e];

  /// 按 id 取系列合集（不是作品图里的系列合集返回 null）。
  WorkSeriesInfo? seriesById(int id) => _seriesById[id];

  /// 端点的媒体分组。书按 `epub_books.format` 分小说 / 漫画（本机没有这本书时按
  /// 小说算）。
  WorkMediaGroup groupOf(MediaLinkEndpoint e) => switch (e.kind) {
    MediaLinkKind.book =>
      _bookFormatByKey[e.key] == BookFormat.manga.dbValue
          ? WorkMediaGroup.manga
          : WorkMediaGroup.novel,
    MediaLinkKind.audiobook => WorkMediaGroup.audiobook,
    MediaLinkKind.videoCollection ||
    MediaLinkKind.videoEpisode => WorkMediaGroup.anime,
    MediaLinkKind.game => WorkMediaGroup.game,
    MediaLinkKind.musicAlbum ||
    MediaLinkKind.musicTrack => WorkMediaGroup.music,
  };

  /// 作品含的媒体分组。
  Set<WorkMediaGroup> groupsOfWork(Work work) =>
      _groupsByWork[work.identity] ??= <WorkMediaGroup>{
        for (final MediaLinkEndpoint m in work.members) groupOf(m),
      };

  /// 卡片角标：[self] 所在作品里**别的**媒体分组（按分组顺序）。不在任何作品里、
  /// 或作品里只有同种媒体时为空。
  List<WorkMediaGroup> otherGroupsFor(MediaLinkEndpoint self) {
    final Work? work = graph.workOf(self);
    if (work == null || work.members.length < 2) {
      return const <WorkMediaGroup>[];
    }
    return _without(groupsOfWork(work), <WorkMediaGroup>{groupOf(self)});
  }

  /// 合集卡角标：系列合集 [collectionId] 所在作品里合集成员之外的媒体分组。
  /// 不是系列合集（阅读清单等）为空。
  List<WorkMediaGroup> otherGroupsForCollection(int collectionId) {
    final WorkSeriesInfo? series = _seriesById[collectionId];
    if (series == null) return const <WorkMediaGroup>[];
    final Work? work = graph.workOf(series.openTarget);
    if (work == null) return const <WorkMediaGroup>[];
    return _without(groupsOfWork(work), <WorkMediaGroup>{
      for (final MediaLinkEndpoint m in series.members) groupOf(m),
    });
  }

  static List<WorkMediaGroup> _without(
    Set<WorkMediaGroup> all,
    Set<WorkMediaGroup> own,
  ) => <WorkMediaGroup>[
    for (final WorkMediaGroup g in WorkMediaGroup.values)
      if (all.contains(g) && !own.contains(g)) g,
  ];
}

/// 读库建一份 [WorkGraphSnapshot]：图本身经 [loadWorkGraph]（判据单一真源），
/// 这里只补界面要的展示索引，同样整表一次读、内存里 join。
Future<WorkGraphSnapshot> loadWorkGraphSnapshot(FushiDatabase db) async {
  final WorkGraph graph = await loadWorkGraph(db);
  final List<CollectionRelationRow> relations = await db
      .getAllCollectionRelations();
  final List<EpubBookMeta> books = await db.getEpubBookMetas();
  final Map<String, String> formatByKey = <String, String>{
    for (final EpubBookMeta b in books) b.bookKey: b.format,
  };

  // 只有落进某部多成员作品的系列合集才需要折叠信息。
  final Set<int> seriesIds = <int>{
    for (final Work w in graph.works) ...w.seriesCollectionIds,
  };
  if (seriesIds.isEmpty) {
    return WorkGraphSnapshot(
      graph: graph,
      bookFormatByKey: formatByKey,
      series: const <WorkSeriesInfo>[],
      collectionRelations: relations,
    );
  }
  final Map<String, String> bookKeyByUid = <String, String>{
    for (final EpubBookMeta b in books)
      if (b.uid.isNotEmpty) b.uid: b.bookKey,
  };
  final Set<String> bookKeys = formatByKey.keys.toSet();
  final Map<String, String> pairedBookKeyBySrtUid = <String, String>{
    for (final QueryRow r
        in await db.customSelect('SELECT uid, book_key FROM srt_books').get())
      if (bookKeys.contains(r.read<String>('book_key')))
        r.read<String>('uid'): r.read<String>('book_key'),
  };
  final Map<int, String> nameById = <int, String>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      if (seriesIds.contains(c.id)) c.id: c.name,
  };
  final Map<int, Set<MediaLinkEndpoint>> membersById =
      <int, Set<MediaLinkEndpoint>>{};
  for (final MediaCollectionItemRow i in await db.getAllCollectionItems()) {
    if (!seriesIds.contains(i.collectionId)) continue;
    final MediaLinkEndpoint? e = _endpointOfMember(
      i,
      bookKeyByUid,
      pairedBookKeyBySrtUid,
    );
    if (e == null) continue;
    (membersById[i.collectionId] ??= <MediaLinkEndpoint>{}).add(e);
  }

  final List<WorkSeriesInfo> series = <WorkSeriesInfo>[];
  for (final int id in seriesIds) {
    final MediaLinkEndpoint collectionEndpoint = videoCollectionEndpoint(id);
    final Work? collectionWork = graph.workOf(collectionEndpoint);
    // 成员换算与 loader 同口径；再按「确实与合集同在一部作品」过滤一遍，折叠信息
    // 永远不会和图本身打架。
    final List<MediaLinkEndpoint> members = <MediaLinkEndpoint>[
      for (final MediaLinkEndpoint e
          in membersById[id] ?? const <MediaLinkEndpoint>{})
        if (graph.workOf(e) case final Work w
            when w.seriesCollectionIds.contains(id))
          e,
    ]..sort(compareMediaLinkEndpoints);
    final bool hasEndpoint =
        collectionWork != null &&
        collectionWork.seriesCollectionIds.contains(id);
    if (members.isEmpty) continue;
    series.add(
      WorkSeriesInfo(
        id: id,
        name: nameById[id] ?? '',
        endpoint: hasEndpoint ? collectionEndpoint : null,
        members: List<MediaLinkEndpoint>.unmodifiable(members),
      ),
    );
  }
  return WorkGraphSnapshot(
    graph: graph,
    bookFormatByKey: formatByKey,
    series: series,
    collectionRelations: relations,
  );
}

/// 合集成员行 → 图谱端点（与 `work_graph_loader.dart` 的成员换算同口径：epub 键是
/// uid、srt 归到配对的书、视频是单集、游戏是游戏）。
MediaLinkEndpoint? _endpointOfMember(
  MediaCollectionItemRow item,
  Map<String, String> bookKeyByUid,
  Map<String, String> pairedBookKeyBySrtUid,
) {
  if (item.mediaType == MediaKind.epub.dbValue) {
    final String? key = bookKeyByUid[item.entryKey];
    return key == null ? null : (kind: MediaLinkKind.book, key: key);
  }
  if (item.mediaType == MediaKind.srt.dbValue) {
    final String? key = pairedBookKeyBySrtUid[item.entryKey];
    return key == null ? null : (kind: MediaLinkKind.book, key: key);
  }
  if (item.mediaType == MediaKind.video.dbValue) {
    return (kind: MediaLinkKind.videoEpisode, key: item.entryKey);
  }
  if (item.mediaType == MediaKind.game.dbValue) {
    return (kind: MediaLinkKind.game, key: item.entryKey);
  }
  return null;
}

/// 作品图的进程级持有者，见文件头。
final class WorkGraphStore extends ChangeNotifier
    implements ValueListenable<WorkGraphSnapshot?> {
  WorkGraphStore._(this._db);

  static final Expando<WorkGraphStore> _byDatabase = Expando<WorkGraphStore>(
    'WorkGraphStore',
  );

  /// [db] 对应的唯一持有者（首次调用时创建；不订阅、不读库，直到有监听者）。
  static WorkGraphStore of(FushiDatabase db) =>
      _byDatabase[db] ??= WorkGraphStore._(db);

  /// 表变更后的去抖时长。
  @visibleForTesting
  static Duration debounce = const Duration(milliseconds: 400);

  final FushiDatabase _db;
  WorkGraphSnapshot? _value;
  StreamSubscription<Set<TableUpdate>>? _tableSub;
  Timer? _debounceTimer;
  int _listenerCount = 0;
  bool _dirty = true;
  bool _loading = false;

  /// 当前的作品图；首次建图完成前为 null。
  @override
  WorkGraphSnapshot? get value => _value;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    _tableSub ??= _db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              ...workGraphSourceTables(_db),
              // 快照另读的相关作品表（关系网系列栏）：刮削落库 / 升级绑定后刷新。
              _db.collectionRelations,
            ],
          ),
        )
        .listen((Set<TableUpdate> _) => _invalidate());
    if (_dirty) unawaited(_rebuild());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount--;
    if (_listenerCount <= 0) {
      _listenerCount = 0;
      final Timer? pending = _debounceTimer;
      if (pending != null && pending.isActive) {
        pending.cancel();
        _dirty = true;
      }
      _debounceTimer = null;
    }
  }

  void _invalidate() {
    _dirty = true;
    if (_listenerCount == 0) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      unawaited(_rebuild());
    });
  }

  Future<void> _rebuild() async {
    if (_loading || !_dirty) return;
    _loading = true;
    _dirty = false;
    WorkGraphSnapshot? next;
    try {
      next = await loadWorkGraphSnapshot(_db);
    } catch (error, stack) {
      // 读库失败（库已关、迁移中）保留上一份图，下一次表变更再试；不吞成静默空图。
      debugPrint('WorkGraphStore: rebuild failed: $error\n$stack');
    } finally {
      _loading = false;
    }
    if (next != null) {
      _value = next;
      if (_listenerCount > 0) notifyListeners();
    }
    // 重建期间又来了变更：去抖计时器还在等就交给它；它已在重建中途到点（那次被
    // `_loading` 挡回）就立刻补建一次。没有监听者只留脏标记，下个监听者挂上时补。
    if (_dirty && _listenerCount > 0 && _debounceTimer == null) {
      unawaited(_rebuild());
    }
  }

  @override
  void dispose() {
    // 进程级单例不随页面释放；只有测试会显式调。
    _debounceTimer?.cancel();
    unawaited(_tableSub?.cancel());
    super.dispose();
  }
}
