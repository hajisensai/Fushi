// 快照 / 批次在大库上不在调用方 isolate 上做 O(全部历史) 的同步工作（反馈 OMWOurRQKb）。
//
// 以前每写一份快照：`exportAll()` 把全部事件物化成对象、`SrsSnapshot.encode` 在调用方 isolate 上整份
// 规范编码 + SHA-256、写完再 `SrsSnapshot.decode` 整份读回解析；发件箱也一次整个读进内存再切批。
// 大库上单段阻塞秒级，桌面看门狗报主线程无响应。快照写不成时 lastSnapshotBatch 不前进，每轮同步重做一遍。
//
// 现在：快照正文按页从副本读（exportSnapshotPages），拼接 / 摘要 / 读回校验在后台 isolate；
// 冻结按批次逐页取发件箱；快照没写成时按批次数 / 时间退避。
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const String kProfile = '01928c3e-0000-7000-8000-00000000f00d';

/// 内存同步目录；[dropSnapshotReads] 为真时快照读回不到（模拟上传丢失 / 读回失败）。
class _Dir implements SrsSyncDirectory {
  _Dir(this.now);

  final int Function() now;
  final Map<String, Map<String, Uint8List>> files =
      <String, Map<String, Uint8List>>{};
  bool dropSnapshotReads = false;
  int snapshotWrites = 0;

  @override
  Future<List<String>> listWriters() async => files.keys.toList()..sort();
  @override
  Future<List<String>?> listFiles(String w) async => files[w]?.keys.toList();
  @override
  Future<Uint8List?> read(String w, String n) async =>
      dropSnapshotReads && srsParseSnapshotName(n) != null
      ? null
      : files[w]?[n];
  @override
  Future<void> write(String w, String n, Uint8List b) async {
    if (srsParseSnapshotName(n) != null) snapshotWrites++;
    (files[w] ??= <String, Uint8List>{})[n] = b;
  }

  @override
  Future<void> delete(String w, String n) async => files[w]?.remove(n);
  @override
  Future<void> deleteWriter(String w) async => files.remove(w);
  @override
  Future<int?> serverTime(String w) async {
    await write(w, srsProbeName, Uint8List(0));
    return now();
  }
}

/// 委托给内存副本，但整份导出（[exportAll] / [exportServerTimes]）一调就失败，
/// 并记下每次取发件箱的 limit。
class _PagedOnly implements SrsSyncReplica {
  _PagedOnly(this.inner);

  final SrsMemoryReplica inner;
  final List<int?> unpublishedLimits = <int?>[];

  @override
  Future<List<SrsEvent>> exportAll() =>
      fail('sync engine must not materialize the whole state (exportAll)');
  @override
  Future<Map<String, int>> exportServerTimes() => fail(
    'sync engine must not materialize all server times (exportServerTimes)',
  );

  @override
  Future<List<SrsEvent>> unpublishedEvents({int? limit}) {
    unpublishedLimits.add(limit);
    return inner.unpublishedEvents(limit: limit);
  }

  @override
  Future<SrsSyncLocalState> loadSyncState() => inner.loadSyncState();
  @override
  Future<void> saveSyncState(SrsSyncLocalState state) =>
      inner.saveSyncState(state);
  @override
  Future<void> freezeBatch(
    SrsSyncLocalState state,
    int no,
    Uint8List bytes,
    List<String> eventIds,
  ) => inner.freezeBatch(state, no, bytes, eventIds);
  @override
  Future<Uint8List?> sentBatch(String writerId, int no) =>
      inner.sentBatch(writerId, no);
  @override
  Future<List<int>> sentBatchNos(String writerId) =>
      inner.sentBatchNos(writerId);
  @override
  Future<void> dropSentBatches(String writerId, {int? throughNo}) =>
      inner.dropSentBatches(writerId, throughNo: throughNo);
  @override
  Future<void> requeue(List<String> eventIds) => inner.requeue(eventIds);
  @override
  Future<void> applyRemote(
    List<SrsEvent> events, {
    int? serverTimeMs,
    bool forward = false,
  }) => inner.applyRemote(events, serverTimeMs: serverTimeMs, forward: forward);
  @override
  Future<void> observeServerTimes(
    Map<String, int> times, {
    bool forward = false,
  }) => inner.observeServerTimes(times, forward: forward);
  @override
  Future<Map<String, int>> knownServerTimes(List<String> eventIds) =>
      inner.knownServerTimes(eventIds);
  @override
  Future<List<String>> exportAllIds() => inner.exportAllIds();
  @override
  Future<void> exportSnapshotPages({
    required Future<void> Function(List<String> canonicalLines) onEvents,
    required Future<void> Function(List<(String, int)> serverTimes)
    onServerTimes,
  }) => inner.exportSnapshotPages(
    onEvents: onEvents,
    onServerTimes: onServerTimes,
  );
  @override
  String newIncarnationWriterId() => inner.newIncarnationWriterId();
}

void main() {
  int now = DateTime.utc(2026, 10, 23).millisecondsSinceEpoch;
  SrsMemoryReplica device(String id) => SrsMemoryReplica(
    deviceId: id,
    trustedNow: () => (now, SrsTimeSource.anchored),
  );

  /// [n] 条字段修改，每条值约 300 字节：正文远超 [kSrsOffThreadMinBytes]，走后台 isolate。
  void fill(SrsMemoryReplica r, int n, {String tag = 'v'}) {
    final String pad = 'x' * 300;
    for (int i = 0; i < n; i++) {
      r.edit(kProfile, SrsEntityKind.note, 'note-$i', 'f/body', '$tag$i$pad');
    }
  }

  test('快照按页导出、后台编码；发件箱逐批取；另一台设备从快照起步得到同一份状态', () async {
    final _Dir dir = _Dir(() => now);
    final SrsMemoryReplica a = device('a');
    fill(a, 3000);
    final _PagedOnly paged = _PagedOnly(a);
    const SrsSyncOptions options = SrsSyncOptions(
      maxEventsPerBatch: 1000,
      snapshotEveryBatches: 1,
    );
    final SrsSyncReport r = await SrsSyncEngine(
      directory: dir,
      directoryKey: 'd',
      replica: paged,
      options: options,
    ).syncOnce();
    expect(r.error, isNull);
    expect(r.snapshotWritten, isTrue);
    // 3000 条按 1000 一批逐批取：每次都带 limit，不一次读整个发件箱。
    expect(paged.unpublishedLimits, isNotEmpty);
    expect(paged.unpublishedLimits, everyElement(1000));

    final Map<String, Uint8List> own = dir.files[a.writerId]!;
    final String snapName = own.keys.firstWhere(
      (String f) => srsParseSnapshotName(f) != null,
    );
    expect(own[snapName]!.length, greaterThan(kSrsOffThreadMinBytes));
    final SrsSnapshot snap = (await srsDecodeSnapshot(
      own[snapName]!,
    )).valueOrNull!;
    expect(
      <String>{for (final SrsEvent e in snap.events) e.id},
      <String>{for (final SrsEvent e in a.store.allEvents()) e.id},
    );
    expect(snap.serverTimes, a.store.serverTime);
    expect(snap.vv[a.writerId], snap.maxOwnBatch);

    // 只留快照（批次删掉）：b 只能经快照起步，结果与 a 相同。
    own.removeWhere((String f, Uint8List _) => srsParseBatchName(f) != null);
    final SrsMemoryReplica b = device('b');
    await SrsSyncEngine(
      directory: dir,
      directoryKey: 'd',
      replica: b,
      options: options,
    ).syncOnce();
    expect(
      <String>{for (final SrsEvent e in b.store.allEvents()) e.canonical()},
      <String>{for (final SrsEvent e in a.store.allEvents()) e.canonical()},
    );
    expect(b.store.serverTime, a.store.serverTime);
  });

  test('快照没写成：记下尝试并退避，不在每轮同步上重做整份快照', () async {
    final _Dir dir = _Dir(() => now)..dropSnapshotReads = true;
    final SrsMemoryReplica a = device('a');
    const SrsSyncOptions options = SrsSyncOptions(
      snapshotEveryBatches: 2,
      snapshotRetryAfterMs: 60 * 60 * 1000,
    );
    SrsSyncEngine engine() => SrsSyncEngine(
      directory: dir,
      directoryKey: 'd',
      replica: a,
      options: options,
    );
    Future<SrsSyncReport> round(int edits) async {
      fill(a, edits, tag: 'r$now-');
      now += 1000;
      return engine().syncOnce();
    }

    // 两批之后第一次尝试：读回失败，没写成。
    await round(1);
    expect((await round(1)).snapshotWritten, isFalse);
    expect(dir.snapshotWrites, 1);
    final SrsDirectoryState ds = a.syncState.directories['d']!;
    expect(ds.lastSnapshotBatch, 0);
    expect(ds.snapshotAttemptBatch, 2);
    // 尝试记录随本机状态持久化。
    expect(
      SrsDirectoryState.fromJson(ds.toJson()).snapshotAttemptBatch,
      ds.snapshotAttemptBatch,
    );

    // 之后的轮次：没攒够又一轮批次、也没到重试时间 → 不再尝试。
    await round(0);
    await round(1);
    expect(dir.snapshotWrites, 1);

    // 又攒够 snapshotEveryBatches 个批次 → 再试一次。
    await round(1);
    expect(dir.snapshotWrites, 2);

    // 到了重试时间（没有新批次也试）；这次读回成功 → 写成，退避清除。
    dir.dropSnapshotReads = false;
    now += options.snapshotRetryAfterMs;
    final SrsSyncReport ok = await round(0);
    expect(ok.snapshotWritten, isTrue);
    expect(dir.snapshotWrites, 3);
    expect(ds.lastSnapshotBatch, a.syncState.nextBatchNo - 1);
  });
}
