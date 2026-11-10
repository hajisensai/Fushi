/// 同步基线的远端作用域工具（BUG-4281）。
///
/// `sync_baselines` 的主键是 `(assetKey, dimension)`；按远端分槽不改表结构，只让
/// `dimension` 带上远端标签后缀（[remoteScopedKey]）。逻辑维度名（冲突上报、裁决簿
/// 用的那个）不变，只有落库的「存储维度」不同。
library;

import 'package:fushi/src/sync/interconnect_sync_backend.dart'
    show LegacyBaselineAdoption;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';

/// 某作用域下 [logicalDimension] 的存储维度：[tag] 为 null（老条目作用域 / 认不出的
/// 后端）→ 逻辑维度本身，即升级前的那一行；否则 `<逻辑维度>@<tag>`。
String baselineStorageDimension(String logicalDimension, String? tag) =>
    tag == null ? logicalDimension : remoteScopedKey(logicalDimension, tag);

/// 进程内领养记录：数据库 → 存储维度 → 那一次领养的 Future。并发调用方 await 同一个，
/// 领养只做一次；失败则移出，下次重试。
final Expando<Map<String, Future<void>>> _adoptions =
    Expando<Map<String, Future<void>>>('syncBaselineAdoptions');

/// 把升级前写下的无后缀旧行按 [adoption] 处理到 [tag] 作用域（[tag] 为 null 时什么
/// 都不做——那个作用域用的就是旧行）：
/// - [LegacyBaselineAdoption.move]：每个逻辑维度的旧行逐行**覆盖**目标行后删除。
///   新代码对带标签的作用域从不写无后缀行，所以旧行只可能来自更旧的版本（含降级
///   期间），一定比目标行新。
/// - [LegacyBaselineAdoption.discard]：删除旧行（来源不可考）。
/// - [LegacyBaselineAdoption.keep]：不动（老条目作用域正在用）。不记进程内缓存，
///   候选之后变成单 host 时还能领养。
///
/// 判空 / 读源行 / 写目标 / 删源行在同一个事务里。
Future<void> ensureBaselinesAdopted(
  FushiDatabase db, {
  required List<String> logicalDimensions,
  required String? tag,
  required LegacyBaselineAdoption adoption,
}) async {
  if (tag == null || adoption == LegacyBaselineAdoption.keep) return;
  final Map<String, Future<void>> byDimension = _adoptions[db] ??=
      <String, Future<void>>{};
  final List<Future<void>> waits = <Future<void>>[];
  for (final String logical in logicalDimensions) {
    final String storage = baselineStorageDimension(logical, tag);
    final Future<void> existing = byDimension[storage] ??=
        _adoptOne(db, logical, storage, adoption).catchError((
          Object e,
          StackTrace st,
        ) {
          byDimension.remove(storage);
          Error.throwWithStackTrace(e, st);
        });
    waits.add(existing);
  }
  await Future.wait(waits);
}

Future<void> _adoptOne(
  FushiDatabase db,
  String source,
  String target,
  LegacyBaselineAdoption adoption,
) => db.transaction(() async {
  final Map<String, int> legacy = await db.getSyncBaselinesForDimension(source);
  if (legacy.isEmpty) return;
  for (final MapEntry<String, int> row in legacy.entries) {
    if (adoption == LegacyBaselineAdoption.move) {
      await db.setSyncBaseline(row.key, target, row.value);
    }
    await db.deleteSyncBaseline(row.key, source);
  }
});
