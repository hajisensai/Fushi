/// 单写者事件日志同步（第三期「传输」）。纯逻辑，不依赖具体后端：
/// 生产经 SyncAssetStore 适配，模拟器用内存目录。
///
/// 硬规则：同步目录里每个文件只由一个写入者写（批次、快照、cursor、探针都在写入者自己的目录下），
/// 其它设备只读；退役写入者的整个目录在满足条件后才可删。
library;

import 'dart:typed_data';

import '../event_store.dart';
import 'sync_files.dart';

/// 同步目录（一个 profile 的 srs/<profileUid>/ 下，每个写入者一个子目录）。
abstract interface class SrsSyncDirectory {
  /// 现存的写入者子目录。
  Future<List<String>> listWriters();

  /// 写入者目录里的文件名；目录不存在返回 null。
  Future<List<String>?> listFiles(String writerId);

  /// 读文件；不存在返回 null。
  Future<Uint8List?> read(String writerId, String name);

  /// 写文件（同名覆盖；目录不存在时创建）。
  Future<void> write(String writerId, String name, Uint8List bytes);

  Future<void> delete(String writerId, String name);

  Future<void> deleteWriter(String writerId);

  /// 服务器时间：在**写入者自己的目录**写探针文件，再读回服务端修改时间（第六轮审查「探针文件的位置」：
  /// 放公共位置会违反「一个文件只有一个写入者」）。拿不到返回 null（该后端不提供 SRS 同步）。
  Future<int?> serverTime(String writerId);
}

/// 本机持久化的同步状态（不同步）。
class SrsSyncLocalState {
  SrsSyncLocalState({
    required this.writerId,
    this.nextBatchNo = 1,
    Map<String, int>? cursors,
    this.frozenBatch,
    this.frozenEventIds = const <String>[],
    this.lastSnapshotBatch = 0,
    this.bootstrapped = false,
    Map<String, int>? lastBatchServerTime,
  }) : cursors = cursors ?? <String, int>{},
       lastBatchServerTime = lastBatchServerTime ?? <String, int>{};

  String writerId;

  /// 下一个要分配的批次号（从 1 起连续）。
  int nextBatchNo;

  /// 对每个写入者的读取进度：只表示无缺口前缀。
  final Map<String, int> cursors;

  /// 已冻结、尚未确认上传成功的批次（重传同号同字节）。
  Uint8List? frozenBatch;
  List<String> frozenEventIds;
  int lastSnapshotBatch;

  /// 是否已经按「读全部现存写入者的最新快照」起步过。
  bool bootstrapped;

  /// 每个写入者最近一个批次的 S（timeUncertain 判定用）。
  final Map<String, int> lastBatchServerTime;

  /// 是否发布过批次。第六轮审查第 15 条：发布过的 profile 不能再改 uid（旧目录会成孤儿）。
  bool get everPublished => nextBatchNo > 1 || frozenBatch != null;
}

/// 本机副本：事件的读写与同步状态的持久化（内存实现见 memory_replica.dart，数据库实现在 fushi_engine）。
abstract interface class SrsSyncReplica {
  Future<SrsSyncLocalState> loadSyncState();
  Future<void> saveSyncState(SrsSyncLocalState state);

  /// 本机产生、还没进任何批次的事件，按创建顺序。
  Future<List<SrsEvent>> unpublishedEvents();

  /// 这些事件已冻结进批次（不再进下一批）。
  Future<void> markPublished(List<String> eventIds);

  /// 冻结过、但所在批次作废（换化身）的事件重新进入发件箱。
  Future<void> requeue(List<String> eventIds);

  /// 应用对端事件（幂等）。[serverTimeMs] 为批次 S；快照应用时为 null（另经 [observeServerTimes]）。
  Future<void> applyRemote(List<SrsEvent> events, {int? serverTimeMs});

  Future<void> observeServerTimes(Map<String, int> times);

  /// 完整合并状态（写快照用）。
  Future<List<SrsEvent>> exportAll();
  Future<Map<String, int>> exportServerTimes();

  /// 本机写入者目录已不存在（被当作退役清理过）：换新化身号（deviceId + 新化身号）。
  String newIncarnationWriterId();
}

/// 一轮同步的结果。
class SrsSyncReport {
  SrsSyncReport();

  int published = 0;
  int applied = 0;
  bool snapshotWritten = false;
  int batchesDeleted = 0;
  final List<String> writersDeleted = <String>[];
  bool reincarnated = false;
  String? error;

  /// 本轮取到的服务器时间（探针文件的服务端修改时间）。调用方据此给可信时间校时（铁律 F 第一层）。
  int? serverTimeMs;
}

/// 同步参数。
class SrsSyncOptions {
  const SrsSyncOptions({
    this.snapshotEveryBatches = 20,
    this.retireAfterMs = 90 * 24 * 60 * 60 * 1000,
  });

  final int snapshotEveryBatches;
  final int retireAfterMs;
}

/// 同步引擎。
class SrsSyncEngine {
  SrsSyncEngine({
    required this.directory,
    required this.replica,
    this.options = const SrsSyncOptions(),
  });

  final SrsSyncDirectory directory;
  final SrsSyncReplica replica;
  final SrsSyncOptions options;

  /// 跑一轮：校时 → 发布 → 拉取 → cursor → 快照 → 清理。
  Future<SrsSyncReport> syncOnce() async {
    final SrsSyncReport report = SrsSyncReport();
    final SrsSyncLocalState st = await replica.loadSyncState();

    // 本机写入者目录已被当作退役设备清理过：立即换新化身，未发布的改动进新化身的批次；
    // 绝不在已删除的目录名下续写旧批次号（修订版 5 / 008）。
    if (st.everPublished && await directory.listFiles(st.writerId) == null) {
      st
        ..writerId = replica.newIncarnationWriterId()
        ..nextBatchNo = 1
        ..frozenBatch = null
        ..lastSnapshotBatch = 0
        ..bootstrapped = false;
      if (st.frozenEventIds.isNotEmpty) {
        // 冻结过但上传状态不明的事件：重新进入发件箱（事件本身不可变，只是换信封）。
        await replica.requeue(st.frozenEventIds);
        st.frozenEventIds = const <String>[];
      }
      report.reincarnated = true;
      await replica.saveSyncState(st);
    }

    final int? s = await directory.serverTime(st.writerId);
    if (s == null) {
      report.error = 'server time unavailable';
      return report;
    }
    report.serverTimeMs = s;

    await _publish(st, s, report);
    if (!st.bootstrapped) {
      await _bootstrap(st, report);
    }
    await _pull(st, report);
    await directory.write(
      st.writerId,
      srsCursorName,
      SrsCursorFile(
        writerId: st.writerId,
        cursors: Map<String, int>.of(st.cursors),
        updatedAtMs: s,
      ).encode(),
    );
    await _maybeSnapshot(st, report);
    await _cleanup(st, s, report);
    await replica.saveSyncState(st);
    return report;
  }

  Future<void> _publish(
    SrsSyncLocalState st,
    int s,
    SrsSyncReport report,
  ) async {
    if (st.frozenBatch == null) {
      final List<SrsEvent> pending = await replica.unpublishedEvents();
      if (pending.isEmpty) return;
      final SrsBatch batch = SrsBatch(
        writerId: st.writerId,
        no: st.nextBatchNo,
        serverTimeMs: s,
        events: pending,
      );
      // 先在本机发件箱冻结（分配批次号、写入 S），然后才上传；冻结后内容不再改变。
      st
        ..frozenBatch = batch.encode()
        ..frozenEventIds = <String>[for (final SrsEvent e in pending) e.id];
      await replica.markPublished(st.frozenEventIds);
      await replica.saveSyncState(st);
    }
    final Uint8List bytes = st.frozenBatch!;
    final SrsBatch frozen = SrsBatch.decode(bytes)!;
    await directory.write(st.writerId, srsBatchName(frozen.no), bytes);
    final Uint8List? back = await directory.read(
      st.writerId,
      srsBatchName(frozen.no),
    );
    if (back == null || SrsBatch.decode(back) == null) {
      // 上传失败或响应丢失：下一轮用同号同字节重传。上一批确认之前不发下一批，不产生空号。
      return;
    }
    await replica.observeServerTimes(<String, int>{
      for (final SrsEvent e in frozen.events) e.id: frozen.serverTimeMs,
    });
    st
      ..cursors[st.writerId] = frozen.no
      ..lastBatchServerTime[st.writerId] = frozen.serverTimeMs
      ..nextBatchNo = frozen.no + 1
      ..frozenBatch = null
      ..frozenEventIds = const <String>[];
    report.published += frozen.events.length;
    await replica.saveSyncState(st);
  }

  /// 起步：读每一个现存写入者的最新快照，逐个合并（幂等、顺序无关），起步 cursor = 各快照 vv 的逐项最大值。
  /// 只读一份覆盖最广的快照会漏掉只存在于另一份快照里的、已删目录写入者的数据（审查 001）。
  Future<void> _bootstrap(SrsSyncLocalState st, SrsSyncReport report) async {
    for (final String w in await directory.listWriters()) {
      final SrsSnapshot? snap = await _latestSnapshot(w);
      if (snap == null) continue;
      await _applySnapshot(st, snap, report);
    }
    st.bootstrapped = true;
  }

  Future<SrsSnapshot?> _latestSnapshot(String writerId) async {
    final List<String>? files = await directory.listFiles(writerId);
    if (files == null) return null;
    final List<int> nos = <int>[
      for (final String f in files)
        if (srsParseSnapshotName(f) case final int n) n,
    ]..sort();
    for (final int n in nos.reversed) {
      final Uint8List? bytes = await directory.read(
        writerId,
        srsSnapshotName(n),
      );
      final SrsSnapshot? snap = bytes == null
          ? null
          : SrsSnapshot.decode(bytes);
      if (snap != null) return snap;
    }
    return null;
  }

  Future<void> _applySnapshot(
    SrsSyncLocalState st,
    SrsSnapshot snap,
    SrsSyncReport report,
  ) async {
    await replica.observeServerTimes(snap.serverTimes);
    await replica.applyRemote(snap.events);
    report.applied += snap.events.length;
    for (final MapEntry<String, int> e in snap.vv.entries) {
      if (e.key == st.writerId) continue;
      if ((st.cursors[e.key] ?? 0) < e.value) st.cursors[e.key] = e.value;
    }
  }

  Future<void> _pull(SrsSyncLocalState st, SrsSyncReport report) async {
    for (final String w in await directory.listWriters()) {
      if (w == st.writerId) continue;
      final List<String>? files = await directory.listFiles(w);
      if (files == null) continue;
      final List<int> batches = <int>[
        for (final String f in files)
          if (srsParseBatchName(f) case final int n) n,
      ]..sort();
      int cursor = st.cursors[w] ?? 0;
      // 中间的批次已被 W 的快照覆盖并清理：读 W 的最新快照，再读之后的增量。
      final int firstExisting = batches.isEmpty ? cursor + 1 : batches.first;
      if (cursor + 1 < firstExisting) {
        final SrsSnapshot? snap = await _latestSnapshot(w);
        if (snap != null) {
          await _applySnapshot(st, snap, report);
          if (snap.maxOwnBatch > cursor) cursor = snap.maxOwnBatch;
        }
      }
      final Set<int> present = batches.toSet();
      // 严格按批次号顺序应用；b+1 还不可见（列表延迟、上传未完成）就停在 b，不跳过、不提前确认。
      while (present.contains(cursor + 1)) {
        final Uint8List? bytes = await directory.read(
          w,
          srsBatchName(cursor + 1),
        );
        final SrsBatch? batch = bytes == null ? null : SrsBatch.decode(bytes);
        if (batch == null || batch.writerId != w || batch.no != cursor + 1) {
          break;
        }
        await replica.applyRemote(
          batch.events,
          serverTimeMs: batch.serverTimeMs,
        );
        report.applied += batch.events.length;
        st.lastBatchServerTime[w] = batch.serverTimeMs;
        cursor = batch.no;
      }
      st.cursors[w] = cursor;
    }
  }

  Future<void> _maybeSnapshot(
    SrsSyncLocalState st,
    SrsSyncReport report,
  ) async {
    final int own = st.nextBatchNo - 1;
    if (own <= 0 || own - st.lastSnapshotBatch < options.snapshotEveryBatches) {
      return;
    }
    await writeSnapshot(st);
    report.snapshotWritten = true;
  }

  /// 写一份完整状态快照（vv 只记无缺口前缀，且只增不减）。
  Future<void> writeSnapshot(SrsSyncLocalState st) async {
    final int own = st.nextBatchNo - 1;
    final SrsSnapshot? previous = await _latestSnapshot(st.writerId);
    final Map<String, int> vv = <String, int>{...?previous?.vv};
    for (final MapEntry<String, int> e in st.cursors.entries) {
      if ((vv[e.key] ?? 0) < e.value) vv[e.key] = e.value;
    }
    vv[st.writerId] = own;
    final SrsSnapshot snap = SrsSnapshot(
      writerId: st.writerId,
      maxOwnBatch: own,
      vv: vv,
      serverTimes: await replica.exportServerTimes(),
      events: await replica.exportAll(),
    );
    await directory.write(st.writerId, srsSnapshotName(own), snap.encode());
    st.lastSnapshotBatch = own;
  }

  Future<Map<String, SrsCursorFile>> _peerCursors(String self) async {
    final Map<String, SrsCursorFile> out = <String, SrsCursorFile>{};
    for (final String w in await directory.listWriters()) {
      if (w == self) continue;
      final Uint8List? bytes = await directory.read(w, srsCursorName);
      final SrsCursorFile? c = bytes == null
          ? null
          : SrsCursorFile.decode(bytes);
      if (c != null) out[w] = c;
    }
    return out;
  }

  Future<void> _cleanup(
    SrsSyncLocalState st,
    int now,
    SrsSyncReport report,
  ) async {
    final Map<String, SrsCursorFile> peers = await _peerCursors(st.writerId);
    bool active(SrsCursorFile c) => now - c.updatedAtMs < options.retireAfterMs;
    final Iterable<SrsCursorFile> activePeers = peers.values.where(active);

    // 1. 本写入者的旧批次：已被自己的快照覆盖，且所有活跃对端的 cursor[自己] 都已越过。
    final List<String>? own = await directory.listFiles(st.writerId);
    for (final String f in own ?? const <String>[]) {
      final int? n = srsParseBatchName(f);
      if (n == null || n > st.lastSnapshotBatch) continue;
      if (activePeers.every(
        (SrsCursorFile c) => (c.cursors[st.writerId] ?? 0) >= n,
      )) {
        await directory.delete(st.writerId, f);
        report.batchesDeleted++;
      }
    }
    // 旧快照只留最新一份。
    final List<int> snaps = <int>[
      for (final String f in own ?? const <String>[])
        if (srsParseSnapshotName(f) case final int n) n,
    ]..sort();
    for (final int n in snaps.take(snaps.isEmpty ? 0 : snaps.length - 1)) {
      await directory.delete(st.writerId, srsSnapshotName(n));
    }

    // 2. 退役写入者的整个目录：cursor 文件 90 天没更新（或已被替代的旧化身），且
    //    ① 所有活跃对端的 cursor[W] 都已到达 W 的最后一批；② 至少一个活跃写入者的最新快照 vv[W] 到达 W 的最后一批。
    //    条件 ② 可传递：数据永远至少存在于一份活跃快照中。不满足的目录永不删除。
    for (final MapEntry<String, SrsCursorFile> e in peers.entries) {
      if (active(e.value)) continue;
      final String w = e.key;
      final int last = await _lastBatchOf(w);
      if (last == 0) continue;
      final bool allRead =
          (st.cursors[w] ?? 0) >= last &&
          activePeers.every(
            (SrsCursorFile c) => c.writerId == w || (c.cursors[w] ?? 0) >= last,
          );
      if (!allRead) continue;
      bool covered = false;
      for (final String holder in <String>[
        st.writerId,
        for (final SrsCursorFile c in activePeers) c.writerId,
      ]) {
        final SrsSnapshot? snap = await _latestSnapshot(holder);
        if (snap != null && (snap.vv[w] ?? 0) >= last) {
          covered = true;
          break;
        }
      }
      if (!covered) continue;
      await directory.deleteWriter(w);
      report.writersDeleted.add(w);
    }
  }

  Future<int> _lastBatchOf(String writerId) async {
    final List<String>? files = await directory.listFiles(writerId);
    int last = 0;
    for (final String f in files ?? const <String>[]) {
      final int? n = srsParseBatchName(f) ?? srsParseSnapshotName(f);
      if (n != null && n > last) last = n;
    }
    return last;
  }
}
