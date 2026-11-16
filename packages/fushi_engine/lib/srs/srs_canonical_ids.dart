/// 持久化在内核之外的 SRS 实体 ID 归一（G9-6，docs/specs/2026-11-15-srs-gen4-g7-g11-plan.md §2.2、交接说明「G9-6」一节）。
///
/// 新代的实体 ID 有别名类，规范 ID 不带盐：按 profile uid 加盐算出来的 ID（协议 3 时代存下的、Dart 派生的）在实体建好
/// 之后就只是成员；补盐（`collection_salts_add`）/ 并入（`collection_join` / `collection_adopt`）之后，别的盐算出的成员
/// 也归过来（`bindingChanged`）。内核对请求里的 ID 一律先归一，所以拿成员 ID 去读写不会写
/// 错实体；但 Dart 拿它去比对内核回来的规范 ID（`tree[deckId]`、`mappings[type.id]`）就对不上，用户的选择被当成
/// 「已删除」静默回落默认。凡是把 SRS 实体 ID 存在内核之外的地方（偏好里的制卡牌组 / 笔记类型 / 字段映射……），
/// 读的时候都经这里向内核要规范 ID（`canonical_ids`），并把规范 ID 写回去。
///
/// 只有这一处 helper：
/// - [srsCanonicalIdMap]：一批 ID → 规范 ID，按内核上限 [kSrsCanonicalIdsBatchMax] 分批（一批一条命令，不逐个跨边界）；
/// - [SrsPersistedIdSite] + [srsNormalizePersistedIds]：每个持久化位置报出它存着的 ID、拿到映射后改写自己，全部位置
///   的 ID 合成一批问一次；
/// - 值的改写（[srsCanonicalFieldMappings]、[srsCanonicalMiningDestination]）是纯函数，读时归一（制卡解析落点）与
///   落盘归一（偏好写回）共用。
///
/// 归一不到（实体已不存在、或根本不是 UUID）的 ID 内核原样返回：原值保留，交给各处已有的「缺失」处理（比如
/// [SrsResolvedMiningDestination.deckFellBack]），不清空用户设置。
library;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';

/// 内核 `canonical_ids` 一次最多答多少条（native/fushi_fsrs/src/store/gen4/cmd/identity.rs `LOOKUP_MAX`）。超了内核
/// 明确报错，调用方分批。
const int kSrsCanonicalIdsBatchMax = 4096;

/// 问一批 ID 的规范 ID：结果与 [ids] 逐项对应、条数相同。[ids] 不超过 [kSrsCanonicalIdsBatchMax] 条。
typedef SrsCanonicalIdsLookup = Future<List<String>> Function(List<String> ids);

/// [store] 那个 profile 的 `canonical_ids`（[SrsDbStore.canonicalIds]，只读命令；一次一个读快照）。
SrsCanonicalIdsLookup srsStoreCanonicalIds(SrsDbStore store) =>
    store.canonicalIds;

/// [ids] 里每个非空 ID → 它的规范 ID（去重后按 [kSrsCanonicalIdsBatchMax] 分批问 [lookup]）。空串不问（偏好里的
/// 「没选过」）。回包条数不对是内核契约被破坏，抛 [StateError]，不猜着对齐。
Future<Map<String, String>> srsCanonicalIdMap(
  Iterable<String> ids,
  SrsCanonicalIdsLookup lookup, {
  int batchMax = kSrsCanonicalIdsBatchMax,
}) async {
  assert(batchMax > 0 && batchMax <= kSrsCanonicalIdsBatchMax);
  final List<String> unique = <String>{
    for (final String id in ids)
      if (id.isNotEmpty) id,
  }.toList();
  final Map<String, String> out = <String, String>{};
  for (int at = 0; at < unique.length; at += batchMax) {
    final List<String> batch = unique.sublist(
      at,
      at + batchMax < unique.length ? at + batchMax : unique.length,
    );
    final List<String> canon = await lookup(batch);
    if (canon.length != batch.length) {
      throw StateError(
        'canonical_ids answered ${canon.length} ids for ${batch.length}',
      );
    }
    for (int i = 0; i < batch.length; i++) {
      out[batch[i]] = canon[i];
    }
  }
  return out;
}

/// [id] 的规范 ID；[canonical] 里没有（没问过 / 空串）就是它自己。
String srsCanonicalIdIn(Map<String, String> canonical, String id) =>
    canonical[id] ?? id;

/// 按键归一一张表：几个成员键归到同一个规范键时，键本来就是规范 ID 的那一项先占位（那是归一后写进来的、更新的
/// 选择），其余按原顺序只补它还没有的；值由 [merge] 合并（先占位的为 [kept]）。
Map<String, V> _canonicalKeys<V>(
  Map<String, V> m,
  Map<String, String> canonical,
  V Function(V kept, V other) merge,
) {
  final Map<String, V> out = <String, V>{};
  final List<MapEntry<String, V>> ordered = <MapEntry<String, V>>[
    for (final MapEntry<String, V> e in m.entries)
      if (srsCanonicalIdIn(canonical, e.key) == e.key) e,
    for (final MapEntry<String, V> e in m.entries)
      if (srsCanonicalIdIn(canonical, e.key) != e.key) e,
  ];
  for (final MapEntry<String, V> e in ordered) {
    final String key = srsCanonicalIdIn(canonical, e.key);
    final V? kept = out[key];
    out[key] = kept == null ? e.value : merge(kept, e.value);
  }
  return out;
}

/// `srs_mining_field_mappings` 形状（`{noteTypeId: {fieldId: 模板}}`）的两层键都换成规范 ID。成员键撞到同一个
/// 规范键时规范键原有的项优先，别的只补缺（[_canonicalKeys]），不丢任何一个字段的映射。
Map<String, Map<String, String>> srsCanonicalFieldMappings(
  Map<String, Map<String, String>> mappings,
  Map<String, String> canonical,
) => _canonicalKeys<Map<String, String>>(
  <String, Map<String, String>>{
    for (final MapEntry<String, Map<String, String>> e in mappings.entries)
      e.key: _canonicalKeys<String>(
        e.value,
        canonical,
        (String kept, String _) => kept,
      ),
  },
  canonical,
  (Map<String, String> kept, Map<String, String> other) => <String, String>{
    ...other,
    ...kept,
  },
);

/// [mappings] 里存着的全部 ID（两层键）。
Iterable<String> srsFieldMappingIds(
  Map<String, Map<String, String>> mappings,
) sync* {
  for (final MapEntry<String, Map<String, String>> e in mappings.entries) {
    yield e.key;
    yield* e.value.keys;
  }
}

/// [destination] 里存着的全部 ID（牌组、笔记类型、字段映射两层键）。
Iterable<String> srsMiningDestinationIds(
  SrsMiningDestination destination,
) sync* {
  yield destination.deckId;
  yield destination.noteTypeId;
  yield* srsFieldMappingIds(destination.fieldMappingsByType);
}

/// [destination] 的 ID 全部换成规范 ID（空串 = 没选过，保持空串）。
SrsMiningDestination srsCanonicalMiningDestination(
  SrsMiningDestination destination,
  Map<String, String> canonical,
) => SrsMiningDestination(
  deckId: srsCanonicalIdIn(canonical, destination.deckId),
  noteTypeId: srsCanonicalIdIn(canonical, destination.noteTypeId),
  fieldMappingsByType: srsCanonicalFieldMappings(
    destination.fieldMappingsByType,
    canonical,
  ),
);

/// 读时归一：[destination] 向内核问一次（一批）规范 ID 后换好。
Future<SrsMiningDestination> srsCanonicalizeMiningDestination(
  SrsMiningDestination destination,
  SrsCanonicalIdsLookup lookup,
) async => srsCanonicalMiningDestination(
  destination,
  await srsCanonicalIdMap(srsMiningDestinationIds(destination), lookup),
);

/// 一个把 SRS 实体 ID 存在内核之外的位置（一个偏好键、一张表的一列……）。
abstract interface class SrsPersistedIdSite {
  /// 诊断用的名字（偏好键名 / 表.列）。
  String get name;

  /// 现在存着的 ID（可以有空串，[srsCanonicalIdMap] 会跳过）。
  Iterable<String> get ids;

  /// 按 [canonical] 改写并落盘；只在值真的变了时写。返回是否写了。
  ///
  /// 改写时现读一遍当前值（问内核期间用户可能改过设置），[canonical] 里没有的 ID 原样保留。
  Future<bool> rewrite(Map<String, String> canonical);
}

/// 一个字符串值存一个 ID 的位置（`srs_mining_deck_id` / `srs_mining_note_type_id`）。
final class SrsPersistedIdValueSite implements SrsPersistedIdSite {
  SrsPersistedIdValueSite({
    required this.name,
    required String Function() read,
    required Future<void> Function(String id) write,
  }) : _read = read,
       _write = write;

  @override
  final String name;
  final String Function() _read;
  final Future<void> Function(String id) _write;

  @override
  Iterable<String> get ids => <String>[_read()];

  @override
  Future<bool> rewrite(Map<String, String> canonical) async {
    final String now = _read();
    final String canon = srsCanonicalIdIn(canonical, now);
    if (canon == now) return false;
    await _write(canon);
    return true;
  }
}

/// `{noteTypeId: {fieldId: 模板}}` 形状的位置（`srs_mining_field_mappings`）。
final class SrsPersistedFieldMappingsSite implements SrsPersistedIdSite {
  SrsPersistedFieldMappingsSite({
    required this.name,
    required Map<String, Map<String, String>> Function() read,
    required Future<void> Function(Map<String, Map<String, String>> mappings)
    write,
  }) : _read = read,
       _write = write;

  @override
  final String name;
  final Map<String, Map<String, String>> Function() _read;
  final Future<void> Function(Map<String, Map<String, String>> mappings) _write;

  @override
  Iterable<String> get ids => srsFieldMappingIds(_read());

  @override
  Future<bool> rewrite(Map<String, String> canonical) async {
    final Map<String, Map<String, String>> now = _read();
    final Map<String, Map<String, String>> canon = srsCanonicalFieldMappings(
      now,
      canonical,
    );
    if (_sameMappings(now, canon)) return false;
    await _write(canon);
    return true;
  }

  static bool _sameMappings(
    Map<String, Map<String, String>> a,
    Map<String, Map<String, String>> b,
  ) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, Map<String, String>> e in a.entries) {
      final Map<String, String>? o = b[e.key];
      if (o == null || o.length != e.value.length) return false;
      for (final MapEntry<String, String> f in e.value.entries) {
        if (!o.containsKey(f.key) || o[f.key] != f.value) return false;
      }
    }
    return true;
  }
}

/// 制卡落点三个偏好（牌组、笔记类型、字段映射）的位置。键名冻结（`srs_mining_*`），这里只给诊断名。
List<SrsPersistedIdSite> srsMiningDestinationIdSites({
  required SrsMiningDestination Function() read,
  required Future<void> Function(String id) writeDeckId,
  required Future<void> Function(String id) writeNoteTypeId,
  required Future<void> Function(Map<String, Map<String, String>> mappings)
  writeFieldMappings,
}) => <SrsPersistedIdSite>[
  SrsPersistedIdValueSite(
    name: 'srs_mining_deck_id',
    read: () => read().deckId,
    write: writeDeckId,
  ),
  SrsPersistedIdValueSite(
    name: 'srs_mining_note_type_id',
    read: () => read().noteTypeId,
    write: writeNoteTypeId,
  ),
  SrsPersistedFieldMappingsSite(
    name: 'srs_mining_field_mappings',
    read: () => read().fieldMappingsByType,
    write: writeFieldMappings,
  ),
];

/// 统一入口：[sites] 存着的 ID 合成一批（按上限分批）问一次规范 ID，再逐个位置改写落盘。返回写了的位置名。
///
/// 打开 profile 的复习副本时跑一次；`bindingChanged`（补盐 / 并入改了别名类）之后再跑一次。归一不到的 ID 原样保留。
/// [shouldStop] 在问完内核、落盘之前看一次：副本已经换掉（切 profile）时不把这份映射写进别的 profile 的设置。
Future<List<String>> srsNormalizePersistedIds(
  List<SrsPersistedIdSite> sites,
  SrsCanonicalIdsLookup lookup, {
  bool Function()? shouldStop,
}) async {
  final Map<String, String> canonical = await srsCanonicalIdMap(<String>[
    for (final SrsPersistedIdSite s in sites) ...s.ids,
  ], lookup);
  if (canonical.entries.every(
    (MapEntry<String, String> e) => e.key == e.value,
  )) {
    return const <String>[];
  }
  if (shouldStop?.call() ?? false) return const <String>[];
  final List<String> written = <String>[];
  for (final SrsPersistedIdSite s in sites) {
    if (await s.rewrite(canonical)) written.add(s.name);
  }
  return written;
}
