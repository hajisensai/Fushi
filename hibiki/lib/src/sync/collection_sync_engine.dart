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
  static CollectionSyncOutcome merge({
    required CollectionManifest local,
    required CollectionManifest remote,
    required int lastSyncedAtMs,
  }) {
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
      final CollectionManifestEntry? merged =
          _mergeOne(l, r, lastSyncedAtMs: lastSyncedAtMs);
      if (merged == null) continue; // 双方都无知识（不可达）或全空壳被剪枝。
      mergedEntries.add(merged);
      if (!_localMatches(l, merged)) toReconcile.add(merged);
    }

    return CollectionSyncOutcome(
      merged: CollectionManifest(collections: mergedEntries),
      changes: CollectionLocalChanges(toReconcile),
    );
  }

  /// 合并单个自然键。返回 null = 该键在合并后不携带任何知识（剪枝）。
  static CollectionManifestEntry? _mergeOne(
    _NormalizedEntry? l,
    _NormalizedEntry? r, {
    required int lastSyncedAtMs,
  }) {
    // 单侧知识：原样并入（对侧从未见过该合集/墓碑）。
    if (l == null && r == null) return null;
    if (l == null) return _prune(r!.toEntry());
    if (r == null) return _prune(l.toEntry());

    final int? lDead = l.deletedAt;
    final int? rDead = r.deletedAt;

    // ── 合集级死活裁决 ─────────────────────────────────────────────
    if (lDead != null && rDead != null) {
      // 双死：取新 deletedAt（知识合并，无需基线）。
      return _deadEntry(l, lDead > rDead ? lDead : rDead);
    }
    if (rDead != null) {
      // 本端活 / 远端死：删除是新闻 ⇒ 生效；旧闻且本端活着 ⇒ 本端重建 ⇒ 活胜。
      return rDead > lastSyncedAtMs
          ? _deadEntry(l, rDead)
          : _prune(l.toEntry());
    }
    if (lDead != null) {
      // 本端死 / 远端活：本端删除未发布(晚于基线) ⇒ 死胜；已发布过 ⇒ 远端重建 ⇒ 活胜。
      return lDead > lastSyncedAtMs
          ? _deadEntry(l, lDead)
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
    final Map<String, int> mergedTombstones = <String, int>{};
    for (final String mk in memberKeys) {
      final bool lm = l.membersByKey.containsKey(mk);
      final bool rm = r.membersByKey.containsKey(mk);
      final int? lt = l.tombstones[mk];
      final int? rt = r.tombstones[mk];
      if (lm && rm) {
        aliveMembers.add(mk);
      } else if (lm) {
        // 本端有成员，远端没有：无墓碑 = 纯本端独有 ⇒ 并集保留；有墓碑按基线裁决。
        if (rt == null || rt <= lastSyncedAtMs) {
          aliveMembers.add(mk); // 旧闻墓碑 + 成员仍在 ⇒ 重加胜，墓碑清除。
        } else {
          mergedTombstones[mk] = rt;
        }
      } else if (rm) {
        // 远端有成员，本端没有：对称——本端墓碑未发布(新闻)则移出胜，否则重加胜。
        if (lt == null || lt <= lastSyncedAtMs) {
          aliveMembers.add(mk);
        } else {
          mergedTombstones[mk] = lt;
        }
      } else {
        // 两侧都无成员：墓碑纯知识合并，取新。
        final int ts = (lt ?? -1) > (rt ?? -1) ? lt! : rt!;
        mergedTombstones[mk] = ts;
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
        for (final MapEntry<String, int> e in mergedTombstones.entries)
          CollectionMemberTombstone(
            mediaType: _memberMediaType(e.key),
            entryKey: _memberEntryKey(e.key),
            removedAt: e.value,
          ),
      ],
    ));
  }

  /// 全空的活壳（无成员、无墓碑）不携带知识：从清单剪掉，防止清单无限膨胀。
  /// 死条目（合集墓碑）永远保留——它就是知识本身。
  static CollectionManifestEntry? _prune(CollectionManifestEntry e) =>
      e.deletedAt == null && e.members.isEmpty && e.memberTombstones.isEmpty
          ? null
          : e;

  static CollectionManifestEntry _deadEntry(_NormalizedEntry key, int at) =>
      CollectionManifestEntry(
        name: key.name,
        collectionType: key.collectionType,
        deletedAt: at,
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
    // 墓碑集合一致？
    if (l.tombstones.length != m.memberTombstones.length) return false;
    for (final CollectionMemberTombstone t in m.memberTombstones) {
      if (l.tombstones[_memberKey(t.mediaType, t.entryKey)] != t.removedAt) {
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
          orderUpdatedAt: 0,
          memberOrder: const <String>[],
          membersByKey: const <String, CollectionManifestMember>{},
          tombstones: const <String, int>{},
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
      final Map<String, int> tombs = <String, int>{
        for (final CollectionMemberTombstone t in e.memberTombstones)
          if (!byKey.containsKey(_memberKey(t.mediaType, t.entryKey)))
            _memberKey(t.mediaType, t.entryKey): t.removedAt,
      };
      out[key] = _NormalizedEntry(
        name: e.name,
        collectionType: e.collectionType,
        deletedAt: null,
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

  final List<CollectionManifestEntry> entries = <CollectionManifestEntry>[];
  final Set<String> seen = <String>{};
  for (final MediaCollectionRow row in rows) {
    final String key = nk(row.name, row.collectionType);
    if (!seen.add(key)) continue; // 历史重名行：取先见者（同引擎归一化方向）。
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(row.id);
    entries.add(CollectionManifestEntry(
      name: row.name,
      collectionType: row.collectionType,
      orderUpdatedAt: row.orderUpdatedAt,
      members: <CollectionManifestMember>[
        for (int i = 0; i < items.length; i++)
          CollectionManifestMember(
            mediaType: items[i].mediaType,
            entryKey: items[i].entryKey,
            sortIndex: i,
          ),
      ],
      memberTombstones: <CollectionMemberTombstone>[
        for (final CollectionMemberTombstoneRow t
            in memberTombsByKey[key] ?? const <CollectionMemberTombstoneRow>[])
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

/// 引擎内部使用的归一化条目（一侧清单里某自然键的知识）。
class _NormalizedEntry {
  const _NormalizedEntry({
    required this.name,
    required this.collectionType,
    required this.deletedAt,
    required this.orderUpdatedAt,
    required this.memberOrder,
    required this.membersByKey,
    required this.tombstones,
  });

  final String name;
  final String collectionType;

  /// 非 null = 该侧认为合集已删（deletedAt 毫秒戳）。
  final int? deletedAt;

  final int orderUpdatedAt;

  /// 成员键（mediaType NUL entryKey）按该侧 sortIndex 的顺序。
  final List<String> memberOrder;

  final Map<String, CollectionManifestMember> membersByKey;

  /// 成员键 → removedAt。
  final Map<String, int> tombstones;

  CollectionManifestEntry toEntry() => CollectionManifestEntry(
        name: name,
        collectionType: collectionType,
        orderUpdatedAt: orderUpdatedAt,
        deletedAt: deletedAt,
        members: <CollectionManifestMember>[
          for (int i = 0; i < memberOrder.length; i++)
            CollectionManifestMember(
              mediaType: CollectionSyncEngine._memberMediaType(memberOrder[i]),
              entryKey: CollectionSyncEngine._memberEntryKey(memberOrder[i]),
              sortIndex: i,
            ),
        ],
        memberTombstones: <CollectionMemberTombstone>[
          for (final MapEntry<String, int> e in tombstones.entries)
            CollectionMemberTombstone(
              mediaType: CollectionSyncEngine._memberMediaType(e.key),
              entryKey: CollectionSyncEngine._memberEntryKey(e.key),
              removedAt: e.value,
            ),
        ],
      );
}
