/// 内存副本：[SrsEventStore] + 本机写入者身份 + 发件箱 + 同步状态。
/// 模拟器的设备就是它；数据库副本（fushi_engine）的行为必须与它一致。
library;

import '../causal_context.dart';
import '../entities.dart';
import '../event_store.dart';
import '../field_edit.dart';
import '../hlc.dart';
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
    final SrsRegister current =
        store.editsOf(kind, entityId)[key] ??
        srsResolveRegister('', const <SrsFieldEdit>[]);
    if (srsEditIsNoop(current, value)) return null;
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

  /// 恢复备份：本机数据整体换成备份内容；换新化身号（不复用旧 writerId），备份里没发布过的事件由新化身重新发布。
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
    store = SrsEventStore();
    store.serverTime.addAll(b.serverTimes);
    for (final SrsEvent e in b.events) {
      store.apply(e);
      if (b.unpublishedIds.contains(e.id)) {
        _local[e.id] = e;
        _outbox.add(e.id);
      }
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
  Future<List<SrsEvent>> unpublishedEvents() async => <SrsEvent>[
    for (final String id in _outbox) _local[id]!,
  ];

  @override
  Future<void> markPublished(List<String> eventIds) async {
    _outbox.removeWhere(eventIds.contains);
  }

  @override
  Future<void> requeue(List<String> eventIds) async {
    for (final String id in eventIds) {
      if (!_outbox.contains(id) && _local.containsKey(id)) _outbox.add(id);
    }
  }

  @override
  Future<void> applyRemote(List<SrsEvent> events, {int? serverTimeMs}) async {
    final (int now, SrsTimeSource _) = trustedNow();
    for (final SrsEvent e in events) {
      store.apply(e, serverTimeMs: serverTimeMs);
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

  @override
  Future<void> observeServerTimes(Map<String, int> times) async {
    times.forEach(store.observeServerTime);
  }

  @override
  Future<List<SrsEvent>> exportAll() async => store.allEvents().toList();

  @override
  Future<Map<String, int>> exportServerTimes() async =>
      Map<String, int>.of(store.serverTime);

  @override
  String newIncarnationWriterId() {
    _incarnation += 1;
    return '$deviceId#$_incarnation';
  }

  SrsCausalContext get seen => store.seenContext;
}
