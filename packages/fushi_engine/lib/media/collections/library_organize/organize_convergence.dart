import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/collections/collection_merge.dart';
import 'package:fushi_engine/sync/collection_book_identity_index.dart';

/// 整理收敛（AI 整理库 spec `docs/specs/2026-10-20-ai-library-organize-design.md` §8）。
///
/// ## 为什么不是锁
///
/// 多台设备各自整理自己的库、离线、按任意顺序同步——没有能仲裁的在线方，「同一时刻
/// 只许一台整理」做不到。规则归组从来不冲突，是因为同样的输入在每台设备上算出同一个
/// 合集名；AI 起的名字不确定，所以换一种同样确定的身份：**分组键**
/// （[MediaCollections.organizeKey] + 吸收过的别名）。
///
/// ## 这一步做什么
///
/// 每次同步落盘后、每次本机整理后跑一遍：同一个系列的整理器合集（键相同、键在对方
/// 别名里、或成员大量重叠）在本机合成一个。胜方选择只看**同步清单里看得见的字段**
/// （名字、类型、来源、键、别名、wire 成员键），所以每台设备独立算出同一个胜方；
/// 合并本身走普通的「加成员 + 删合集」，经现有合集同步（成员并集 + 墓碑）传播。
/// 旧对端把败方复活了也没关系：下一轮收敛照样并回来。
///
/// 用户的合集（`origin == user`）永远不当败方；只有它带着同一个分组键时才参与，
/// 并且当胜方（整理器合集并进用户合集，与用户手动「加入合集」同构）。

/// 收敛规划的一个输入（只含跨端可见的字段）。
class ConvergenceCollection {
  const ConvergenceCollection({
    required this.id,
    required this.name,
    required this.collectionType,
    required this.origin,
    required this.organizeKey,
    required this.organizeAliases,
    required this.memberWireKeys,
  });

  final int id;
  final String name;
  final String collectionType;
  final CollectionOrigin origin;
  final String? organizeKey;
  final Set<String> organizeAliases;

  /// 成员 wire 键（`mediaType NUL wireEntryKey`）。
  final Set<String> memberWireKeys;

  Set<String> get identityKeys => <String>{
        if (organizeKey != null) organizeKey!,
        ...organizeAliases,
      };

  /// 粗粒度域（只看 wire 成员种类）：书 / 视频 / 游戏。
  Set<String> get wireDomains => <String>{
        for (final String k in memberWireKeys)
          wireDomainOfMediaType(k.substring(0, k.indexOf('\u0000'))),
      };

  bool get participates =>
      origin.isOrganizerManaged ||
      (origin == CollectionOrigin.user && organizeKey != null);
}

/// 一次合并：[sourceIds] 并进 [targetId]。
class ConvergenceMerge {
  const ConvergenceMerge({required this.targetId, required this.sourceIds});

  final int targetId;
  final List<int> sourceIds;

  @override
  String toString() => 'ConvergenceMerge($targetId <- $sourceIds)';
}

/// 成员种类 → 粗粒度域。书与漫画同为 `epub`，在这一层不分（区分它们要读本机书格式，
/// 各端不一致）；标题键里带着 `<domain>`，重叠又要求共享成员，所以不会错并。
String wireDomainOfMediaType(String mediaType) {
  if (mediaType == MediaKind.video.dbValue) return 'video';
  if (mediaType == MediaKind.game.dbValue) return 'game';
  return 'book';
}

/// 两个整理器合集的成员重叠到这个比例（相对小的一方）就视为同一个系列。
const double kConvergenceOverlapRatio = 0.5;

/// 纯函数：从全部合集算出要做的合并。与输入顺序无关、幂等（对输出执行后再跑一遍
/// 得到空计划）。
List<ConvergenceMerge> planOrganizeConvergence(
  List<ConvergenceCollection> collections,
) {
  final List<ConvergenceCollection> parts = <ConvergenceCollection>[
    for (final ConvergenceCollection c in collections)
      if (c.participates && c.memberWireKeys.isNotEmpty) c,
  ]..sort(_byStableIdentity);
  final int n = parts.length;
  final List<int> parent = List<int>.generate(n, (int i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  void union(int a, int b) {
    final int ra = find(a);
    final int rb = find(b);
    if (ra != rb) parent[ra < rb ? rb : ra] = ra < rb ? ra : rb;
  }

  // 分组键 → 持有它的参与者（键或别名）。
  final Map<String, List<int>> byKey = <String, List<int>>{};
  for (int i = 0; i < n; i++) {
    for (final String k in parts[i].identityKeys) {
      (byKey[k] ??= <int>[]).add(i);
    }
  }
  for (final List<int> holders in byKey.values) {
    for (int j = 1; j < holders.length; j++) {
      if (_sameDomain(parts[holders[0]], parts[holders[j]])) {
        union(holders[0], holders[j]);
      }
    }
  }
  // 成员重叠：只在两个整理器合集之间（用户合集只认键，不因为碰巧有重叠成员被吞）。
  final Map<String, List<int>> byMember = <String, List<int>>{};
  for (int i = 0; i < n; i++) {
    if (!parts[i].origin.isOrganizerManaged) continue;
    for (final String m in parts[i].memberWireKeys) {
      (byMember[m] ??= <int>[]).add(i);
    }
  }
  final Map<int, Map<int, int>> shared = <int, Map<int, int>>{};
  for (final List<int> holders in byMember.values) {
    for (int a = 0; a < holders.length; a++) {
      for (int b = a + 1; b < holders.length; b++) {
        final Map<int, int> row = shared[holders[a]] ??= <int, int>{};
        row[holders[b]] = (row[holders[b]] ?? 0) + 1;
      }
    }
  }
  shared.forEach((int a, Map<int, int> row) {
    row.forEach((int b, int count) {
      final int smaller = parts[a].memberWireKeys.length <
              parts[b].memberWireKeys.length
          ? parts[a].memberWireKeys.length
          : parts[b].memberWireKeys.length;
      if (count >= smaller * kConvergenceOverlapRatio) union(a, b);
    });
  });

  final Map<int, List<ConvergenceCollection>> components =
      <int, List<ConvergenceCollection>>{};
  for (int i = 0; i < n; i++) {
    (components[find(i)] ??= <ConvergenceCollection>[]).add(parts[i]);
  }
  final List<ConvergenceMerge> plan = <ConvergenceMerge>[];
  for (final List<ConvergenceCollection> group in components.values) {
    if (group.length < 2) continue;
    group.sort(_winnerOrder);
    final ConvergenceCollection winner = group.first;
    final List<int> sources = <int>[
      for (final ConvergenceCollection c in group.skip(1))
        // 用户合集永不当败方。
        if (c.origin.isOrganizerManaged) c.id,
    ];
    if (sources.isEmpty) continue;
    plan.add(ConvergenceMerge(targetId: winner.id, sourceIds: sources));
  }
  plan.sort(
    (ConvergenceMerge a, ConvergenceMerge b) =>
        a.targetId.compareTo(b.targetId),
  );
  return plan;
}

bool _sameDomain(ConvergenceCollection a, ConvergenceCollection b) =>
    a.wireDomains.intersection(b.wireDomains).isNotEmpty;

/// 输入的稳定序（本地 id 各端不同，不能用）：名字、类型。
int _byStableIdentity(ConvergenceCollection a, ConvergenceCollection b) {
  final int byName = a.name.compareTo(b.name);
  if (byName != 0) return byName;
  return a.collectionType.compareTo(b.collectionType);
}

/// 胜方序：用户合集优先；再按规范分组键（外部 id 键优先、字典序）；没键的排后；
/// 最后按名字 / 类型。全部是跨端可见字段，各端选出同一个胜方。
int _winnerOrder(ConvergenceCollection a, ConvergenceCollection b) {
  final bool aUser = a.origin == CollectionOrigin.user;
  final bool bUser = b.origin == CollectionOrigin.user;
  if (aUser != bUser) return aUser ? -1 : 1;
  final String? ak = a.organizeKey;
  final String? bk = b.organizeKey;
  if (ak != null && bk == null) return -1;
  if (ak == null && bk != null) return 1;
  if (ak != null && bk != null) {
    final int byKey = compareOrganizeKeys(ak, bk);
    if (byKey != 0) return byKey;
  }
  return _byStableIdentity(a, b);
}

/// 从库里取收敛输入。
Future<List<ConvergenceCollection>> loadConvergenceCollections(
  FushiDatabase db,
) async {
  final CollectionBookIdentityIndex identities =
      await CollectionBookIdentityIndex.load(db);
  final Map<int, Set<String>> membersById = <int, Set<String>>{};
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    (membersById[item.collectionId] ??= <String>{}).add(
      '${item.mediaType}\u0000'
      '${identities.wireKey(item.mediaType, item.entryKey)}',
    );
  }
  return <ConvergenceCollection>[
    for (final MediaCollectionRow row in await db.getAllMediaCollections())
      ConvergenceCollection(
        id: row.id,
        name: row.name,
        collectionType: row.collectionType,
        origin: CollectionOrigin.parse(row.origin),
        organizeKey: row.organizeKey,
        organizeAliases: decodeOrganizeAliases(row.organizeAliases),
        memberWireKeys: membersById[row.id] ?? const <String>{},
      ),
  ];
}

/// 在本机执行收敛。返回被并掉的合集数。
///
/// 合并走 [mergeMediaCollectionsInto]（`userIntent: false`：不把胜方转成用户的；
/// 跳过胜方里用户移出过的成员）。
Future<int> convergeOrganizedCollections(FushiDatabase db) async {
  final List<ConvergenceMerge> plan = planOrganizeConvergence(
    await loadConvergenceCollections(db),
  );
  int merged = 0;
  for (final ConvergenceMerge m in plan) {
    merged += await mergeMediaCollectionsInto(
      db,
      targetId: m.targetId,
      sourceIds: m.sourceIds,
      userIntent: false,
      skipTombstonedInTarget: true,
    );
  }
  if (merged > 0) {
    engineLog.logDiagnostic(
      'organizeConvergence',
      'merged $merged collection(s): $plan',
    );
  }
  return merged;
}
