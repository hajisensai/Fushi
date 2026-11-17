/// 冻结协议 3 夹具迁移进新代之后的 ID 口径。
///
/// 冻结库（`srs_stats_vectors.db.gz` 等）是协议 3 写的：内置笔记类型、字段、模板、默认牌组、笔记、卡全是按 profile uid
/// 加盐的存量 ID，期望值也按这些 ID 记。新代一律按规范 ID（不带盐，G9-7）物化，迁移之后读命令给的是规范 ID。比对前
/// 把期望值里的旧 ID 经内核 `canonical_ids`（[SrsDbStore.canonicalIds]，与生产归一持久化 ID 同一个命令）换成规范 ID；
/// 用卡 ID 当输入的假打分器反过来按旧 ID 算，结果才与期望值生成时相同。
library;

import 'package:fushi_engine/srs/srs_canonical_ids.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// [v]（JSON 形状：Map / List / 标量）里出现的全部 UUID 文本（值与键）。
Set<String> srsUuidsIn(Object? v) {
  final Set<String> out = <String>{};
  void walk(Object? x) {
    switch (x) {
      case final String s when _uuid.hasMatch(s):
        out.add(s);
      case final Map<Object?, Object?> m:
        for (final MapEntry<Object?, Object?> e in m.entries) {
          walk(e.key);
          walk(e.value);
        }
      case final List<Object?> l:
        l.forEach(walk);
      default:
    }
  }

  walk(v);
  return out;
}

/// 迁移之后 [legacy] 里出现的旧 ID → 新代的规范 ID（内核归一不到的原样）。
Future<Map<String, String>> srsMigratedIds(SrsDbStore s, Object? legacy) =>
    srsCanonicalIdMap(srsUuidsIn(legacy), s.canonicalIds);

/// [v] 的深拷贝，其中的 UUID 文本（值与键）按 [ids] 换掉。
Object? srsWithIds(Object? v, Map<String, String> ids) => switch (v) {
  final String s => ids[s] ?? s,
  final Map<Object?, Object?> m => <String, Object?>{
    for (final MapEntry<Object?, Object?> e in m.entries)
      srsWithIds(e.key, ids)! as String: srsWithIds(e.value, ids),
  },
  final List<Object?> l => <Object?>[
    for (final Object? x in l) srsWithIds(x, ids),
  ],
  _ => v,
};

/// [ids]（旧 → 规范）反过来：规范 ID → 旧 ID。两个旧 ID 归到同一个规范 ID 是夹具与内核契约都不允许的，直接报错。
Map<String, String> srsLegacyOf(Map<String, String> ids) {
  final Map<String, String> out = <String, String>{};
  for (final MapEntry<String, String> e in ids.entries) {
    final String? had = out[e.value];
    if (had != null && had != e.key) {
      throw StateError(
        '${e.value} is the canonical id of both $had and ${e.key}',
      );
    }
    out[e.value] = e.key;
  }
  return out;
}
