/// 合并内核：一个副本持有的全部事件，以及由它们确定性算出的状态。
///
/// 同步合并、备份合并、快照起步都调这一份：按 ID 取并集（幂等、顺序无关），可编辑字段走多值寄存器，
/// 排程走「最后一条有效日志」。模拟器（test/simulator）直接测这份代码。
library;

import 'causal_context.dart';
import 'entities.dart';
import 'field_edit.dart';
import 'review_log.dart';
import 'ordering.dart';
import 'valid_logs.dart';

/// 一条同步事件（批次 / 快照 / 备份里的一项）。
sealed class SrsEvent {
  const SrsEvent();

  String get id;

  Map<String, Object?> toJson();

  String canonical() => srsCanonicalJson(toJson());

  static SrsEvent fromJson(Map<String, Object?> json) {
    switch (json['t']) {
      case 'entity':
        return SrsEntityEvent(
          SrsEntityRecord.fromJson((json['x']! as Map).cast<String, Object?>()),
        );
      case 'edit':
        return SrsEditEvent(
          SrsFieldEdit.fromJson((json['x']! as Map).cast<String, Object?>()),
        );
      case 'log':
        return SrsLogEvent(
          SrsReviewLog.fromJson((json['x']! as Map).cast<String, Object?>()),
        );
      default:
        return SrsUnknownEvent(json);
    }
  }
}

class SrsEntityEvent extends SrsEvent {
  const SrsEntityEvent(this.record);

  final SrsEntityRecord record;

  @override
  String get id => record.id;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'entity',
    'x': record.toJson(),
  };
}

class SrsEditEvent extends SrsEvent {
  const SrsEditEvent(this.edit);

  final SrsFieldEdit edit;

  @override
  String get id => edit.id;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'edit',
    'x': edit.toJson(),
  };
}

class SrsLogEvent extends SrsEvent {
  const SrsLogEvent(this.log);

  final SrsReviewLog log;

  @override
  String get id => log.id;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'log',
    'x': log.toJson(),
  };
}

/// 不认识的事件类型（更新版本写来的）：原样保留、原样转写，不解析。
class SrsUnknownEvent extends SrsEvent {
  const SrsUnknownEvent(this.raw);

  final Map<String, Object?> raw;

  @override
  String get id =>
      (raw['x'] is Map ? (raw['x'] as Map)['id'] : null) as String? ??
      srsCanonicalJson(raw);

  @override
  Map<String, Object?> toJson() => raw;
}

/// 内存中的事件集合。
class SrsEventStore {
  final Map<String, SrsEntityRecord> entities = <String, SrsEntityRecord>{};

  /// registerKey → (editId → edit)，只保留没被支配的记录。
  final Map<String, Map<String, SrsFieldEdit>> _edits =
      <String, Map<String, SrsFieldEdit>>{};

  /// 本副本已应用的修改记录的因果上下文（含闭包）：已被支配而丢掉的记录也算「已见过」。
  SrsCausalContext _seen = SrsCausalContext.empty();

  /// cardId → (logId → log)。
  final Map<String, Map<String, SrsReviewLog>> logs =
      <String, Map<String, SrsReviewLog>>{};
  final Map<String, SrsUnknownEvent> unknown = <String, SrsUnknownEvent>{};

  /// S(e)：所有已见到的、包含 e 的批次的 S 的最小值。
  final Map<String, int> serverTime = <String, int>{};

  /// 同 ID 异内容的诊断（只可能是 bug / 损坏）。
  final List<String> diagnostics = <String>[];

  SrsCausalContext get seenContext => _seen;

  int? serverTimeOf(String eventId) => serverTime[eventId];

  /// 记录一次 S 观察（批次信封 / 快照映射）。
  void observeServerTime(String eventId, int s) {
    serverTime[eventId] = srsMergeServerTime(serverTime[eventId], s)!;
  }

  /// 应用一条事件（幂等）。返回是否有变化。
  bool apply(SrsEvent event, {int? serverTimeMs}) {
    if (serverTimeMs != null) observeServerTime(event.id, serverTimeMs);
    switch (event) {
      case SrsEntityEvent(:final SrsEntityRecord record):
        final SrsEntityRecord? old = entities[record.id];
        if (old == null) {
          entities[record.id] = record;
          return true;
        }
        if (old.canonical() == record.canonical()) return false;
        diagnostics.add('entity ${record.id}: same id, different content');
        final SrsEntityRecord pick = SrsEntityRecord.pick(old, record);
        entities[record.id] = pick;
        return !identical(pick, old);
      case SrsEditEvent(:final SrsFieldEdit edit):
        return _applyEdit(edit);
      case SrsLogEvent(:final SrsReviewLog log):
        final Map<String, SrsReviewLog> m = logs[log.cardId] ??=
            <String, SrsReviewLog>{};
        final SrsReviewLog? old = m[log.id];
        if (old == null) {
          m[log.id] = log;
          return true;
        }
        if (old.canonical() == log.canonical()) return false;
        diagnostics.add('log ${log.id}: same id, different content');
        if (log.canonical().compareTo(old.canonical()) < 0) {
          m[log.id] = log;
          return true;
        }
        return false;
      case SrsUnknownEvent():
        final bool fresh = !unknown.containsKey(event.id);
        unknown[event.id] = event;
        return fresh;
    }
  }

  bool _applyEdit(SrsFieldEdit edit) {
    final Map<String, SrsFieldEdit> reg = _edits[edit.registerKey] ??=
        <String, SrsFieldEdit>{};
    final SrsFieldEdit? same = reg[edit.id];
    if (same != null) {
      if (same.canonical() != edit.canonical()) {
        diagnostics.add('edit ${edit.id}: same id, different content');
      }
      return false;
    }
    _seen = _seen.merge(edit.ctx).add(edit.dot);
    // 被同一字段键上的已有记录支配：丢掉。支配可传递（任何含 a.dot 的上下文都 ⊇ a.ctx，
    // 因为 dot 只能经「应用该记录」进入上下文），所以被丢掉的记录以后再收到也能当场判出。
    // 注意上下文是全局的：a.dot 出现在别的字段键的记录里，不代表 a 在自己的字段键上被支配。
    if (reg.values.any((SrsFieldEdit b) => b.dominates(edit))) return false;
    reg.removeWhere((String _, SrsFieldEdit a) => edit.dominates(a));
    reg[edit.id] = edit;
    return true;
  }

  /// 全部现存（未被支配的）修改记录。
  Iterable<SrsFieldEdit> get liveEdits =>
      _edits.values.expand((Map<String, SrsFieldEdit> m) => m.values);

  /// 某实体的寄存器。
  SrsEntityEdits editsOf(SrsEntityKind kind, String entityId) {
    final String prefix = '${kind.wire}/$entityId/';
    return SrsEntityEdits.build(<SrsFieldEdit>[
      for (final MapEntry<String, Map<String, SrsFieldEdit>> e
          in _edits.entries)
        if (e.key.startsWith(prefix)) ...e.value.values,
    ], serverTimeOf: serverTimeOf);
  }

  SrsCardHistory historyOf(String cardId) => SrsCardHistory(
    logs[cardId]?.values ?? const <SrsReviewLog>[],
    serverTimeOf: serverTimeOf,
  );

  /// 全部事件（快照 / 备份导出用）：身份记录、现存修改记录、全部日志、不认识的事件。
  Iterable<SrsEvent> allEvents() sync* {
    for (final SrsEntityRecord r in entities.values) {
      yield SrsEntityEvent(r);
    }
    for (final SrsFieldEdit e in liveEdits) {
      yield SrsEditEvent(e);
    }
    for (final Map<String, SrsReviewLog> m in logs.values) {
      for (final SrsReviewLog l in m.values) {
        yield SrsLogEvent(l);
      }
    }
    yield* unknown.values;
  }

  /// 收敛判定用的规范摘要：寄存器（live 集合与生效值）、每张卡的排程状态、身份记录。
  /// 不含本机元信息（published、收到时间等）。
  String digest() {
    final List<String> regs = <String>[
      for (final MapEntry<String, Map<String, SrsFieldEdit>> e
          in _edits.entries)
        if (e.value.isNotEmpty) _registerDigest(e.key, e.value.values),
    ]..sort();
    final List<String> cards = <String>[
      for (final String cardId in logs.keys)
        '$cardId=${srsCanonicalJson(historyOf(cardId).state.toJson())}'
            '|${historyOf(cardId).lastEffective?.id}',
    ]..sort();
    final List<String> ents = <String>[
      for (final SrsEntityRecord r in entities.values) r.canonical(),
    ]..sort();
    final List<String> logIds = <String>[
      for (final Map<String, SrsReviewLog> m in logs.values) ...m.keys,
    ]..sort();
    return srsCanonicalJson(<String, Object?>{
      'regs': regs,
      'cards': cards,
      'ents': ents,
      'logs': logIds,
    });
  }

  String _registerDigest(String key, Iterable<SrsFieldEdit> edits) {
    final SrsRegister r = srsResolveRegister(
      key,
      edits,
      serverTimeOf: serverTimeOf,
    );
    return '$key:${r.live.map((SrsFieldEdit e) => e.id).join(',')}'
        '=${srsCanonicalJson(r.value)}';
  }
}
