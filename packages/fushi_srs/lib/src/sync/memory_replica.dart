/// 内存副本：[SrsEventStore] + 本机写入者身份 + 发件箱 + 同步状态。
/// 模拟器的设备就是它；数据库副本（fushi_engine）的行为必须与它一致。
library;

import 'dart:collection';
import 'dart:typed_data';

import '../causal_context.dart';
import '../entities.dart';
import '../event_store.dart';
import '../field_edit.dart';
import '../hlc.dart';
import '../register_kernel.dart';
import '../review_log.dart';
import 'sync_engine.dart';

/// 备份：完整合并状态 + S 映射 + 哪些事件还没发布（「备份在发布之前做」的情形）。
class SrsBackup {
  const SrsBackup({
    required this.events,
    required this.serverTimes,
    required this.unpublishedIds,
  });

  final List<SrsEvent> events;
  final Map<String, int> serverTimes;
  final List<String> unpublishedIds;
}

class SrsMemoryReplica implements SrsSyncReplica {
  SrsMemoryReplica({
    required this.deviceId,
    required this.trustedNow,
    int incarnation = 1,
  }) : _incarnation = incarnation,
       _state = SrsSyncLocalState(writerId: '$deviceId#$incarnation') {
    clock = HlcClock(_state.writerId);
    writer = SrsEditWriter(writerId: _state.writerId);
  }

  final String deviceId;

  /// (可信时间, 来源)。
  final (int, SrsTimeSource) Function() trustedNow;
  int _incarnation;
  SrsSyncLocalState _state;

  SrsEventStore store = SrsEventStore();
  late HlcClock clock;
  late SrsEditWriter writer;
  final List<String> _outbox = <String>[];
  final Map<String, SrsEvent> _local = <String, SrsEvent>{};

  /// 已冻结批次的本机留存：写入者 → 批次号 → 字节。
  final Map<String, SplayTreeMap<int, Uint8List>> _sent =
      <String, SplayTreeMap<int, Uint8List>>{};

  String get writerId => _state.writerId;
  SrsSyncLocalState get syncState => _state;

  // ---- 本机产生事件 ----

  void _emit(SrsEvent e) {
    store.apply(e);
    _local[e.id] = e;
    _outbox.add(e.id);
  }

  void createEntity(SrsEntityRecord record) {
    if (store.entities.containsKey(record.id)) return;
    _emit(SrsEntityEvent(record));
  }

  /// 改一个字段（no-op 不产生记录）。返回新记录或 null。
  SrsFieldEdit? edit(
    String profileUid,
    SrsEntityKind kind,
    String entityId,
    String key,
    Object? value, {
    bool machine = false,
  }) {
    final SrsRegister? current = store.editsOf(kind, entityId)[key];
    if (current != null && srsEditIsNoop(current, value)) return null;
    final (int now, SrsTimeSource src) = trustedNow();
    writer.adopt(store.seenContext);
    final SrsFieldEdit e = writer.create(
      profileUid: profileUid,
      entityKind: kind,
      entityId: entityId,
      fieldKey: key,
      value: value,
      hlc: clock.tick(now),
      timeSource: src,
      machine: machine,
    );
    _emit(SrsEditEvent(e));
    return e;
  }

  void addLog(SrsReviewLog log) => _emit(SrsLogEvent(log));

  // ---- 备份 / 恢复 ----

  SrsBackup backup() => SrsBackup(
    events: store.allEvents().toList(),
    serverTimes: Map<String, int>.of(store.serverTime),
    unpublishedIds: List<String>.of(_outbox),
  );

  /// 恢复备份：本机数据整体换成备份内容；换新化身号（不复用旧 writerId），备份里的全部事件由新化身重新发布
  /// （与数据库副本 `SrsDbStore.afterRestore` 一致：新化身不知道每个同步目录里已经有哪些，
  /// 多目录时旧化身的批次未必到过每个目录；事件不可变、按 ID 取并集，重复发布无害）。
  /// 备份之后才产生、又没发布出去的本机改动随之丢失（这是「恢复旧备份」本身的语义）。
  /// 事件不可变，它们的 dot / HLC 仍属旧写入者（第六轮审查第 2 条，由因果上下文按 dot 处理）。
  void restore(SrsBackup b) {
    _incarnation += 1;
    _state = SrsSyncLocalState(writerId: '$deviceId#$_incarnation');
    clock = HlcClock(
      _state.writerId,
      last: Hlc(clock.last.physical, clock.last.counter, _state.writerId),
    );
    writer = SrsEditWriter(writerId: _state.writerId);
    _outbox.clear();
    _local.clear();
    _sent.clear();
    store = SrsEventStore();
    store.serverTime.addAll(b.serverTimes);
    for (final SrsEvent e in b.events) {
      store.apply(e);
      _local[e.id] = e;
      _outbox.add(e.id);
    }
    writer.adopt(store.seenContext);
  }

  // ---- SrsSyncReplica ----

  @override
  Future<SrsSyncLocalState> loadSyncState() async => _state;

  @override
  Future<void> saveSyncState(SrsSyncLocalState state) async {
    _state = state;
    if (writer.writerId != state.writerId) {
      writer = SrsEditWriter(
        writerId: state.writerId,
        applied: store.seenContext,
      );
      clock = HlcClock(
        state.writerId,
        last: Hlc(clock.last.physical, clock.last.counter, state.writerId),
      );
    }
  }

  @override
  Future<List<SrsEvent>> unpublishedEvents({int? limit}) async => <SrsEvent>[
    for (final String id in limit == null ? _outbox : _outbox.take(limit))
      _local[id]!,
  ];

  @override
  Future<void> freezeBatch(
    SrsSyncLocalState state,
    int no,
    Uint8List bytes,
    List<String> eventIds,
  ) async {
    (_sent[state.writerId] ??= SplayTreeMap<int, Uint8List>())[no] = bytes;
    final Set<String> ids = eventIds.toSet();
    _outbox.removeWhere(ids.contains);
    await saveSyncState(state);
  }

  @override
  Future<Uint8List?> sentBatch(String writerId, int no) async =>
      _sent[writerId]?[no];

  @override
  Future<List<int>> sentBatchNos(String writerId) async =>
      _sent[writerId]?.keys.toList() ?? <int>[];

  @override
  Future<void> dropSentBatches(String writerId, {int? throughNo}) async {
    if (throughNo == null) {
      _sent.remove(writerId);
      return;
    }
    _sent[writerId]?.removeWhere((int no, Uint8List _) => no <= throughNo);
  }

  @override
  Future<void> requeue(List<String> eventIds) async {
    // 重新发布的可以是对端的事件（转发 / 换化身 / 目录起步）：按 ID 从合并状态里取。
    Map<String, SrsEvent>? all;
    for (final String id in eventIds) {
      if (_outbox.contains(id)) continue;
      SrsEvent? e = _local[id];
      if (e == null) {
        all ??= <String, SrsEvent>{
          for (final SrsEvent x in store.allEvents()) x.id: x,
        };
        e = all[id];
      }
      if (e == null) continue;
      _local[id] = e;
      _outbox.add(id);
    }
  }

  @override
  Future<void> applyRemote(
    List<SrsEvent> events, {
    int? serverTimeMs,
    bool forward = false,
  }) async {
    final (int now, SrsTimeSource _) = trustedNow();
    for (final SrsEvent e in events) {
      final int? before = store.serverTimeOf(e.id);
      final bool landed = store.apply(e, serverTimeMs: serverTimeMs);
      if (forward &&
          (landed || _lowered(before, store.serverTimeOf(e.id))) &&
          !_outbox.contains(e.id)) {
        _local[e.id] = e;
        _outbox.add(e.id);
      }
      final Hlc? h = switch (e) {
        SrsEditEvent(:final SrsFieldEdit edit) => edit.hlc,
        SrsLogEvent(:final SrsReviewLog log) => log.hlc,
        _ => null,
      };
      if (h != null) {
        clock.receive(
          h,
          serverTimeMs: serverTimeMs ?? store.serverTimeOf(e.id),
          trustedNowMs: now,
        );
      }
    }
    writer.adopt(store.seenContext);
  }

  /// S 变小了（含从未知变成已知）。
  static bool _lowered(int? before, int? after) =>
      after != null && (before == null || after < before);

  @override
  Future<void> observeServerTimes(
    Map<String, int> times, {
    bool forward = false,
  }) async {
    final List<String> lowered = <String>[];
    times.forEach((String id, int s) {
      final int? before = store.serverTimeOf(id);
      store.observeServerTime(id, s);
      if (forward && _lowered(before, store.serverTimeOf(id))) lowered.add(id);
    });
    // 已在本机的事件才转发（还没到的随后落地时按「新落地」转发）。
    if (lowered.isNotEmpty) await requeue(lowered);
  }

  @override
  Future<Map<String, int>> knownServerTimes(List<String> eventIds) async =>
      <String, int>{
        for (final String id in eventIds)
          if (store.serverTimeOf(id) case final int s) id: s,
      };

  @override
  Future<List<SrsEvent>> exportAll() async => store.allEvents().toList();

  @override
  Future<Map<String, int>> exportServerTimes() async =>
      Map<String, int>.of(store.serverTime);

  @override
  Future<List<String>> exportAllIds() async => <String>[
    for (final SrsEvent e in store.allEvents()) e.id,
  ];

  @override
  Future<void> exportSnapshotPages({
    required Future<void> Function(List<String> canonicalLines) onEvents,
    required Future<void> Function(List<(String, int)> serverTimes)
    onServerTimes,
  }) async {
    await onEvents(<String>[
      for (final SrsEvent e in store.allEvents()) e.canonical(),
    ]);
    await onServerTimes(<(String, int)>[
      for (final MapEntry<String, int> e in store.serverTime.entries)
        (e.key, e.value),
    ]);
  }

  @override
  String newIncarnationWriterId() {
    _incarnation += 1;
    return '$deviceId#$_incarnation';
  }

  SrsCausalContext get seen => store.seenContext;
}
