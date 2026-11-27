/// 媒体服务器剧名合集的「懒收养」（BUG-5601，方案 B）。
///
/// 媒体服务器（Jellyfin / Emby / 飞牛 / Plex）的单集按剧名归组（`mediaServerCollectionOf`）
/// 是客户端**现算**的派生归属，不是任何人存下的数据。从前视频库页每拿到一份目录就把
/// 整台服务器按剧名收养成真合集（`RemoteCollectionAdoptionService.adoptVideos`），几千个
/// 合集、几万条成员行经合集同步扩散到所有设备。现在平时只在内存里按同一口径叠加一层
/// 临时分组（[buildRemoteSeriesOverlay]），用户对某部剧做了会持久化的动作时才物化成真
/// 合集（[materializeRemoteSeriesCollection]）。
///
/// 叠加规则与收养规则（`FushiDatabase._adoptRemoteCollectionMemberInTransaction`）逐条
/// 对齐，同一份目录叠加出来的折叠归属与组内序和「收养落库再读归属」一致：
/// 1. 自然键上有合集级删除哨兵 → 不分组；
/// 2. 成员墓碑 → 这一集不进组；
/// 3. 已有同自然键真合集（重名取最小 id）→ 挂到它上面；它手排过时未落库的集按目录序
///    接在已有成员之后；
/// 4. 没有真合集 → 一个会话内稳定的负 id 虚拟合集行（[VirtualCollectionRegistry]）。
/// 条目已经有真合集主归属的不动（真成员行优先，负 id 不参与「最小 id」比较）。
library;

import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart'
    show OrganizerRemovals;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;

/// 一条派生剧归属：条目键 + 剧合集自然键 + 槽位。
final class RemoteSeriesEntry {
  const RemoteSeriesEntry({
    required this.entryKey,
    required this.name,
    required this.collectionType,
    required this.sortIndex,
  });

  /// 视频条目键（= 远端视频 id = 本机入库后的 bookUid）。
  final String entryKey;
  final String name;
  final String collectionType;
  final int sortIndex;
}

/// 合集自然键的拼接口径（名 NUL 类型）。
String remoteSeriesNaturalKey(String name, String collectionType) =>
    '$name\u0000$collectionType';

/// 派生剧归属的列式快照（一条目一行）。
///
/// 叠加在后台 isolate 里算：用户库规模（3145 部剧 / 84,487 集）在主 isolate 上要
/// 一两百毫秒（BUG-5601 实测）。列式输入跨 isolate 只传引用（字符串是不可变对象，
/// 同一 isolate 组内共享），打包一次约 10ms、发送约 3ms。
final class RemoteSeriesColumns {
  RemoteSeriesColumns({
    required this.entryKeys,
    required this.names,
    required this.types,
    required this.sortIndex,
  }) : assert(
         entryKeys.length == names.length &&
             names.length == types.length &&
             types.length == sortIndex.length,
       );

  static final RemoteSeriesColumns empty = RemoteSeriesColumns(
    entryKeys: const <String>[],
    names: const <String>[],
    types: const <String>[],
    sortIndex: Int32List(0),
  );

  final List<String> entryKeys;
  final List<String> names;
  final List<String> types;
  final Int32List sortIndex;

  int get length => entryKeys.length;
  bool get isEmpty => entryKeys.isEmpty;

  /// 远端视频清单 → 列式快照（没有剧归属的电影等跳过）。
  factory RemoteSeriesColumns.fromVideos(Iterable<RemoteVideoInfo> videos) {
    final List<String> keys = <String>[];
    final List<String> names = <String>[];
    final List<String> types = <String>[];
    final List<int> sorts = <int>[];
    for (final RemoteVideoInfo v in videos) {
      final RemoteCollectionMembership? m = v.collection;
      if (m == null) continue;
      keys.add(v.id);
      names.add(m.collectionName);
      types.add(m.collectionType);
      sorts.add(m.sortIndex);
    }
    return RemoteSeriesColumns(
      entryKeys: keys,
      names: names,
      types: types,
      sortIndex: Int32List.fromList(sorts),
    );
  }

  /// 测试 / 小批量用。
  factory RemoteSeriesColumns.fromEntries(Iterable<RemoteSeriesEntry> entries) {
    final List<RemoteSeriesEntry> list = entries.toList();
    return RemoteSeriesColumns(
      entryKeys: <String>[for (final RemoteSeriesEntry e in list) e.entryKey],
      names: <String>[for (final RemoteSeriesEntry e in list) e.name],
      types: <String>[for (final RemoteSeriesEntry e in list) e.collectionType],
      sortIndex: Int32List.fromList(<int>[
        for (final RemoteSeriesEntry e in list) e.sortIndex,
      ]),
    );
  }

  /// 多份快照首尾相接（多个媒体服务器来源并存；同 id 先到者胜）。
  static RemoteSeriesColumns concat(Iterable<RemoteSeriesColumns> parts) {
    final List<RemoteSeriesColumns> list = <RemoteSeriesColumns>[
      for (final RemoteSeriesColumns c in parts)
        if (!c.isEmpty) c,
    ];
    if (list.isEmpty) return empty;
    if (list.length == 1) return list.single;
    return RemoteSeriesColumns(
      entryKeys: <String>[
        for (final RemoteSeriesColumns c in list) ...c.entryKeys,
      ],
      names: <String>[for (final RemoteSeriesColumns c in list) ...c.names],
      types: <String>[for (final RemoteSeriesColumns c in list) ...c.types],
      sortIndex: Int32List.fromList(<int>[
        for (final RemoteSeriesColumns c in list) ...c.sortIndex,
      ]),
    );
  }
}

/// 叠加要尊重的墓碑知识。
final class RemoteSeriesTombstones {
  const RemoteSeriesTombstones({
    this.deletedCollections = const <String>{},
    this.removedMembers = const <String>{},
  });

  static const RemoteSeriesTombstones none = RemoteSeriesTombstones();

  /// 有合集级删除哨兵的自然键（[remoteSeriesNaturalKey]）。
  final Set<String> deletedCollections;

  /// 视频成员墓碑：`自然键 NUL 条目键`。
  final Set<String> removedMembers;

  /// 从墓碑表行构造。[blocksGrouping] 决定一条合集级哨兵挡不挡临时分组（缺省全挡）。
  factory RemoteSeriesTombstones.fromRows(
    Iterable<CollectionMemberTombstoneRow> rows, {
    bool Function(CollectionMemberTombstoneRow sentinel)? blocksGrouping,
  }) {
    final Set<String> deleted = <String>{};
    final Set<String> removed = <String>{};
    for (final CollectionMemberTombstoneRow t in rows) {
      final String nk = remoteSeriesNaturalKey(
        t.collectionName,
        t.collectionType,
      );
      if (t.mediaType == FushiDatabase.collectionTombstoneSentinel &&
          t.entryKey == FushiDatabase.collectionTombstoneSentinel) {
        if (blocksGrouping == null || blocksGrouping(t)) deleted.add(nk);
      } else if (t.mediaType == MediaKind.video.dbValue) {
        removed.add('$nk\u0000${t.entryKey}');
      }
    }
    return RemoteSeriesTombstones(
      deletedCollections: deleted,
      removedMembers: removed,
    );
  }
}

/// 一次叠加的结果：[primary] / [memberSortIndex] 是**并好**的完整映射（库里读出的
/// 归属 + 叠加新增的键，已有键不动）。
final class RemoteSeriesOverlay {
  const RemoteSeriesOverlay({
    required this.primary,
    required this.memberSortIndex,
    required this.virtualCollections,
    required this.membersByNaturalKey,
  });

  /// 复合键 `video|<id>` → 合集 id（真合集正 id / 虚拟合集负 id）。
  final Map<String, int> primary;

  /// 复合键 → 组内序。
  final Map<String, int> memberSortIndex;

  /// 虚拟合集行（负 id）。
  final Map<int, MediaCollectionRow> virtualCollections;

  /// 自然键 → 本轮叠加进组的成员（过完墓碑、按目录序），物化时据此落成员行。
  final Map<String, List<RemoteSeriesEntry>> membersByNaturalKey;
}

/// 计算一次叠加（纯函数，不读库）。
///
/// [existingPrimary] / [existingMemberSortIndex]：库里读出的折叠归属（已过目录合集
/// 策略）；有主归属的条目不叠加（真成员行优先）。
/// [collections]：全部合集行（按自然键找真合集，重名取最小 id）。
/// [maxSortIndexByCollection]：手排过（`orderUpdatedAt > 0`）的真合集现有成员的最大
/// `sortIndex`，未落库的集接在它后面（与收养的 `_nextCollectionSortIndex` 同口径）。
/// [registry]：分配虚拟 id；缺省用进程单例。
RemoteSeriesOverlay buildRemoteSeriesOverlay({
  required RemoteSeriesColumns series,
  required Map<String, int> existingPrimary,
  required Map<String, int> existingMemberSortIndex,
  required Iterable<MediaCollectionRow> collections,
  RemoteSeriesTombstones tombstones = RemoteSeriesTombstones.none,
  Map<int, int> maxSortIndexByCollection = const <int, int>{},
  VirtualCollectionRegistry? registry,
}) {
  final VirtualCollectionRegistry ids =
      registry ?? VirtualCollectionRegistry.instance;
  final Map<String, MediaCollectionRow> realByKey =
      <String, MediaCollectionRow>{};
  for (final MediaCollectionRow c in collections) {
    if (c.id <= 0) continue;
    final String nk = remoteSeriesNaturalKey(c.name, c.collectionType);
    final MediaCollectionRow? prev = realByKey[nk];
    if (prev == null || c.id < prev.id) realByKey[nk] = c;
  }
  final Map<String, int> primary = Map<String, int>.of(existingPrimary);
  final Map<String, int> sortIndex = Map<String, int>.of(
    existingMemberSortIndex,
  );
  final Map<int, MediaCollectionRow> virtual = <int, MediaCollectionRow>{};
  final Map<String, List<RemoteSeriesEntry>> members =
      <String, List<RemoteSeriesEntry>>{};
  final Set<String> seen = <String>{};
  final Map<int, int> nextAppend = <int, int>{};
  final String videoPrefix = '${MediaKind.video.dbValue}|';
  final bool anyRemoved = tombstones.removedMembers.isNotEmpty;
  // 目录按剧连续排列：同一部剧的相邻条目复用上一条的裁决，不重复拼键查表。
  String? lastName;
  String? lastType;
  String lastKey = '';
  bool lastBlocked = false;
  MediaCollectionRow? lastTarget;
  List<RemoteSeriesEntry>? lastMembers;
  final int n = series.length;
  for (int i = 0; i < n; i++) {
    final String name = series.names[i];
    final String type = series.types[i];
    if (name != lastName || type != lastType) {
      lastName = name;
      lastType = type;
      lastKey = remoteSeriesNaturalKey(name, type);
      lastBlocked = tombstones.deletedCollections.contains(lastKey);
      if (lastBlocked) {
        lastTarget = null;
        lastMembers = null;
      } else {
        lastTarget = realByKey[lastKey] ?? ids.rowFor(name, type);
        lastMembers = members[lastKey] ??= <RemoteSeriesEntry>[];
      }
    }
    if (lastBlocked) continue;
    final String entryKey = series.entryKeys[i];
    if (anyRemoved &&
        tombstones.removedMembers.contains('$lastKey\u0000$entryKey')) {
      continue;
    }
    final String key = '$videoPrefix$entryKey';
    if (!seen.add(key)) continue; // 多来源同 id：先到者胜。
    final int slot = series.sortIndex[i];
    lastMembers!.add(
      RemoteSeriesEntry(
        entryKey: entryKey,
        name: name,
        collectionType: type,
        sortIndex: slot,
      ),
    );
    if (existingPrimary.containsKey(key)) continue;
    final MediaCollectionRow target = lastTarget!;
    primary[key] = target.id;
    if (target.id < 0) {
      virtual[target.id] = target;
      sortIndex[key] = slot;
    } else if (target.orderUpdatedAt == 0) {
      sortIndex[key] = slot;
    } else {
      final int next =
          nextAppend[target.id] ??
          ((maxSortIndexByCollection[target.id] ?? -1) + 1);
      sortIndex[key] = next;
      nextAppend[target.id] = next + 1;
    }
  }
  members.removeWhere((String _, List<RemoteSeriesEntry> v) => v.isEmpty);
  return RemoteSeriesOverlay(
    primary: primary,
    memberSortIndex: sortIndex,
    virtualCollections: virtual,
    membersByNaturalKey: members,
  );
}

/// 虚拟 id 分配的种子：已知的「自然键 → id」与一段本次独占的新 id 区间起点。
typedef VirtualCollectionSeed = ({Map<String, int> known, int nextId});

/// 会话级虚拟合集登记：自然键 → 负 id（单调分配、不复用），以及最近一次叠加的成员
/// （物化时取）。进程内单例：视频库页、详情页、共享菜单拿到的负 id 都在这里认。
///
/// 叠加在后台 isolate 里算时，主 isolate 先 [reserve] 一段 id 区间作种子，后台用
/// [VirtualCollectionRegistry.seeded] 分配，结果回来再 [absorb]；几次叠加并发时区间
/// 互不相交，同一部剧在两次里拿到不同 id 也都认得（物化按自然键，不按 id）。
final class VirtualCollectionRegistry {
  VirtualCollectionRegistry();

  VirtualCollectionRegistry.seeded(VirtualCollectionSeed seed)
    : _next = seed.nextId {
    seed.known.forEach((String nk, int id) => _knownIds[nk] = id);
  }

  /// 进程单例；构造时把只读钩子装进 [VirtualCollectionHooks]，库里按负 id 读合集行 /
  /// 成员就认这里。
  static final VirtualCollectionRegistry instance = VirtualCollectionRegistry()
    .._installReads();

  void _installReads() {
    VirtualCollectionHooks.rowOf = rowOf;
    VirtualCollectionHooks.itemsOf = itemsOfId;
    VirtualCollectionHooks.materializedIdOf = materializedIdOf;
    VirtualCollectionHooks.materialize = _materializeForWrite;
  }

  /// 写入口经钩子物化用的库（现取：app 关库重开后换新对象）。
  FushiDatabase Function()? _database;

  /// app 打开主库时挂上，库层写入口遇到负 id 才能自己物化。
  void attachDatabase(FushiDatabase Function() database) =>
      _database = database;

  Future<int> _materializeForWrite(int id) async {
    final int? done = _materialized[id];
    if (done != null) return done;
    final FushiDatabase? db = _database?.call();
    final MediaCollectionRow? row = _rowsById[id];
    if (db == null || row == null) {
      throw StateError('unknown virtual collection $id');
    }
    final MediaCollectionRow? real = await materializeRemoteSeriesCollection(
      db,
      row,
      registry: this,
    );
    if (real == null) {
      throw StateError('collection ${row.name} could not be materialized');
    }
    return real.id;
  }

  /// 虚拟 id → 物化后的真合集 id（本会话里物化过的）。
  int? materializedIdOf(int id) => _materialized[id];

  /// 记下某自然键已物化成 [realId]：同自然键的所有虚拟 id 都指过去。
  void markMaterialized(String name, String collectionType, int realId) {
    final String nk = remoteSeriesNaturalKey(name, collectionType);
    _rowsById.forEach((int id, MediaCollectionRow row) {
      if (remoteSeriesNaturalKey(row.name, row.collectionType) == nk) {
        _materialized[id] = realId;
      }
    });
  }

  final Map<String, int> _knownIds = <String, int>{};
  final Map<String, MediaCollectionRow> _rowsByKey =
      <String, MediaCollectionRow>{};
  final Map<int, MediaCollectionRow> _rowsById = <int, MediaCollectionRow>{};
  final Map<int, int> _materialized = <int, int>{};
  Map<String, List<RemoteSeriesEntry>> _members =
      const <String, List<RemoteSeriesEntry>>{};
  int _next = -1;

  /// [name] / [collectionType] 对应的虚拟行（首次见到时分配 id）。
  MediaCollectionRow rowFor(String name, String collectionType) {
    final String nk = remoteSeriesNaturalKey(name, collectionType);
    final MediaCollectionRow? known = _rowsByKey[nk];
    if (known != null) return known;
    final int id = _knownIds[nk] ?? _next--;
    final MediaCollectionRow row = virtualCollectionRow(
      id: id,
      name: name,
      collectionType: collectionType,
    );
    _knownIds[nk] = id;
    _rowsByKey[nk] = row;
    _rowsById[id] = row;
    return row;
  }

  /// 给后台叠加的种子：已知 id + 独占 [count] 个新 id 的区间。
  VirtualCollectionSeed reserve(int count) {
    final int start = _next;
    _next -= count < 1 ? 1 : count;
    return (known: Map<String, int>.of(_knownIds), nextId: start);
  }

  /// 收下一次（后台）叠加的结果：认下它分配的虚拟行，记下成员（按自然键覆盖）。
  void absorb(RemoteSeriesOverlay overlay) {
    overlay.virtualCollections.forEach((int id, MediaCollectionRow row) {
      final String nk = remoteSeriesNaturalKey(row.name, row.collectionType);
      _rowsById[id] = row;
      _knownIds.putIfAbsent(nk, () => id);
      _rowsByKey.putIfAbsent(nk, () => row);
    });
    if (overlay.membersByNaturalKey.isEmpty) return;
    _members = <String, List<RemoteSeriesEntry>>{
      ..._members,
      ...overlay.membersByNaturalKey,
    };
  }

  /// 负 id → 虚拟行；不认识返回 null。
  MediaCollectionRow? rowOf(int id) => _rowsById[id];

  /// 负 id → 叠加里的成员，形状同库里的成员行（[FushiDatabase.getCollectionItems] 的
  /// 排序：sortIndex → entryKey）。不认识的 id 返回 null。
  List<MediaCollectionItemRow>? itemsOfId(int id) {
    final MediaCollectionRow? row = _rowsById[id];
    if (row == null) return null;
    final List<MediaCollectionItemRow> items =
        <MediaCollectionItemRow>[
          for (final RemoteSeriesEntry e in membersOf(
            row.name,
            row.collectionType,
          ))
            MediaCollectionItemRow(
              collectionId: id,
              mediaType: MediaKind.video.dbValue,
              entryKey: e.entryKey,
              sortIndex: e.sortIndex,
              pinnedByUser: false,
            ),
        ]..sort((MediaCollectionItemRow a, MediaCollectionItemRow b) {
          final int bySlot = a.sortIndex.compareTo(b.sortIndex);
          return bySlot != 0 ? bySlot : a.entryKey.compareTo(b.entryKey);
        });
    return items;
  }

  /// 最近一次叠加里该自然键的成员。
  List<RemoteSeriesEntry> membersOf(String name, String collectionType) =>
      _members[remoteSeriesNaturalKey(name, collectionType)] ??
      const <RemoteSeriesEntry>[];

  /// 只给测试：清空登记。
  void debugReset() {
    _knownIds.clear();
    _rowsByKey.clear();
    _rowsById.clear();
    _materialized.clear();
    _members = const <String, List<RemoteSeriesEntry>>{};
    _next = -1;
  }
}

/// 虚拟合集行的形状：和收养新建的行同样的默认值（`origin = user`、没有封面 / 偏好 /
/// 分组键），`sortOrder` 排在全部真合集之后。
MediaCollectionRow virtualCollectionRow({
  required int id,
  required String name,
  required String collectionType,
}) => MediaCollectionRow(
  id: id,
  name: name,
  collectionType: collectionType,
  sortOrder: 1 << 30,
  createdAt: 0,
  orderUpdatedAt: 0,
  origin: CollectionOrigin.user.dbValue,
  organizeAliases: '',
);

/// 合集行是不是叠加出来的虚拟行（还没落库）。
bool isVirtualCollection(MediaCollectionRow row) => row.id < 0;

/// 写入前把（可能是虚拟的）合集行落成真合集，返回真行；真行原样返回。
///
/// 物化 = 把这部剧当前叠加里的全部成员按收养规则一次事务落库，并把写入的成员钉住
/// （`pinned_by_user`：「用户动过这部剧」随同步各端可见，存量清理据此保留它）。
/// [userIntent] 为真（改名、打标签、排序等用户动作）时撤销该自然键的合集删除与本机
/// AI 整理的移出，与「加入媒体库」同一语义；为假（下载落地）时用户删过这部剧的合集
/// 就让路，返回 null。
///
/// 进程内按自然键单飞：两个入口同时触发也只跑一次事务。
Future<MediaCollectionRow?> materializeRemoteSeriesCollection(
  FushiDatabase database,
  MediaCollectionRow row, {
  bool userIntent = true,
  VirtualCollectionRegistry? registry,
}) {
  if (!isVirtualCollection(row)) {
    return Future<MediaCollectionRow?>.value(row);
  }
  final VirtualCollectionRegistry ids =
      registry ?? VirtualCollectionRegistry.instance;
  final int? done = ids.materializedIdOf(row.id);
  if (done != null) return database.getMediaCollectionById(done);
  return materializeRemoteSeries(
    database,
    name: row.name,
    collectionType: row.collectionType,
    members: ids.membersOf(row.name, row.collectionType),
    userIntent: userIntent,
  ).then((MediaCollectionRow? real) {
    if (real != null) {
      ids.markMaterialized(row.name, row.collectionType, real.id);
    }
    return real;
  });
}

/// 按自然键物化（[materializeRemoteSeriesCollection] 的本体；下载落地等手上只有剧名
/// 与成员、没有虚拟行的入口直接用它）。
Future<MediaCollectionRow?> materializeRemoteSeries(
  FushiDatabase database, {
  required String name,
  required String collectionType,
  required List<RemoteSeriesEntry> members,
  bool userIntent = true,
}) {
  final String nk = remoteSeriesNaturalKey(name, collectionType);
  final Future<MediaCollectionRow?>? running = _inFlight[nk];
  if (running != null) return running;
  final Future<MediaCollectionRow?> run =
      _materialize(
        database,
        name: name,
        collectionType: collectionType,
        members: members,
        userIntent: userIntent,
      ).whenComplete(() {
        // 块体：`=> _inFlight.remove(nk)` 会返回被移除的 future 本身，whenComplete
        // 再去等它就成了自己等自己。
        _inFlight.remove(nk);
      });
  _inFlight[nk] = run;
  return run;
}

final Map<String, Future<MediaCollectionRow?>> _inFlight =
    <String, Future<MediaCollectionRow?>>{};

Future<MediaCollectionRow?> _materialize(
  FushiDatabase database, {
  required String name,
  required String collectionType,
  required List<RemoteSeriesEntry> members,
  required bool userIntent,
}) async {
  final OrganizerRemovals removals = userIntent
      ? await OrganizerRemovals.load(database, collectionNames: <String>{name})
      : OrganizerRemovals.none;
  final Map<String, int> organizerRemoved = removals.keysFor(
    collectionName: name,
    collectionType: collectionType,
    mediaType: MediaKind.video.dbValue,
  );
  final int? id = await database.materializeRemoteCollection(
    name: name,
    collectionType: collectionType,
    members: <RemoteCollectionMemberAdoption>[
      for (final RemoteSeriesEntry e in members)
        RemoteCollectionMemberAdoption(
          name: name,
          collectionType: collectionType,
          mediaType: MediaKind.video,
          remoteEntryKey: e.entryKey,
          sortIndex: e.sortIndex,
          localEntryKey: e.entryKey,
          userIntent: userIntent,
          organizerRemovedKeys: organizerRemoved,
        ),
    ],
    userIntent: userIntent,
  );
  if (id == null) return null;
  return database.getMediaCollectionById(id);
}

/// [materializeRemoteSeriesCollection] 的「必须拿到真行」版（用户意图）：写入入口
/// 用它，真行原样返回。
Future<MediaCollectionRow> ensurePersistedCollection(
  FushiDatabase database,
  MediaCollectionRow row,
) async {
  final MediaCollectionRow? persisted = await materializeRemoteSeriesCollection(
    database,
    row,
  );
  if (persisted == null) {
    throw StateError('collection ${row.name} could not be materialized');
  }
  return persisted;
}
