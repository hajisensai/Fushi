import 'package:hibiki/src/sync/collection_manifest.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 合集同步引擎（多端库联合视图 §2.3 任务4）。
///
/// 纯函数核心：输入本地合集全量快照 + 远端清单（都是 [CollectionManifest]），
/// 输出合并后清单 + 本地变更集。IO（清单读写、DB 落盘）由调用方注入——云后端走
/// SyncOrchestrator 的 `__collections__/collections.json` 读-合并-写；互联 host
/// API（任务5/6）就绪后走同一引擎，仅通道不同。
///
/// 合并语义（spec §2.3，全部已拍板）：
/// - 合集按 (name, collectionType) 自然键对齐（复用备份合并的成熟语义）；
/// - 成员**并集 + 移出墓碑**：墓碑 removedAt 晚于本端最后同步基线
///   (lastSyncedAtMs) ⇒「新闻」⇒ 成员删除生效；早于基线 ⇒ 本端早已见过并
///   裁决过该墓碑，此刻成员仍在 ⇒ 是之后的**重新加入**，成员胜、墓碑清除。
///   基线是本端与共享清单的因果分界（「参照 git」模型里的共同祖先时刻）：没有
///   per-成员 addedAt 列，靠它区分「未见过的移出」与「移出后的重加」。
/// - **手动序整合集 LWW**：orderUpdatedAt 新者整表覆盖成员 sortIndex；平手取
///   远端（共享清单）序——两端从未手动排序(=0)时也能收敛到同一顺序，而不是各
///   持己序永久 ping-pong。不做逐成员位置合并（两个排列不存在有意义的合并）。
/// - **合集删除墓碑**（deletedAt，清单 entry 级）防复活；与成员墓碑同一基线
///   规则：晚于基线 ⇒ 删除生效；早于基线且对端活着 ⇒ 对端重建了，合集复活。
class CollectionSyncEngine {
  CollectionSyncEngine._(); // 纯静态引擎，禁实例化。

  /// 合并本地快照与远端清单。[lastSyncedAtMs] 是本端上次**成功**合集同步的毫秒
  /// 戳（0 = 从未同步过：一切墓碑都是新闻，移出/删除全部生效——首次同步语义）。
  ///
  /// [nowMs] 是「发布时刻」——本端首次把一条远端清单里尚无的墓碑/删除写进合并结果时
  /// 给它盖上 publishedAt=now（缺省取当前墙钟）。[localIsPeer] 为 true 时把 [local] 侧
  /// 也当**对端已发布**清单裁决（用 publishedAt 而非 removedAt），供 [combinePeers] 折叠
  /// 多份 per-device 清单；缺省 false（[local] 是本端未发布快照，用 removedAt 本端裁决）。
  /// [stampPublish] 为 false 时不盖 publishedAt（折叠对端清单时保真，不冒充本端发布）。
  static CollectionSyncOutcome merge({
    required CollectionManifest local,
    required CollectionManifest remote,
    required int lastSyncedAtMs,
    int? nowMs,
    bool localIsPeer = false,
    bool stampPublish = true,
  }) {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final Map<String, _NormalizedEntry> lSide = _normalize(local);
    final Map<String, _NormalizedEntry> rSide = _normalize(remote);
    final Set<String> allKeys = <String>{...lSide.keys, ...rSide.keys};
    // 自然键排序遍历：合并结果与遍历顺序无关，但排序让输出/调试稳定。
    final List<String> orderedKeys = allKeys.toList()..sort();

    final List<CollectionManifestEntry> mergedEntries =
        <CollectionManifestEntry>[];
    final List<CollectionManifestEntry> toReconcile =
        <CollectionManifestEntry>[];

    for (final String key in orderedKeys) {
      final _NormalizedEntry? l = lSide[key];
      final _NormalizedEntry? r = rSide[key];
      CollectionManifestEntry? merged =
          _mergeOne(l, r, lastSyncedAtMs: lastSyncedAtMs, lPeer: localIsPeer);
      if (merged == null) continue; // 双方都无知识（不可达）或全空壳被剪枝。
      // 首次发布盖时戳：把本端新造/新并入的（publishedAt 尚空的）墓碑/删除标记为
      // now，供对端用「基线 vs publishedAt」判新旧（§2.3 因果修复）。
      if (stampPublish) merged = _stampEntry(merged, now);
      mergedEntries.add(merged);
      if (!_localMatches(l, merged)) toReconcile.add(merged);
    }

    return CollectionSyncOutcome(
      merged: CollectionManifest(collections: mergedEntries),
      changes: CollectionLocalChanges(toReconcile),
    );
  }

  /// 折叠多份**对端已发布**清单（per-device `collections-<id>.json` + 旧单文件）成
  /// 一份「远端并集」，供编排器再与本端快照 [merge]。
  ///
  /// finding 1 因果修复：折叠里**不**用本端基线裁决墓碑——基线每轮推进，一条本端上轮
  /// 刚发布（publishedAt==上轮基线）的墓碑到了下轮会 `publishedAt > 基线` 判 false → 判
  /// 旧闻 → 陈旧对端文件里的活成员「重加胜」→ 已移出/删除/改名的成员在全网复活。改用
  /// **文件级 [CollectionManifest.lastWrittenAt]**：一个活成员仅当其所在文件的 lastWrittenAt
  /// **晚于**该成员墓碑的 publishedAt 才算「看过墓碑后的有意重加」，否则墓碑默认获胜。
  /// 旧文件/旧单文件缺 lastWrittenAt（=0）的活成员恒陈旧，永远输给任何已发布墓碑。
  ///
  /// 折叠对折叠顺序不变（每项聚合都用 max/min，与顺序无关），不盖新 publishedAt（保真
  /// 对端发布戳）。合集级删除同理：某文件在删除发布戳之后（lastWrittenAt > deletePublishedAt）
  /// 仍把合集列为活的 ⇒ 重建胜；否则删除胜。
  static CollectionManifest combinePeers(List<CollectionManifest> peers) {
    final Map<String, _FoldGroup> groups = <String, _FoldGroup>{};
    for (final CollectionManifest peer in peers) {
      final int fileTime = peer.lastWrittenAt;
      final Map<String, _NormalizedEntry> norm = _normalize(peer);
      for (final MapEntry<String, _NormalizedEntry> e in norm.entries) {
        (groups[e.key] ??= _FoldGroup(e.value.name, e.value.collectionType))
            .observe(e.value, fileTime);
      }
    }
    final List<CollectionManifestEntry> out = <CollectionManifestEntry>[];
    for (final _FoldGroup g in groups.values) {
      final CollectionManifestEntry? entry = g.resolve();
      if (entry != null) out.add(entry);
    }
    return CollectionManifest(collections: out);
  }

  /// 给合并结果条目里 publishedAt 尚空的墓碑/删除盖上 [nowMs]（本端首次发布）。
  /// publishedAt 已有值（来自对端清单）的原样保留——发布时刻一经确定绝不刷新，
  /// 否则每轮都重盖会破坏「字节相等 ⇒ 跳过回写」的幂等。
  static CollectionManifestEntry _stampEntry(
      CollectionManifestEntry e, int nowMs) {
    final bool deadNeedsStamp =
        e.deletedAt != null && e.deletedPublishedAt == null;
    bool tombNeedsStamp = false;
    for (final CollectionMemberTombstone t in e.memberTombstones) {
      if (t.publishedAt == null) {
        tombNeedsStamp = true;
        break;
      }
    }
    if (!deadNeedsStamp && !tombNeedsStamp) return e;
    return CollectionManifestEntry(
      name: e.name,
      collectionType: e.collectionType,
      orderUpdatedAt: e.orderUpdatedAt,
      deletedAt: e.deletedAt,
      deletedPublishedAt:
          e.deletedAt != null ? (e.deletedPublishedAt ?? nowMs) : null,
      members: e.members,
      memberTombstones: <CollectionMemberTombstone>[
        for (final CollectionMemberTombstone t in e.memberTombstones)
          t.publishedAt == null
              ? CollectionMemberTombstone(
                  mediaType: t.mediaType,
                  entryKey: t.entryKey,
                  removedAt: t.removedAt,
                  publishedAt: nowMs,
                )
              : t,
      ],
    );
  }

  /// 合并单个自然键。返回 null = 该键在合并后不携带任何知识（剪枝）。
  /// [lPeer]/[rPeer] 分别标记 l/r 侧是否为「对端已发布」清单：对端侧用 publishedAt
  /// 判新旧（回退 removedAt 兼容旧清单），本端侧用 removedAt（与本端基线同一时钟轴）。
  static CollectionManifestEntry? _mergeOne(
    _NormalizedEntry? l,
    _NormalizedEntry? r, {
    required int lastSyncedAtMs,
    bool lPeer = false,
    bool rPeer = true,
  }) {
    // 单侧知识：原样并入（对侧从未见过该合集/墓碑）。
    if (l == null && r == null) return null;
    if (l == null) return _prune(r!.toEntry());
    if (r == null) return _prune(l.toEntry());

    final int? lDead = l.deletedAt;
    final int? rDead = r.deletedAt;

    // ── 合集级死活裁决 ─────────────────────────────────────────────
    if (lDead != null && rDead != null) {
      // 双死：取新 deletedAt（知识合并），publishedAt 取较早的真·首发戳。
      final int deadAt = lDead >= rDead ? lDead : rDead;
      return _deadEntry(
          l, deadAt, _minPublished(l.deletedPublishedAt, r.deletedPublishedAt));
    }
    if (rDead != null) {
      // 本端活 / 对侧死：删除是新闻 ⇒ 生效；旧闻且本端活着 ⇒ 本端重建 ⇒ 活胜。
      return _deleteIsNews(rDead, r.deletedPublishedAt,
              peer: rPeer, baseline: lastSyncedAtMs)
          ? _deadEntry(l, rDead, r.deletedPublishedAt)
          : _prune(l.toEntry());
    }
    if (lDead != null) {
      // 本端死 / 对侧活：本端删除未发布(新闻) ⇒ 死胜；已发布过 ⇒ 对侧重建 ⇒ 活胜。
      return _deleteIsNews(lDead, l.deletedPublishedAt,
              peer: lPeer, baseline: lastSyncedAtMs)
          ? _deadEntry(l, lDead, l.deletedPublishedAt)
          : _prune(r.toEntry());
    }

    // ── 双活：成员并集 + 墓碑裁决 + 手动序整合集 LWW ────────────────
    final Set<String> memberKeys = <String>{
      ...l.membersByKey.keys,
      ...r.membersByKey.keys,
      ...l.tombstones.keys,
      ...r.tombstones.keys,
    };
    final Set<String> aliveMembers = <String>{};
    final Map<String, _Tomb> mergedTombstones = <String, _Tomb>{};
    for (final String mk in memberKeys) {
      final bool lm = l.membersByKey.containsKey(mk);
      final bool rm = r.membersByKey.containsKey(mk);
      final _Tomb? lt = l.tombstones[mk];
      final _Tomb? rt = r.tombstones[mk];
      if (lm && rm) {
        aliveMembers.add(mk);
      } else if (lm) {
        // 本端有成员，对侧没有：无墓碑 = 纯本端独有 ⇒ 并集保留；有墓碑按对侧模式裁决。
        if (rt == null ||
            !_tombIsNews(rt, peer: rPeer, baseline: lastSyncedAtMs)) {
          aliveMembers.add(mk); // 旧闻墓碑 + 成员仍在 ⇒ 重加胜，墓碑清除。
        } else {
          mergedTombstones[mk] = rt;
        }
      } else if (rm) {
        // 对侧有成员，本端没有：对称——本端墓碑未发布(新闻)则移出胜，否则重加胜。
        if (lt == null ||
            !_tombIsNews(lt, peer: lPeer, baseline: lastSyncedAtMs)) {
          aliveMembers.add(mk);
        } else {
          mergedTombstones[mk] = lt;
        }
      } else {
        // 两侧都无成员：墓碑纯知识合并（removedAt 取新、publishedAt 取较早真·首发）。
        mergedTombstones[mk] = _mergeTomb(lt, rt);
      }
    }

    // 手动序整合集 LWW：新者的整表顺序为准；平手取远端（共享态）保证收敛。
    final bool localOrderWins = l.orderUpdatedAt > r.orderUpdatedAt;
    final _NormalizedEntry winner = localOrderWins ? l : r;
    final _NormalizedEntry loser = localOrderWins ? r : l;
    final List<String> orderedAlive = <String>[
      for (final String mk in winner.memberOrder)
        if (aliveMembers.contains(mk)) mk,
      for (final String mk in loser.memberOrder)
        if (aliveMembers.contains(mk) && !winner.membersByKey.containsKey(mk))
          mk,
    ];

    final int mergedOrderUpdatedAt = l.orderUpdatedAt > r.orderUpdatedAt
        ? l.orderUpdatedAt
        : r.orderUpdatedAt;
    return _prune(CollectionManifestEntry(
      name: l.name,
      collectionType: l.collectionType,
      orderUpdatedAt: mergedOrderUpdatedAt,
      members: _reindexed(orderedAlive),
      memberTombstones: <CollectionMemberTombstone>[
        for (final MapEntry<String, _Tomb> e in mergedTombstones.entries)
          CollectionMemberTombstone(
            mediaType: _memberMediaType(e.key),
            entryKey: _memberEntryKey(e.key),
            removedAt: e.value.removedAt,
            publishedAt: e.value.publishedAt,
          ),
      ],
    ));
  }

  /// 一条墓碑「对本端是不是新闻」：对端侧用 publishedAt（首次进共享清单的时刻，回退
  /// removedAt 兼容旧清单）判 `> 基线`；本端侧用 removedAt（与本端基线同一时钟轴，
  /// 本端未发布=removedAt>基线=新闻）。
  static bool _tombIsNews(_Tomb t,
      {required bool peer, required int baseline}) {
    final int at = peer ? (t.publishedAt ?? t.removedAt) : t.removedAt;
    return at > baseline;
  }

  /// 合集级删除「对本端是不是新闻」：同 [_tombIsNews]，用 deletedPublishedAt/deletedAt。
  static bool _deleteIsNews(int deletedAt, int? deletedPublishedAt,
      {required bool peer, required int baseline}) {
    final int at = peer ? (deletedPublishedAt ?? deletedAt) : deletedAt;
    return at > baseline;
  }

  /// 合并两条同键墓碑：removedAt 取较大（较新移出墙钟），publishedAt 取较早的非空
  /// 首发戳（都空 → null，留待 [_stampEntry] 盖本端 now）。显式 null 展开，不用
  /// `?? -1` 哨兵——负 removedAt（已在 codec 拒绝）+ 哨兵曾触发 `!` 空断言崩溃。
  static _Tomb _mergeTomb(_Tomb? a, _Tomb? b) {
    if (a == null) return b!;
    if (b == null) return a;
    final int removedAt =
        a.removedAt >= b.removedAt ? a.removedAt : b.removedAt;
    return (
      removedAt: removedAt,
      publishedAt: _minPublished(a.publishedAt, b.publishedAt),
    );
  }

  /// 两个可空发布戳取较早的非空值（首次真发布时刻收敛，与折叠顺序无关）。
  static int? _minPublished(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a <= b ? a : b;
  }

  /// 全空的活壳（无成员、无墓碑）不携带知识：从清单剪掉，防止清单无限膨胀。
  /// 死条目（合集墓碑）永远保留——它就是知识本身。
  static CollectionManifestEntry? _prune(CollectionManifestEntry e) =>
      e.deletedAt == null && e.members.isEmpty && e.memberTombstones.isEmpty
          ? null
          : e;

  static CollectionManifestEntry _deadEntry(
          _NormalizedEntry key, int at, int? publishedAt) =>
      CollectionManifestEntry(
        name: key.name,
        collectionType: key.collectionType,
        deletedAt: at,
        deletedPublishedAt: publishedAt,
      );

  /// 本地现状 [l]（null = 本地全然不知）是否已与合并结果 [merged] 一致（一致则
  /// 无需产出本地变更；比较忽略 sortIndex 的具体数值，只看序列——本地可能是
  /// 0,5,7 的历史稀疏值，展示序相同就不值得为归一化写库）。
  static bool _localMatches(_NormalizedEntry? l, CollectionManifestEntry m) {
    if (l == null) {
      // 本地一无所知：仅当合并结果也不要求任何本地物化时才算一致。
      return m.deletedAt == null &&
          m.members.isEmpty &&
          m.memberTombstones.isEmpty;
    }
    if (m.deletedAt != null) {
      return l.deletedAt == m.deletedAt &&
          l.membersByKey.isEmpty &&
          l.tombstones.isEmpty;
    }
    if (l.deletedAt != null) return false;
    // 成员序列一致？
    final List<String> mergedOrder = <String>[
      for (final CollectionManifestMember mm in m.members)
        _memberKey(mm.mediaType, mm.entryKey),
    ];
    if (l.memberOrder.length != mergedOrder.length) return false;
    for (int i = 0; i < mergedOrder.length; i++) {
      if (l.memberOrder[i] != mergedOrder[i]) return false;
    }
    // orderUpdatedAt 一致？（空壳无合集行可承载时间戳，忽略之，防止每轮空转）
    if (m.members.isNotEmpty && l.orderUpdatedAt != m.orderUpdatedAt) {
      return false;
    }
    // 墓碑集合一致？只比 removedAt——publishedAt 不落本地 DB（本地无该列），忽略之
    // 才不会因合并结果盖了 publishedAt 就每轮误判「需变更」空转写库。
    if (l.tombstones.length != m.memberTombstones.length) return false;
    for (final CollectionMemberTombstone t in m.memberTombstones) {
      if (l.tombstones[_memberKey(t.mediaType, t.entryKey)]?.removedAt !=
          t.removedAt) {
        return false;
      }
    }
    return true;
  }

  static List<CollectionManifestMember> _reindexed(List<String> orderedKeys) =>
      <CollectionManifestMember>[
        for (int i = 0; i < orderedKeys.length; i++)
          CollectionManifestMember(
            mediaType: _memberMediaType(orderedKeys[i]),
            entryKey: _memberEntryKey(orderedKeys[i]),
            sortIndex: i,
          ),
      ];

  /// 归一化一侧清单：按自然键成 map；死条目丢弃成员与墓碑（已无意义）；活条目
  /// 丢弃与在册成员同键的墓碑（DAO 不变量「加成员清墓碑」的防御性兜底）。
  /// 重复自然键（历史 schema 无唯一约束）取先见者，与备份合并的对齐方向一致。
  static Map<String, _NormalizedEntry> _normalize(CollectionManifest m) {
    final Map<String, _NormalizedEntry> out = <String, _NormalizedEntry>{};
    for (final CollectionManifestEntry e in m.collections) {
      final String key = _naturalKey(e.name, e.collectionType);
      if (out.containsKey(key)) continue;
      if (e.deletedAt != null) {
        out[key] = _NormalizedEntry(
          name: e.name,
          collectionType: e.collectionType,
          deletedAt: e.deletedAt,
          deletedPublishedAt: e.deletedPublishedAt,
          orderUpdatedAt: 0,
          memberOrder: const <String>[],
          membersByKey: const <String, CollectionManifestMember>{},
          tombstones: const <String, _Tomb>{},
        );
        continue;
      }
      final List<CollectionManifestMember> sorted =
          List<CollectionManifestMember>.of(e.members)
            ..sort((CollectionManifestMember a, CollectionManifestMember b) =>
                a.sortIndex.compareTo(b.sortIndex));
      final Map<String, CollectionManifestMember> byKey =
          <String, CollectionManifestMember>{};
      final List<String> order = <String>[];
      for (final CollectionManifestMember mm in sorted) {
        final String mk = _memberKey(mm.mediaType, mm.entryKey);
        if (byKey.containsKey(mk)) continue;
        byKey[mk] = mm;
        order.add(mk);
      }
      final Map<String, _Tomb> tombs = <String, _Tomb>{
        for (final CollectionMemberTombstone t in e.memberTombstones)
          if (!byKey.containsKey(_memberKey(t.mediaType, t.entryKey)))
            _memberKey(t.mediaType, t.entryKey): (
              removedAt: t.removedAt,
              publishedAt: t.publishedAt,
            ),
      };
      out[key] = _NormalizedEntry(
        name: e.name,
        collectionType: e.collectionType,
        deletedAt: null,
        deletedPublishedAt: null,
        orderUpdatedAt: e.orderUpdatedAt,
        memberOrder: order,
        membersByKey: byKey,
        tombstones: tombs,
      );
    }
    return out;
  }

  // 键编码：NUL 分隔（两段都不含 NUL），同 backup_merge_engine._collectionKey。
  static String _naturalKey(String name, String type) => '$name\u0000$type';
  static String _memberKey(String mediaType, String entryKey) =>
      '$mediaType\u0000$entryKey';
  static String _memberMediaType(String memberKey) =>
      memberKey.substring(0, memberKey.indexOf('\u0000'));
  static String _memberEntryKey(String memberKey) =>
      memberKey.substring(memberKey.indexOf('\u0000') + 1);
}

/// [CollectionSyncEngine.merge] 的产物：合并后清单（写回远端）+ 本地变更集。
class CollectionSyncOutcome {
  const CollectionSyncOutcome({required this.merged, required this.changes});

  final CollectionManifest merged;
  final CollectionLocalChanges changes;
}

/// 本地变更集：需要把本地 DB 物化成的目标态（合并结果里与本地现状不一致的
/// 合集条目，活=调和成员/序/墓碑，死=删合集+镜像合集墓碑）。声明式目标态而非
/// 操作列表——应用器按目标态调和，天然幂等（重放安全）。
class CollectionLocalChanges {
  const CollectionLocalChanges(this.entries);

  /// 目标态条目（每条即合并后清单里的对应 entry）。
  final List<CollectionManifestEntry> entries;

  bool get isEmpty => entries.isEmpty;

  /// 变更合集数（计入 SyncRunReport）。
  int get changedCollections => entries.length;
}

/// 从本地 DB 构建合集全量快照清单。成员 sortIndex 用**位置序号 0..n-1**（而非
/// 历史稀疏 sortIndex 原值）：清单只关心序列，归一化让「内容相等 ⇒ 字节相等」。
Future<CollectionManifest> loadLocalCollectionManifest(
    HibikiDatabase db) async {
  final List<MediaCollectionRow> rows = await db.getAllMediaCollections();
  final List<CollectionMemberTombstoneRow> tombRows =
      await db.getAllCollectionMemberTombstones();

  // 墓碑按自然键分组；哨兵行单独归为合集级 deletedAt。
  final Map<String, List<CollectionMemberTombstoneRow>> memberTombsByKey =
      <String, List<CollectionMemberTombstoneRow>>{};
  final Map<String, int> deletedAtByKey = <String, int>{};
  String nk(String name, String type) => '$name\u0000$type';
  for (final CollectionMemberTombstoneRow t in tombRows) {
    final String key = nk(t.collectionName, t.collectionType);
    final bool isSentinel =
        t.mediaType == HibikiDatabase.collectionTombstoneSentinel &&
            t.entryKey == HibikiDatabase.collectionTombstoneSentinel;
    if (isSentinel) {
      deletedAtByKey[key] = t.removedAt;
    } else {
      (memberTombsByKey[key] ??= <CollectionMemberTombstoneRow>[]).add(t);
    }
  }

  // 历史重名行去重方向必须与 applyCollectionLocalChanges 用的
  // getMediaCollectionByNaturalKey(min id) 一致——否则同名两行每轮各选一行、判不
  // 一致永不收敛。getAllMediaCollections 按 sortOrder,id 排序，先见者未必是 min id；
  // 这里显式按 id 升序取先见者，与应用端对齐（BUG 修复）。
  final List<MediaCollectionRow> byId = List<MediaCollectionRow>.of(rows)
    ..sort(
        (MediaCollectionRow a, MediaCollectionRow b) => a.id.compareTo(b.id));

  final List<CollectionManifestEntry> entries = <CollectionManifestEntry>[];
  final Set<String> seen = <String>{};
  for (final MediaCollectionRow row in byId) {
    // 空自然键行是脏数据（正常合集名恒非空）：绝不发布，否则对端 fromJson 抛
    // FormatException 拖垮整份清单解析。
    if (row.name.isEmpty || row.collectionType.isEmpty) continue;
    final String key = nk(row.name, row.collectionType);
    if (!seen.add(key)) continue; // 历史重名行：取 min id 者（同应用端对齐方向）。
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(row.id);
    entries.add(CollectionManifestEntry(
      name: row.name,
      collectionType: row.collectionType,
      orderUpdatedAt: row.orderUpdatedAt,
      members: <CollectionManifestMember>[
        for (int i = 0; i < items.length; i++)
          // 空成员键是脏数据：跳过（对端 codec 会拒空键）。
          if (items[i].mediaType.isNotEmpty && items[i].entryKey.isNotEmpty)
            CollectionManifestMember(
              mediaType: items[i].mediaType,
              entryKey: items[i].entryKey,
              sortIndex: i,
            ),
      ],
      memberTombstones: <CollectionMemberTombstone>[
        for (final CollectionMemberTombstoneRow t
            in memberTombsByKey[key] ?? const <CollectionMemberTombstoneRow>[])
          // 空键 / 负 removedAt 是脏数据：跳过（对端 codec 会拒之）。
          if (t.mediaType.isNotEmpty &&
              t.entryKey.isNotEmpty &&
              t.removedAt >= 0)
            CollectionMemberTombstone(
              mediaType: t.mediaType,
              entryKey: t.entryKey,
              removedAt: t.removedAt,
            ),
      ],
    ));
  }

  // 无合集行但有墓碑知识的自然键：死壳（哨兵）或活壳（仅成员墓碑——移空自删后
  // 留下的移出知识，必须进清单否则对端并集会复活刚移出的成员）。
  final Set<String> tombOnlyKeys = <String>{
    ...memberTombsByKey.keys,
    ...deletedAtByKey.keys,
  }..removeAll(seen);
  for (final String key in tombOnlyKeys) {
    final int nul = key.indexOf('\u0000');
    final String name = key.substring(0, nul);
    final String type = key.substring(nul + 1);
    // 空自然键的墓碑壳是脏数据：跳过（绝不发布空 name/type 毒害对端）。
    if (name.isEmpty || type.isEmpty) continue;
    final int? deadAt = deletedAtByKey[key];
    entries.add(CollectionManifestEntry(
      name: name,
      collectionType: type,
      deletedAt: deadAt,
      memberTombstones: deadAt != null
          ? const <CollectionMemberTombstone>[]
          : <CollectionMemberTombstone>[
              for (final CollectionMemberTombstoneRow t
                  in memberTombsByKey[key]!)
                if (t.mediaType.isNotEmpty &&
                    t.entryKey.isNotEmpty &&
                    t.removedAt >= 0)
                  CollectionMemberTombstone(
                    mediaType: t.mediaType,
                    entryKey: t.entryKey,
                    removedAt: t.removedAt,
                  ),
            ],
    ));
  }

  return CollectionManifest(collections: entries);
}

/// 把 [changes]（目标态）调和进本地 DB。整体一个事务：中途失败全量回滚，不留
/// 半套合集。返回实际处理的合集条目数（计入 SyncRunReport.collectionsUpdated）。
///
/// 与用户路径的关键差异：这里**镜像**清单里的时间戳/墓碑，绝不写 now、绝不经
/// [HibikiDatabase.removeFromCollection]/[HibikiDatabase.deleteMediaCollection]
/// （那两条会写全新墓碑，把同步应用伪装成本端的人为操作）。
Future<int> applyCollectionLocalChanges(
    HibikiDatabase db, CollectionLocalChanges changes) async {
  if (changes.isEmpty) return 0;
  await db.transaction(() async {
    for (final CollectionManifestEntry e in changes.entries) {
      final MediaCollectionRow? row =
          await db.getMediaCollectionByNaturalKey(e.name, e.collectionType);

      if (e.deletedAt != null) {
        // 目标态 = 已删：删本地行（若有），墓碑表只留哨兵（镜像 deletedAt）。
        if (row != null) {
          await db.deleteMediaCollectionRaw(row.id);
        }
        await db.replaceCollectionTombstonesFor(
            e.name, e.collectionType, <CollectionMemberTombstonesCompanion>[
          CollectionMemberTombstonesCompanion.insert(
            collectionName: e.name,
            collectionType: e.collectionType,
            mediaType: HibikiDatabase.collectionTombstoneSentinel,
            entryKey: HibikiDatabase.collectionTombstoneSentinel,
            removedAt: e.deletedAt!,
          ),
        ]);
        continue;
      }

      // 目标态 = 活：成员序列/序时间戳/成员墓碑全部镜像清单。
      if (e.members.isEmpty) {
        // 活壳（全成员被移出）：本地沿用「移空自删」语义，不留 0 成员合集卡。
        if (row != null) {
          await db.deleteMediaCollectionRaw(row.id);
        }
      } else {
        final int id = row?.id ??
            await db.createMediaCollection(e.name,
                collectionType: e.collectionType);
        // 调和成员：删多余、按位置 upsert（sortIndex = 清单位置序号）。
        final List<MediaCollectionItemRow> current =
            await db.getCollectionItems(id);
        final Set<String> desiredKeys = <String>{
          for (final CollectionManifestMember m in e.members)
            '${m.mediaType}\u0000${m.entryKey}',
        };
        for (final MediaCollectionItemRow it in current) {
          if (!desiredKeys.contains('${it.mediaType}\u0000${it.entryKey}')) {
            await db.deleteCollectionItemRaw(id, it.mediaType, it.entryKey);
          }
        }
        for (int i = 0; i < e.members.length; i++) {
          await db.upsertCollectionItemAt(
              id, e.members[i].mediaType, e.members[i].entryKey, i);
        }
        await db.setCollectionOrderUpdatedAt(id, e.orderUpdatedAt);
      }
      await db.replaceCollectionTombstonesFor(
          e.name, e.collectionType, <CollectionMemberTombstonesCompanion>[
        for (final CollectionMemberTombstone t in e.memberTombstones)
          CollectionMemberTombstonesCompanion.insert(
            collectionName: e.name,
            collectionType: e.collectionType,
            mediaType: t.mediaType,
            entryKey: t.entryKey,
            removedAt: t.removedAt,
          ),
      ]);
    }
  });
  return changes.changedCollections;
}

/// 一条墓碑的知识：移出墙钟 [removedAt] + 首次进共享清单的发布戳 [publishedAt]
/// （null = 本端尚未发布，一律视为新闻）。
typedef _Tomb = ({int removedAt, int? publishedAt});

/// 引擎内部使用的归一化条目（一侧清单里某自然键的知识）。
class _NormalizedEntry {
  const _NormalizedEntry({
    required this.name,
    required this.collectionType,
    required this.deletedAt,
    required this.deletedPublishedAt,
    required this.orderUpdatedAt,
    required this.memberOrder,
    required this.membersByKey,
    required this.tombstones,
  });

  final String name;
  final String collectionType;

  /// 非 null = 该侧认为合集已删（deletedAt 毫秒戳）。
  final int? deletedAt;

  /// 合集级删除的首次发布戳（null = 未发布，对端裁决回退 deletedAt）。
  final int? deletedPublishedAt;

  final int orderUpdatedAt;

  /// 成员键（mediaType NUL entryKey）按该侧 sortIndex 的顺序。
  final List<String> memberOrder;

  final Map<String, CollectionManifestMember> membersByKey;

  /// 成员键 → 墓碑知识（removedAt + publishedAt）。
  final Map<String, _Tomb> tombstones;

  CollectionManifestEntry toEntry() => CollectionManifestEntry(
        name: name,
        collectionType: collectionType,
        orderUpdatedAt: orderUpdatedAt,
        deletedAt: deletedAt,
        deletedPublishedAt: deletedPublishedAt,
        members: <CollectionManifestMember>[
          for (int i = 0; i < memberOrder.length; i++)
            CollectionManifestMember(
              mediaType: CollectionSyncEngine._memberMediaType(memberOrder[i]),
              entryKey: CollectionSyncEngine._memberEntryKey(memberOrder[i]),
              sortIndex: i,
            ),
        ],
        memberTombstones: <CollectionMemberTombstone>[
          for (final MapEntry<String, _Tomb> e in tombstones.entries)
            CollectionMemberTombstone(
              mediaType: CollectionSyncEngine._memberMediaType(e.key),
              entryKey: CollectionSyncEngine._memberEntryKey(e.key),
              removedAt: e.value.removedAt,
              publishedAt: e.value.publishedAt,
            ),
        ],
      );
}

/// [CollectionSyncEngine.combinePeers] 的按自然键聚合器：把 N 份对端清单里同一合集的
/// 知识折叠成一条。裁决全用**文件级 lastWrittenAt**（finding 1 因果修复），不碰本端基线。
///
/// 聚合项都用 max/min（与折叠顺序无关，保证两端读同一批文件收敛到同一并集）：
/// - 成员活/死：`aliveFileTimeMax`（该成员被列为活的文件中最新 lastWrittenAt）> 该成员墓碑
///   的最新 publishedAt ⇒ 活（有意重加）；否则墓碑胜。缺 publishedAt 回退 removedAt。
/// - 合集删/活：任一文件在删除发布之后仍把它列为活 ⇒ 重建胜；否则删除胜。
/// - 手动序 LWW：取最大 orderUpdatedAt 的成员顺序；多份平手取字典序最小者（对折叠顺序不变）。
class _FoldGroup {
  _FoldGroup(this.name, this.collectionType);

  final String name;
  final String collectionType;

  // ── 合集级删除聚合 ──
  bool _sawDelete = false;
  int _deleteRemovedMax = 0; // 删除胜时落盘的 deletedAt（取最新移除墙钟）。
  int? _deletePubMin; // 删除胜时落盘的 deletedPublishedAt（首发戳，取最早非空）。
  int _deletePubMaxDecision = -1; // 决策用：最新删除发布戳（回退 deletedAt）。

  // ── 活条目聚合 ──
  int _aliveFileTimeMax = -1; // 把本合集列为活的文件中最新 lastWrittenAt。
  int _orderUpdatedAtMax = 0;
  int _orderCandidateAt = -1; // 当前候选顺序对应的 orderUpdatedAt。
  final List<List<String>> _orderCandidates = <List<String>>[];

  final Map<String, int> _memberAliveTime = <String, int>{}; // 成员键 → 最新活文件时戳。
  final Map<String, int> _tombRemovedMax =
      <String, int>{}; // 成员键 → 最新 removedAt。
  final Map<String, int?> _tombPubMin =
      <String, int?>{}; // 成员键 → 最早非空 publishedAt。
  final Map<String, int> _tombPubMaxDecision =
      <String, int>{}; // 决策用 max(pub??removed)。

  void observe(_NormalizedEntry e, int fileTime) {
    if (e.deletedAt != null) {
      _sawDelete = true;
      final int d = e.deletedAt!;
      if (d > _deleteRemovedMax) _deleteRemovedMax = d;
      final int pubDecision = e.deletedPublishedAt ?? d;
      if (pubDecision > _deletePubMaxDecision) {
        _deletePubMaxDecision = pubDecision;
      }
      final int? p = e.deletedPublishedAt;
      if (p != null && (_deletePubMin == null || p < _deletePubMin!)) {
        _deletePubMin = p;
      }
      return; // 归一化后的死条目不携带成员/墓碑。
    }
    if (fileTime > _aliveFileTimeMax) _aliveFileTimeMax = fileTime;
    if (e.orderUpdatedAt > _orderUpdatedAtMax) {
      _orderUpdatedAtMax = e.orderUpdatedAt;
    }
    if (e.orderUpdatedAt > _orderCandidateAt) {
      _orderCandidateAt = e.orderUpdatedAt;
      _orderCandidates
        ..clear()
        ..add(e.memberOrder);
    } else if (e.orderUpdatedAt == _orderCandidateAt) {
      _orderCandidates.add(e.memberOrder);
    }
    for (final String mk in e.memberOrder) {
      final int prev = _memberAliveTime[mk] ?? -1;
      if (fileTime > prev) _memberAliveTime[mk] = fileTime;
    }
    for (final MapEntry<String, _Tomb> t in e.tombstones.entries) {
      final String mk = t.key;
      final int r = t.value.removedAt;
      final int prevR = _tombRemovedMax[mk] ?? -1;
      if (r > prevR) _tombRemovedMax[mk] = r;
      final int pubDecision = t.value.publishedAt ?? r;
      final int prevMax = _tombPubMaxDecision[mk] ?? -1;
      if (pubDecision > prevMax) _tombPubMaxDecision[mk] = pubDecision;
      final int? p = t.value.publishedAt;
      if (p != null) {
        final int? prevMin = _tombPubMin[mk];
        if (prevMin == null || p < prevMin) _tombPubMin[mk] = p;
      } else {
        _tombPubMin.putIfAbsent(mk, () => null);
      }
    }
  }

  /// 折叠出该合集在远端并集里的最终条目（剪枝空壳返回 null）。
  CollectionManifestEntry? resolve() {
    // 合集级死活：任一文件在最新删除发布之后仍把它列为活（活文件时戳更晚）⇒ 重建胜。
    if (_sawDelete && !(_aliveFileTimeMax > _deletePubMaxDecision)) {
      return CollectionManifestEntry(
        name: name,
        collectionType: collectionType,
        deletedAt: _deleteRemovedMax,
        deletedPublishedAt: _deletePubMin,
      );
    }

    final Set<String> keys = <String>{
      ..._memberAliveTime.keys,
      ..._tombRemovedMax.keys,
    };
    final Set<String> aliveMembers = <String>{};
    final Map<String, _Tomb> tombs = <String, _Tomb>{};
    for (final String mk in keys) {
      final int? aliveT = _memberAliveTime[mk];
      final bool hasTomb = _tombRemovedMax.containsKey(mk);
      final int tombPubDecision = _tombPubMaxDecision[mk] ?? -1;
      // 活成员仅当其文件时戳晚于墓碑最新发布戳（有意重加）；无墓碑则活着即保留。
      final bool alive =
          aliveT != null && (!hasTomb || aliveT > tombPubDecision);
      if (alive) {
        aliveMembers.add(mk);
      } else if (hasTomb) {
        tombs[mk] =
            (removedAt: _tombRemovedMax[mk]!, publishedAt: _tombPubMin[mk]);
      }
    }

    // 顺序：候选（最大 orderUpdatedAt 的 memberOrder）里字典序最小者为准（折叠顺序无关），
    // 过滤到 alive，再追加不在候选里的剩余 alive（按 key 排序，确定性）。
    final List<String> winnerOrder = _pickCanonicalOrder();
    final List<String> ordered = <String>[
      for (final String mk in winnerOrder)
        if (aliveMembers.contains(mk)) mk,
    ];
    final Set<String> placed = ordered.toSet();
    final List<String> rest = <String>[
      for (final String mk in aliveMembers)
        if (!placed.contains(mk)) mk,
    ]..sort();
    ordered.addAll(rest);

    return CollectionSyncEngine._prune(CollectionManifestEntry(
      name: name,
      collectionType: collectionType,
      orderUpdatedAt: _orderUpdatedAtMax,
      members: CollectionSyncEngine._reindexed(ordered),
      memberTombstones: <CollectionMemberTombstone>[
        for (final MapEntry<String, _Tomb> e in tombs.entries)
          CollectionMemberTombstone(
            mediaType: CollectionSyncEngine._memberMediaType(e.key),
            entryKey: CollectionSyncEngine._memberEntryKey(e.key),
            removedAt: e.value.removedAt,
            publishedAt: e.value.publishedAt,
          ),
      ],
    ));
  }

  List<String> _pickCanonicalOrder() {
    if (_orderCandidates.isEmpty) return const <String>[];
    List<String> best = _orderCandidates.first;
    for (final List<String> c in _orderCandidates.skip(1)) {
      if (_lexLess(c, best)) best = c;
    }
    return best;
  }

  static bool _lexLess(List<String> a, List<String> b) {
    final int n = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final int c = a[i].compareTo(b[i]);
      if (c != 0) return c < 0;
    }
    return a.length < b.length;
  }
}
