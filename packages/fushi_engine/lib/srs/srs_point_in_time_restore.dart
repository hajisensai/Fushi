/// 复习库「恢复到某个备份的时间点」（docs/specs/2026-10-17-srs-auto-backup-restore.md）。
///
/// 不是覆盖恢复（那条路径在通用备份里：整库换掉、换新化身，见 [SrsDbStore.afterRestore]）。
/// 覆盖恢复在多设备下回不到过去：备份之后的事件还在别的设备上，下一轮同步按 ID 取并集就全回来了。
/// 这里把「回到过去」写成**新事件**，新事件在合并里赢过备份之后的一切，并随同步传到所有设备：
///
/// 1. 先把备份里的事件并进本机（按 ID 取并集，与多设备同步同一套合并函数）：本机若缺了备份里的数据
///    （新装、清过数据、从别的设备拷来的备份），这一步补回来，并重新进发件箱。
/// 2. 可编辑字段：每个字段键的当前值与备份时的值不同（或有冲突）就写一条新修改记录，值取备份时的值。
///    新记录的 ctx 覆盖本机已应用的全部记录，支配它们（铁律 H）——对端那些旧值合进来时被判为被支配，回不来。
///    - 备份之后新建的笔记 / 牌组 / 笔记类型 → 写删除（软删除，删除优先）。
///    - 备份之后被删的 → 删除寄存器回到备份时的空值，即恢复，随同步在所有设备上恢复。
///    - 备份里没有、之后才出现的字段键 → 写「不存在」对应的值（null；笔记类型的字段 / 模板定义写软删除，
///      内置项写回代码里的定义）。
/// 3. 复习日志：备份之后的有效日志一律写 undo（[srsPlanRevokeLogs]）；备份内的日志后来被撤销、导致状态仍不同的卡，
///    由 [srsPlanStateRestore] 补回：被撤销的是备份时有效历史的尾巴就重放副本（旧版本客户端同样算对），
///    否则写一条 manual 日志照抄备份时的状态。日志本身一条不删（只追加）。
///
/// 恢复只覆盖本机在恢复那一刻**已经收到**的数据。那一刻别的设备上还没同步过来的修改与复习，与恢复是并发的：
/// 字段按铁律 H 处理（内容类进「待裁决」，标志 / 设置类最后修改生效并进同步冲突记录），复习日志照常有效。
library;

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

/// 一次恢复做了什么（界面提示、测试断言用）。
class SrsRestoreReport {
  int mergedEvents = 0;
  int fieldEdits = 0;
  int entitiesDeleted = 0;
  int entitiesRestored = 0;
  int logsRevoked = 0;
  int statesRestored = 0;

  @override
  String toString() =>
      'SrsRestoreReport(merged=$mergedEvents, edits=$fieldEdits, '
      'deleted=$entitiesDeleted, restored=$entitiesRestored, '
      'revoked=$logsRevoked, states=$statesRestored)';
}

/// 备份里的事件不属于 [SrsDbStore.profileUid]。
class SrsRestoreProfileMismatch implements Exception {
  const SrsRestoreProfileMismatch(this.backupProfileUid, this.localProfileUid);

  final String backupProfileUid;
  final String localProfileUid;

  @override
  String toString() =>
      'SrsRestoreProfileMismatch(backup=$backupProfileUid, '
      'local=$localProfileUid)';
}

String _profileOf(SrsEvent e) => switch (e) {
  SrsEntityEvent(:final SrsEntityRecord record) => record.profileUid,
  SrsEditEvent(:final SrsFieldEdit edit) => edit.profileUid,
  SrsLogEvent(:final SrsReviewLog log) => log.profileUid,
  SrsUnknownEvent(:final Map<String, Object?> raw) =>
    (raw['x'] is Map ? (raw['x']! as Map)['p'] as String? : null) ?? '',
};

const Set<SrsEntityKind> _deletableKinds = <SrsEntityKind>{
  SrsEntityKind.note,
  SrsEntityKind.deck,
  SrsEntityKind.noteType,
};

/// 把 [store] 恢复到 [backupEvents]（一份备份里的全部事件）那一刻的状态。见库注释。
///
/// [backupId] 只用于追溯（写进恢复日志的 extra）。整个过程一个事务：中途失败不留半恢复的库。
Future<SrsRestoreReport> srsRestoreToBackup({
  required SrsDbStore store,
  required List<SrsEvent> backupEvents,
  required Map<String, int> backupServerTimes,
  required String backupId,
  @visibleForTesting Future<void> Function(String stage)? debugOnStage,
}) async {
  for (final SrsEvent e in backupEvents) {
    final String p = _profileOf(e);
    if (p.isNotEmpty && p != store.profileUid) {
      throw SrsRestoreProfileMismatch(p, store.profileUid);
    }
  }
  final SrsRestoreReport report = SrsRestoreReport();
  // 先进副本的独占区再开事务：事务里调的写方法（applyRemote / writeEdits / appendLocalLogs）都要
  // 这把锁；反过来先开事务，排队等锁的别处写入又在等这个事务，两边互等。整个恢复期间别的写入
  // 排在后面，恢复写出的记录序号连续、与落库顺序一致。
  await store.runExclusive(() async {
    try {
      await store.db.transaction(() async {
        report.mergedEvents = await _mergeBackupEvents(
          store,
          backupEvents,
          backupServerTimes,
        );
        await debugOnStage?.call('merged');
        await _restoreFields(store, backupEvents, report);
        await debugOnStage?.call('fields');
        await _restoreLogs(store, backupEvents, backupId, report);
        await debugOnStage?.call('logs');
      });
    } catch (_) {
      // 事务回滚了库，但写入者的因果上下文 / 时钟 / 发件箱序号已在内存里前进：从库重读，
      // 否则 applied 里留着回滚掉的 dot（见 SrsDbStore.reloadLocal）。
      await store.reloadLocal();
      rethrow;
    }
  });
  return report;
}

/// 第 1 步：备份事件按 ID 取并集并进本机；本机原来没有、落下来的重新进发件箱。
Future<int> _mergeBackupEvents(
  SrsDbStore store,
  List<SrsEvent> events,
  Map<String, int> serverTimes,
) async {
  if (events.isEmpty) return 0;
  // 只要 ID：不读正文、不逐条解码（整库导出在大库上是秒级）。
  final Set<String> before = (await store.exportAllIds()).toSet();
  await store.applyRemote(events);
  final Set<String> ids = <String>{for (final SrsEvent e in events) e.id};
  final Map<String, int> times = <String, int>{
    for (final MapEntry<String, int> t in serverTimes.entries)
      if (ids.contains(t.key)) t.key: t.value,
  };
  if (times.isNotEmpty) await store.observeServerTimes(times);
  final Set<String> after = (await store.exportAllIds()).toSet();
  final List<String> fresh = <String>[
    for (final String id in ids)
      if (!before.contains(id) && after.contains(id)) id,
  ];
  if (fresh.isNotEmpty) await store.requeue(fresh);
  return fresh.length;
}

typedef _EntityKey = (SrsEntityKind, String);

Map<_EntityKey, List<SrsFieldEdit>> _editsByEntity(Iterable<SrsEvent> events) {
  final Map<_EntityKey, List<SrsFieldEdit>> out =
      <_EntityKey, List<SrsFieldEdit>>{};
  for (final SrsEvent e in events) {
    if (e is SrsEditEvent) {
      (out[(e.edit.entityKind, e.edit.entityId)] ??= <SrsFieldEdit>[]).add(
        e.edit,
      );
    }
  }
  return out;
}

/// 第 2 步：可编辑字段回到备份时的值。
Future<void> _restoreFields(
  SrsDbStore store,
  List<SrsEvent> backupEvents,
  SrsRestoreReport report,
) async {
  final List<SrsEvent> local = await store.exportAll();
  final Map<String, int> s = await store.exportServerTimes();
  int? serverTimeOf(String id) => s[id];

  final Map<_EntityKey, List<SrsFieldEdit>> backupEdits = _editsByEntity(
    backupEvents,
  );
  final Map<_EntityKey, List<SrsFieldEdit>> localEdits = _editsByEntity(local);
  final Set<String> backupEntityIds = <String>{
    for (final SrsEvent e in backupEvents)
      if (e is SrsEntityEvent) e.record.id,
  };
  final Map<String, SrsEntityRecord> localRecords = <String, SrsEntityRecord>{
    for (final SrsEvent e in local)
      if (e is SrsEntityEvent) e.record.id: e.record,
  };
  final Set<String> builtinIds = <String>{
    for (final SrsEntityRecord r in srsBuiltinEntities(store.profileUid)) r.id,
  };

  final (int nowMs, _) = store.now();
  final List<SrsEditSpec> specs = <SrsEditSpec>[];

  // 备份之后才出现的笔记 / 牌组 / 笔记类型：删掉（内置行每台设备都有，不算「之后才出现」）。
  final Set<String> createdAfter = <String>{};
  final List<SrsEntityRecord> fresh = <SrsEntityRecord>[
    for (final SrsEntityRecord r in localRecords.values)
      if (_deletableKinds.contains(r.kind) &&
          !backupEntityIds.contains(r.id) &&
          !builtinIds.contains(r.id))
        r,
  ];
  // 寄存器整批一次 FFI 调用（字段寄存器内核）。
  final List<SrsEntityEdits> freshEdits =
      SrsEntityEdits.buildMany(<List<SrsFieldEdit>>[
        for (final SrsEntityRecord r in fresh)
          localEdits[(r.kind, r.id)] ?? const <SrsFieldEdit>[],
      ], serverTimeOf: serverTimeOf);
  for (int i = 0; i < fresh.length; i++) {
    final SrsEntityRecord r = fresh[i];
    createdAfter.add(r.id);
    final SrsRegister? del = freshEdits[i][SrsFieldKeys.deleted];
    if (del != null && !del.conflicted && freshEdits[i].deletedAt != null) {
      continue;
    }
    specs.add(SrsEditSpec(r.kind, r.id, SrsFieldKeys.deleted, nowMs));
    report.entitiesDeleted++;
  }

  // 被删笔记的卡片不用逐张改回（生成门已经挡住它们），省掉无意义的同步行。
  final Map<String, String> noteOfCard = <String, String>{
    for (final SrsCardCacheRow c in await store.allCardRows()) c.id: c.noteId,
  };

  final Set<_EntityKey> entities = <_EntityKey>{
    ...backupEdits.keys,
    ...localEdits.keys,
  };
  final List<_EntityKey> keyed = <_EntityKey>[
    for (final _EntityKey key in entities)
      if (!createdAfter.contains(key.$2) &&
          !(key.$1 == SrsEntityKind.card &&
              createdAfter.contains(noteOfCard[key.$2] ?? '')))
        key,
  ];
  // 备份时与现在的寄存器各整批一次 FFI 调用（字段寄存器内核）。
  final List<SrsEntityEdits> wants = SrsEntityEdits.buildMany(
    <List<SrsFieldEdit>>[
      for (final _EntityKey key in keyed)
        backupEdits[key] ?? const <SrsFieldEdit>[],
    ],
    serverTimeOf: serverTimeOf,
  );
  final List<SrsEntityEdits> haves = SrsEntityEdits.buildMany(
    <List<SrsFieldEdit>>[
      for (final _EntityKey key in keyed)
        localEdits[key] ?? const <SrsFieldEdit>[],
    ],
    serverTimeOf: serverTimeOf,
  );
  // 要改回的候选按原顺序攒着；要判 no-op 的（现值与目标比较）最后整批一次 FFI 调用。
  final List<(SrsEditSpec, int, bool)> candidates =
      <(SrsEditSpec, int, bool)>[];
  final List<(SrsRegister?, Object?)> noopAsk = <(SrsRegister?, Object?)>[];
  for (int k = 0; k < keyed.length; k++) {
    final (SrsEntityKind kind, String id) = keyed[k];
    final SrsEntityEdits want = wants[k];
    final SrsEntityEdits have = haves[k];
    final Set<String> keys = <String>{...want.keys, ...have.keys};
    for (final String field in keys) {
      final SrsRegister? cur = have[field];
      final SrsRegister? had = want[field];
      final Object? target;
      int noopAt = -1;
      if (field == SrsFieldKeys.deleted) {
        // 删除优先：备份时只要有一条没被支配的删除记录，行就是已删，不看排序赢家。
        target = had == null ? null : want.deletedAt;
        if (cur == null) {
          if (target == null) continue;
        } else if (!cur.conflicted &&
            (have.deletedAt != null) == (target != null)) {
          continue;
        }
      } else {
        target = had != null
            ? want.value(field)
            : _absentValue(store, localRecords[id], kind, field, cur);
        if (cur == null) {
          if (target == null) continue;
        } else {
          noopAsk.add((cur, target));
          noopAt = noopAsk.length - 1;
        }
      }
      final bool restored =
          field == SrsFieldKeys.deleted &&
          target == null &&
          cur != null &&
          have.deletedAt != null;
      candidates.add((SrsEditSpec(kind, id, field, target), noopAt, restored));
    }
  }
  final List<bool> noop = srsEditsAreNoop(noopAsk);
  for (final (SrsEditSpec spec, int noopAt, bool restored) in candidates) {
    if (noopAt >= 0 && noop[noopAt]) continue;
    if (restored) report.entitiesRestored++;
    specs.add(spec);
  }
  if (specs.isEmpty) return;
  report.fieldEdits = (await store.writeEdits(specs)).length;
}

/// 备份里没有这个字段键时，「不存在」对应写什么值。
Object? _absentValue(
  SrsDbStore store,
  SrsEntityRecord? record,
  SrsEntityKind kind,
  String field,
  SrsRegister? current,
) {
  if (kind != SrsEntityKind.noteType) return null;
  final bool isField = field.startsWith('fieldDef/');
  final bool isTemplate = field.startsWith('tmplDef/');
  if (!isField && !isTemplate) return null;
  final String itemId = field.substring(field.indexOf('/') + 1);
  // 内置笔记类型的项：没有修改记录 = 跟随代码，写回代码里的定义。
  final SrsBuiltinNoteType? builtin = srsBuiltinNoteTypeForKey(
    store.profileUid,
    record?.payload['builtin'] as String?,
  );
  if (builtin != null) {
    if (isField) {
      for (final SrsFieldDef f in builtin.fields) {
        if (f.id == itemId) return f.toValue();
      }
    } else {
      for (final SrsTemplateDef t in builtin.templates) {
        if (t.id == itemId) return t.toValue();
      }
    }
  }
  // 备份之后才加的字段 / 模板：软删除（null 会被读成一个空名字的项）。
  final Object? v = current?.value;
  return <String, Object?>{
    if (v is Map) ...v.cast<String, Object?>(),
    'deleted': true,
  };
}

/// 第 3 步：复习日志回到备份时的有效集合；仍不一致的卡照抄备份时的状态。
Future<void> _restoreLogs(
  SrsDbStore store,
  List<SrsEvent> backupEvents,
  String backupId,
  SrsRestoreReport report,
) async {
  final Set<String> backupLogIds = <String>{
    for (final SrsEvent e in backupEvents)
      if (e is SrsLogEvent) e.log.id,
  };
  final Map<String, int> s = await store.exportServerTimes();
  int? serverTimeOf(String id) => s[id];

  final Map<String, List<SrsReviewLog>> byCard = <String, List<SrsReviewLog>>{};
  // 卡片的「前身」链接（更改笔记类型）：前身 → 继承它历史的卡。
  final Map<String, Set<String>> successors = <String, Set<String>>{};
  for (final SrsEvent e in await store.exportAll()) {
    if (e is SrsLogEvent) {
      (byCard[e.log.cardId] ??= <SrsReviewLog>[]).add(e.log);
    } else if (e is SrsEditEvent &&
        e.edit.entityKind == SrsEntityKind.card &&
        e.edit.fieldKey.startsWith(SrsFieldKeys.cardHistoryFromPrefix)) {
      (successors[e.edit.fieldKey.substring(
                SrsFieldKeys.cardHistoryFromPrefix.length,
              )] ??=
              <String>{})
          .add(e.edit.entityId);
    }
  }
  // 受影响的卡：有不在备份里的日志（备份之后的复习、撤销等）的卡。其余卡的日志与备份时完全相同，
  // 状态必然一致，不用逐卡读历史。
  final Set<String> affected = <String>{
    for (final MapEntry<String, List<SrsReviewLog>> e in byCard.entries)
      if (e.value.any((SrsReviewLog l) => !backupLogIds.contains(l.id))) e.key,
  };
  final SrsLogContext ctx = await store.logContext();
  final List<SrsReviewLog> undos = <SrsReviewLog>[
    for (final String card in affected)
      ...srsPlanRevokeLogs(
        logs: byCard[card]!,
        backupLogIds: backupLogIds,
        ctx: ctx,
        backupId: backupId,
        serverTimeOf: serverTimeOf,
      ),
  ];
  await store.appendLocalLogs(undos);
  report.logsRevoked = undos.length;

  // 状态核对：受影响的卡，加上经「前身」链接继承了它们历史的卡。
  final Set<String> check = <String>{...affected};
  final List<String> queue = affected.toList();
  while (queue.isNotEmpty) {
    for (final String next in successors[queue.removeLast()] ?? <String>{}) {
      if (check.add(next)) queue.add(next);
    }
  }
  final Set<String> cached = <String>{
    for (final SrsCardCacheRow c in await store.cardRows(check)) c.id,
  };
  final List<SrsReviewLog> fixes = <SrsReviewLog>[];
  int cardsFixed = 0;
  // 各卡历史按块一次预读（以前每张卡各查四五次，BUG-3543）。
  final Map<String, SrsCardHistory> histories = await store.histories(cached);
  for (final String cardId in cached) {
    final List<SrsReviewLog> fix = srsPlanStateRestore(
      cardId: cardId,
      current: histories[cardId]!,
      backupLogIds: backupLogIds,
      ctx: ctx,
      backupId: backupId,
      serverTimeOf: serverTimeOf,
    );
    if (fix.isEmpty) continue;
    cardsFixed++;
    fixes.addAll(fix);
  }
  await store.appendLocalLogs(fixes);
  report.statesRestored = cardsFixed;
}
