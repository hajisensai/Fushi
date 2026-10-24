/// 单写者事件日志同步（第三期「传输」）。纯逻辑，不依赖具体后端：
/// 生产经 SyncAssetStore 适配，模拟器用内存目录。
///
/// 硬规则：同步目录里每个文件只由一个写入者写（批次、快照、cursor、探针都在写入者自己的目录下），
/// 其它设备只读；退役写入者的整个目录在满足条件后才可删。
///
/// 多目录：一台设备可以同时用几个同步目录（云盘、所连的互联 host、本机作为 host 时自己的目录）。
/// 目录只是传输介质，不是数据的归属：写入者身份、批次号、对每个写入者的读取进度全局只有一份
/// （同一个批次冻结后逐字节不变，在哪个目录里读到都一样），只有「这个目录里传到了哪、起步过没有、
/// 快照写到哪、里面有哪些写入者」按目录记（[SrsDirectoryState]）。每个目录各跑各的 [SrsSyncEngine.syncOnce]，
/// 已冻结的批次在本机留存到所有在用目录都确认收到为止，所以先跑的目录不会把批次「用掉」。
library;

import 'dart:convert';
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

/// 本机对**一个**同步目录的进度（不同步）。键是调用方给的稳定目录身份（[SrsSyncEngine.directoryKey]）。
class SrsDirectoryState {
  SrsDirectoryState({
    this.confirmedThrough = 0,
    this.ownSeen = false,
    this.bootstrapped = false,
    this.lastSnapshotBatch = 0,
    this.snapshotAttemptBatch = 0,
    this.snapshotAttemptAt = 0,
    this.lastSyncAt,
    Map<String, int>? writers,
    Set<String>? alive,
    Map<String, int>? relayed,
  }) : writers = writers ?? <String, int>{},
       alive = alive ?? <String>{},
       relayed = relayed ?? <String, int>{};

  factory SrsDirectoryState.fromJson(Map<String, Object?> j) {
    Map<String, int> ints(Object? v) => <String, int>{
      for (final MapEntry<String, Object?> e
          in ((v as Map?) ?? const <String, Object?>{})
              .cast<String, Object?>()
              .entries)
        e.key: e.value! as int,
    };
    return SrsDirectoryState(
      confirmedThrough: (j['confirmed'] as int?) ?? 0,
      ownSeen: j['ownSeen'] == true,
      bootstrapped: j['boot'] == true,
      lastSnapshotBatch: (j['snap'] as int?) ?? 0,
      snapshotAttemptBatch: (j['snapTry'] as int?) ?? 0,
      snapshotAttemptAt: (j['snapTryAt'] as int?) ?? 0,
      lastSyncAt: j['at'] as int?,
      writers: ints(j['writers']),
      alive: <String>{
        ...((j['alive'] as List?) ?? const <Object?>[]).cast<String>(),
      },
      relayed: ints(j['relayed']),
    );
  }

  /// 本写入者在这个目录里已确认存在的批次前缀（批次或覆盖了它的快照）。
  int confirmedThrough;

  /// 这个目录里出现过本写入者的目录。之后又不见了 = 被当作退役设备清理过（要换新化身）；
  /// 从没出现过 = 只是还没往这里传过（补齐即可，不换化身）。
  bool ownSeen;

  /// 是否已按「读这个目录里全部现存写入者的最新快照」起步过。
  bool bootstrapped;
  int lastSnapshotBatch;

  /// 最近一次开始写快照时的本写入者批次号与服务器时间。没写成（读回校验不过、中途抛错、进程被杀）
  /// 时据此退避：整份快照是 O(全部历史) 的活，不能每轮同步都重做一遍（反馈 OMWOurRQKb）。
  int snapshotAttemptBatch;
  int snapshotAttemptAt;

  /// 最近一次在这个目录同步成功时的服务器时间；null = 还没成功过。
  int? lastSyncAt;

  /// 这个目录里见过的写入者 → 列出过的最大批次 / 快照号（只增不减；写入者目录被删后条目保留）。
  final Map<String, int> writers;

  /// 这个目录里「还活着」的写入者：自己会把之后的批次传进来（cursor 文件在留存期内更新过，
  /// 且没被同一台设备更高的化身取代）。不活着的写入者在这里的数据只到 [writers] 记的那批为止，
  /// 本机从别处读到它更后面的数据时要转发进来。
  final Set<String> alive;

  /// 本机已替不活着的写入者把数据带进这个目录到哪一批（转发、全量重新发布、起步时读到的快照覆盖）。
  final Map<String, int> relayed;

  /// 这个目录里写入者 [w] 的数据已经（或将会）有到哪一批。
  int coveredOf(String w) {
    final int seen = writers[w] ?? 0;
    final int r = relayed[w] ?? 0;
    return seen > r ? seen : r;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'confirmed': confirmedThrough,
    'ownSeen': ownSeen,
    'boot': bootstrapped,
    'snap': lastSnapshotBatch,
    if (snapshotAttemptBatch != 0) 'snapTry': snapshotAttemptBatch,
    if (snapshotAttemptAt != 0) 'snapTryAt': snapshotAttemptAt,
    if (lastSyncAt != null) 'at': lastSyncAt,
    'writers': writers,
    'alive': (alive.toList()..sort()),
    'relayed': relayed,
  };
}

/// 本机持久化的同步状态（不同步）。
class SrsSyncLocalState {
  SrsSyncLocalState({
    required this.writerId,
    this.nextBatchNo = 1,
    Map<String, int>? cursors,
    Map<String, int>? lastBatchServerTime,
    Map<String, SrsDirectoryState>? directories,
    this.legacyDirectories = false,
  }) : cursors = cursors ?? <String, int>{},
       lastBatchServerTime = lastBatchServerTime ?? <String, int>{},
       directories = directories ?? <String, SrsDirectoryState>{};

  String writerId;

  /// 下一个要冻结的批次号（从 1 起连续；冻结即分配，已冻结的批次在本机留存到各目录确认）。
  int nextBatchNo;

  /// 对每个写入者的读取进度：只表示无缺口前缀。全局一份——写入者的第 n 批在哪个目录里都逐字节相同。
  final Map<String, int> cursors;

  /// 每个写入者最近一个批次的 S（timeUncertain 判定用）。
  final Map<String, int> lastBatchServerTime;

  /// 按目录的进度（见 [SrsDirectoryState]）。
  final Map<String, SrsDirectoryState> directories;

  /// 本机状态来自还不分目录记账的旧版本：那时没记「哪个目录出现过本写入者」，
  /// 某个目录里找不到本写入者时分不清「从没传过去」还是「被当作退役清理了」，只能按后者换新化身。
  /// 换过化身（新写入者没有旧账）后清除。
  bool legacyDirectories;

  /// 是否发布过批次。第六轮审查第 15 条：发布过的 profile 不能再改 uid（旧目录会成孤儿）。
  bool get everPublished => nextBatchNo > 1;
}

/// 本机副本：事件的读写与同步状态的持久化（内存实现见 memory_replica.dart，数据库实现在 fushi_engine）。
abstract interface class SrsSyncReplica {
  Future<SrsSyncLocalState> loadSyncState();
  Future<void> saveSyncState(SrsSyncLocalState state);

  /// 本机发件箱里、还没进任何批次的事件，按入箱顺序；给了 [limit] 时只取最前面的至多这么多条
  /// （冻结按批次逐页取，不把整个发件箱一次读进内存）。
  Future<List<SrsEvent>> unpublishedEvents({int? limit});

  /// 冻结一个批次（一次原子操作）：[bytes] 作为写入者 [SrsSyncLocalState.writerId] 的第 [no] 批留存在本机、
  /// [eventIds] 出发件箱、[state]（nextBatchNo 已越过 [no]）落盘。冻结后内容不再改变，
  /// 每个目录都从留存里取同样的字节上传。
  Future<void> freezeBatch(
    SrsSyncLocalState state,
    int no,
    Uint8List bytes,
    List<String> eventIds,
  );

  /// 留存的第 [no] 批；已不再留存返回 null（落后太久的目录改用快照补齐）。
  Future<Uint8List?> sentBatch(String writerId, int no);

  /// 留存批次的批次号（升序）。
  Future<List<int>> sentBatchNos(String writerId);

  /// 不再留存写入者 [writerId] 的 ≤ [throughNo] 的批次（null = 全部）。
  Future<void> dropSentBatches(String writerId, {int? throughNo});

  /// 这些事件重新进入发件箱（换化身、目录起步时缺数据要重新发布；事件不可变，重复发布无害）。
  Future<void> requeue(List<String> eventIds);

  /// 应用对端事件（幂等）。[serverTimeMs] 为批次 S；快照应用时为 null（另经 [observeServerTimes]）。
  /// [forward] 为真时，其中**本机原先没有、这次新落地**的事件，以及**S 因此变小**（含从未知变已知）
  /// 的事件，同时进入发件箱：本机还用着别的目录、而那个目录里这些事件的写入者不活着，
  /// 只有本机能把它们（连同更小的 S，见 [SrsBatch.knownServerTimes]）带过去（见 [SrsSyncEngine] 的转发规则）。
  /// S 只会变小、事件只会落地一次，所以转发必然终止。
  Future<void> applyRemote(
    List<SrsEvent> events, {
    int? serverTimeMs,
    bool forward = false,
  });

  /// 记录 S 观察（取最小值）。[forward] 同 [applyRemote]：已在本机、S 因此变小的事件进发件箱。
  Future<void> observeServerTimes(
    Map<String, int> times, {
    bool forward = false,
  });

  /// [eventIds] 里已知 S 的事件 → S（冻结批次时带上，见 [SrsBatch.knownServerTimes]）。
  Future<Map<String, int>> knownServerTimes(List<String> eventIds);

  /// 完整合并状态（整份进内存；同步引擎不用它，写快照走 [exportSnapshotPages]）。
  Future<List<SrsEvent>> exportAll();
  Future<Map<String, int>> exportServerTimes();

  /// 全部事件的 ID（与 [exportAll] 同序；全量重新发布只要 ID，不必把正文读出来解析）。
  Future<List<String>> exportAllIds();

  /// 完整合并状态按页交出（写快照用）：先逐页交出全部事件的规范 JSON 行（与 `SrsEvent.canonical()`
  /// 逐字节相同），再逐页交出已知的「事件 ID → S」。整个导出是同一个一致读（中间插不进别的写入），
  /// 内存只占一页、页与页之间让出事件循环——几万条事件、几十 MB 正文不能一次物化在调用方 isolate 上。
  Future<void> exportSnapshotPages({
    required Future<void> Function(List<String> canonicalLines) onEvents,
    required Future<void> Function(List<(String, int)> serverTimes)
    onServerTimes,
  });

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

  /// 这个目录起步时发现本机持有它缺的写入者的数据，把全部事件重新放进了发件箱。
  bool republished = false;

  /// 本轮跳过的坏文件（自校验通过、内容却解不出来；`<写入者>/<文件名>: 原因`）。
  /// 文件不删（不是本写入者的文件，也可能是更新版本写的），调用方记日志。
  /// 坏批次之后的数据只能等它的写入者写出覆盖它的快照再接上，其它写入者照常同步。
  final List<String> skippedFiles = <String>[];
  String? error;

  /// 本轮取到的服务器时间（探针文件的服务端修改时间）。调用方据此给可信时间校时（铁律 F 第一层）。
  int? serverTimeMs;
}

/// 同步参数。
class SrsSyncOptions {
  const SrsSyncOptions({
    this.snapshotEveryBatches = 20,
    this.retireAfterMs = 90 * 24 * 60 * 60 * 1000,
    this.retainSentForMs = 30 * 24 * 60 * 60 * 1000,
    this.maxSentBatches = 5000,
    this.maxEventsPerBatch = 5000,
    this.snapshotRetryAfterMs = 24 * 60 * 60 * 1000,
  });

  final int snapshotEveryBatches;
  final int retireAfterMs;

  /// 已冻结批次留存到「最近 [retainSentForMs] 内同步过的所有目录」都确认收到为止；
  /// 更久没来的目录不再拖住留存，它回来时用快照补齐。
  final int retainSentForMs;

  /// 留存批次数上限：超出时丢最旧的，落后的目录同样用快照补齐。
  final int maxSentBatches;

  /// 一个批次最多装多少条事件；发件箱更多时按序切成几批。全量重新发布（新目录起步、换化身、
  /// 恢复备份）与大包导入一次进箱几万条：切开后单个文件有界，上传 / 读取中断时已确认的那几批不必重来，
  /// 读方也逐批应用、不必一次解码整库。
  final int maxEventsPerBatch;

  /// 快照没写成时，等本写入者又攒够 [snapshotEveryBatches] 个批次、或过了这么久（服务器时间）再试。
  final int snapshotRetryAfterMs;
}

/// 同步引擎：对**一个**目录跑一轮。
///
/// 转发规则（多目录）：从目录 D 读到写入者 W 的事件时，如果本机另一个已起步的目录 D' 里 W 不活着
/// （从没出现过、超过留存期没来、或已被它的新化身取代——它不会自己把这些批次传进 D'），
/// 新落地的事件进本机发件箱，随本机批次带到所有目录（含 D'）。单目录时没有 D'，与「回声规则」一致：
/// 不转发。转发只看事件是不是新落地，每条事件在每台设备上只落地一次，转发必然终止。
/// 转发之前就已落地、D' 却缺的数据（目录刚起步、写入者刚停止来 D'），由「全量重新发布一次」补上：
/// 每轮核对本机读到的每个写入者的进度与 D' 已有的（列出过的、快照覆盖的、本机转发过的），缺就重发。
class SrsSyncEngine {
  SrsSyncEngine({
    required this.directory,
    required this.directoryKey,
    required this.replica,
    this.options = const SrsSyncOptions(),
  });

  final SrsSyncDirectory directory;

  /// 目录的稳定身份（同一个物理目录每次给同一个值，不同目录给不同值），按目录的进度以它为键。
  final String directoryKey;
  final SrsSyncReplica replica;
  final SrsSyncOptions options;

  /// 跑一轮：（换化身）→ 校时 → 冻结 → 上传 → 起步 → 拉取 → cursor → 快照 → 清理 → 修剪留存。
  Future<SrsSyncReport> syncOnce() async {
    final SrsSyncReport report = SrsSyncReport();
    final SrsSyncLocalState st = await replica.loadSyncState();
    st.directories.putIfAbsent(directoryKey, SrsDirectoryState.new);

    List<String>? ownFiles = await directory.listFiles(st.writerId);
    if (ownFiles == null &&
        st.everPublished &&
        (st.directories[directoryKey]!.ownSeen || st.legacyDirectories)) {
      // 本机写入者目录已被当作退役设备清理过：立即换新化身，绝不在已删除的目录名下续写旧批次号
      // （修订版 5 / 008）。
      await _reincarnate(st);
      report.reincarnated = true;
      ownFiles = null;
    }
    final SrsDirectoryState ds = st.directories[directoryKey]!;

    final int? s = await directory.serverTime(st.writerId);
    if (s == null) {
      report.error = 'server time unavailable';
      return report;
    }
    report.serverTimeMs = s;
    // 探针已写进本写入者目录：从此这个目录「出现过」本写入者。
    ds.ownSeen = true;
    final int? lastAt = ds.lastSyncAt;
    if (lastAt != null && s - lastAt >= options.retireAfterMs) {
      // 本机在这个目录里已被当作退役（超过退役时限没来）：按「起步」流程重新读全部快照。
      ds.bootstrapped = false;
    }
    ds.confirmedThrough = await _confirmedThrough(st, ds, ownFiles);

    await _freeze(st, s);
    await _upload(st, ds, s, report);
    final Map<String, SrsCursorFile> peers = await _peerCursors(
      st.writerId,
      report.skippedFiles,
    );
    if (!ds.bootstrapped) await _bootstrap(st, ds, report);
    await _pull(st, ds, peers, s, report);
    final List<String> missing = _dataMissingHere(st, ds);
    if (missing.isNotEmpty) {
      // 本机持有这个目录缺的数据（写入者在这里不活着、也没人替它带进来过）：全部事件重新发布一次。
      await replica.requeue(await replica.exportAllIds());
      // 重新发布进的是本机批次流，会到达每一个目录：每个目录都按本机此刻的读取进度记账，
      // 别的目录不必再各自重发一次。
      for (final SrsDirectoryState d in st.directories.values) {
        for (final MapEntry<String, int> c in st.cursors.entries) {
          if (c.key == st.writerId) continue;
          if ((d.relayed[c.key] ?? 0) < c.value) d.relayed[c.key] = c.value;
        }
      }
      report.republished = true;
      await _freeze(st, s);
      await _upload(st, ds, s, report);
    }
    await directory.write(
      st.writerId,
      srsCursorName,
      SrsCursorFile(
        writerId: st.writerId,
        cursors: Map<String, int>.of(st.cursors),
        updatedAtMs: s,
      ).encode(),
    );
    await _maybeSnapshot(st, ds, s, report);
    ds.lastSyncAt = s;
    await _cleanup(st, ds, peers, s, report);
    await _pruneSent(st, s);
    await replica.saveSyncState(st);
    return report;
  }

  /// 换新化身：本机全部事件由新化身重新发布，旧化身停止增长。
  ///
  /// 不能只重发旧化身还留存的批次：本机转发过的别人的数据、旧化身没传到某些目录就被修剪掉的批次，
  /// 都只靠旧化身的批次流送达。新的批次流包含本机全部数据，才能重新成立「本机持有的每条事件，
  /// 要么在本机当前的批次流里，要么由在那个目录里活着的写入者送达」——转发记账（[SrsDirectoryState.relayed]）
  /// 全靠这条成立。换化身只在被当作退役清理时发生，多传一次全量可以接受。
  Future<void> _reincarnate(SrsSyncLocalState st) async {
    final String old = st.writerId;
    final int oldLast = st.nextBatchNo - 1;
    st
      ..writerId = replica.newIncarnationWriterId()
      ..nextBatchNo = 1
      ..legacyDirectories = false;
    // 本机持有旧化身的全部事件：读取进度记到它的最后一批，本机快照的 vv 因此覆盖它，
    // 别处的旧化身目录才能按退役规则清理。
    if (oldLast > 0) st.cursors[old] = oldLast;
    for (final MapEntry<String, SrsDirectoryState> e
        in st.directories.entries) {
      // 新化身的批次流带着本机此刻的全部数据，会到达每个目录（留存或快照补齐）。
      e.value.relayed
        ..clear()
        ..addAll(<String, int>{
          for (final MapEntry<String, int> c in st.cursors.entries)
            if (c.key != st.writerId) c.key: c.value,
        });
      e.value
        ..confirmedThrough = 0
        ..ownSeen = false
        ..lastSnapshotBatch = 0
        ..snapshotAttemptBatch = 0
        ..snapshotAttemptAt = 0;
      // 触发换化身的目录按「起步」流程重来（它把旧化身删了，退役后回归要重新读全部快照）。
      if (e.key == directoryKey) e.value.bootstrapped = false;
    }
    await replica.requeue(await replica.exportAllIds());
    await replica.dropSentBatches(old);
    await replica.saveSyncState(st);
  }

  /// 本写入者在这个目录里已确认存在的前缀：以目录里实际列出的批次 / 快照为准；
  /// 列出的比记账少（列表延迟）且本机已不再留存下一批时，沿用记账，不为列表延迟写补齐快照。
  Future<int> _confirmedThrough(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
    List<String>? ownFiles,
  ) async {
    int listed = 0;
    for (final String f in ownFiles ?? const <String>[]) {
      final int? n = srsParseBatchName(f) ?? srsParseSnapshotName(f);
      if (n != null && n > listed) listed = n;
    }
    if (listed >= ds.confirmedThrough) return listed;
    if (await replica.sentBatch(st.writerId, listed + 1) != null) return listed;
    return ds.confirmedThrough;
  }

  /// 发件箱里的事件按序冻结成新批次（每批至多 [SrsSyncOptions.maxEventsPerBatch] 条，发布时的服务器时间 S
  /// 写进信封）。冻结后内容不再改变。逐批从发件箱头部取（冻结即出箱），不把整个发件箱一次读进内存：
  /// 大包导入 / 全量重新发布后发件箱是几万条事件。
  Future<void> _freeze(SrsSyncLocalState st, int s) async {
    final int step = options.maxEventsPerBatch < 1
        ? 1
        : options.maxEventsPerBatch;
    while (true) {
      final List<SrsEvent> pending = await replica.unpublishedEvents(
        limit: step,
      );
      if (pending.isEmpty) return;
      await _freezeOne(st, s, pending);
      if (pending.length < step) return;
    }
  }

  Future<void> _freezeOne(
    SrsSyncLocalState st,
    int s,
    List<SrsEvent> pending,
  ) async {
    final int no = st.nextBatchNo;
    final List<String> ids = <String>[for (final SrsEvent e in pending) e.id];
    final Map<String, int> known = await replica.knownServerTimes(ids);
    final Uint8List bytes = await srsEncodeBatch(
      SrsBatch(
        writerId: st.writerId,
        no: no,
        serverTimeMs: s,
        events: pending,
        knownServerTimes: known,
      ),
    );
    st.nextBatchNo = no + 1;
    await replica.freezeBatch(st, no, bytes, ids);
    // 冻结即定下首次发布事件的 S（批次字节不再变，每个目录收到的都是这个 S）。
    // 不等某个目录确认：落后的目录可能直接用快照补齐，快照里的 S 映射必须已经有它们。
    await replica.observeServerTimes(<String, int>{
      for (final String id in ids)
        if (!known.containsKey(id)) id: s,
    });
  }

  /// 应用一个对端批次：首次发布的事件取信封 S，早已发布过的取批次里带的原 S。
  Future<void> _applyBatch(SrsBatch batch, {required bool forward}) async {
    if (batch.knownServerTimes.isNotEmpty) {
      await replica.observeServerTimes(
        batch.knownServerTimes,
        forward: forward,
      );
    }
    final List<SrsEvent> fresh = <SrsEvent>[];
    final List<SrsEvent> known = <SrsEvent>[];
    for (final SrsEvent e in batch.events) {
      (batch.knownServerTimes.containsKey(e.id) ? known : fresh).add(e);
    }
    if (fresh.isNotEmpty) {
      await replica.applyRemote(
        fresh,
        serverTimeMs: batch.serverTimeMs,
        forward: forward,
      );
    }
    if (known.isNotEmpty) {
      await replica.applyRemote(known, forward: forward);
    }
  }

  /// 把这个目录还没确认的本写入者批次按序传上去。上一批确认之前不传下一批（目录里不产生空号）；
  /// 本机已不再留存的那段用一份快照补齐。
  Future<void> _upload(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
    int s,
    SrsSyncReport report,
  ) async {
    final int own = st.nextBatchNo - 1;
    while (ds.confirmedThrough < own) {
      final int no = ds.confirmedThrough + 1;
      final Uint8List? bytes = await replica.sentBatch(st.writerId, no);
      if (bytes == null) {
        // 这个目录落后得比本机留存还久：快照覆盖本写入者到 own 为止的全部批次。
        if (!_snapshotRetryDue(ds, own, s)) return;
        if (await _attemptSnapshot(st, ds, s)) {
          ds.confirmedThrough = own;
          report.snapshotWritten = true;
        }
        return;
      }
      await directory.write(st.writerId, srsBatchName(no), bytes);
      final Uint8List? back = await directory.read(
        st.writerId,
        srsBatchName(no),
      );
      final SrsBatch? frozen = back == null
          ? null
          : (await srsDecodeBatch(back)).valueOrNull;
      if (frozen == null) {
        // 上传失败或响应丢失：下一轮用同号同字节重传。
        return;
      }
      await replica.observeServerTimes(<String, int>{
        for (final SrsEvent e in frozen.events) e.id: frozen.serverTimeOf(e.id),
      });
      if ((st.cursors[st.writerId] ?? 0) < no) {
        st
          ..cursors[st.writerId] = no
          ..lastBatchServerTime[st.writerId] = frozen.serverTimeMs;
      }
      ds.confirmedThrough = no;
      report.published += frozen.events.length;
      await replica.saveSyncState(st);
    }
  }

  /// 转发目标：本机另一个已起步、而写入者 [w] 在那里不活着的目录（它之后的数据要由本机带过去）。
  List<SrsDirectoryState> _forwardTargets(SrsSyncLocalState st, String w) {
    if (w == st.writerId) return const <SrsDirectoryState>[];
    return <SrsDirectoryState>[
      for (final MapEntry<String, SrsDirectoryState> e
          in st.directories.entries)
        if (e.key != directoryKey &&
            e.value.bootstrapped &&
            !e.value.alive.contains(w))
          e.value,
    ];
  }

  /// 本机数据里，这个目录缺、又不会有别人补上的那些写入者：写入者在这里不活着
  /// （从没在这里出现过、不再来这个目录、或已被它的新化身取代），而本机读到的比这个目录
  /// 已有的（[SrsDirectoryState.coveredOf]：列出过的批次、起步读到的快照覆盖、本机转发过的）更多。
  /// 被正常退役删除的写入者不算：退役条件 ② 保证它的数据已在某份活跃快照的 vv 里（起步时计入）。
  List<String> _dataMissingHere(SrsSyncLocalState st, SrsDirectoryState ds) =>
      <String>[
        for (final MapEntry<String, int> e in st.cursors.entries)
          if (e.key != st.writerId &&
              !ds.alive.contains(e.key) &&
              e.value > ds.coveredOf(e.key))
            e.key,
      ];

  /// 写入者 [w] 已被同一台设备更高的化身取代（writerId = deviceId#化身号）：它不会再增长。
  bool _superseded(SrsSyncLocalState st, String w) {
    final (String, int)? me = _incarnationOf(w);
    if (me == null) return false;
    bool newer(String other) {
      final (String, int)? o = _incarnationOf(other);
      return o != null && o.$1 == me.$1 && o.$2 > me.$2;
    }

    if (newer(st.writerId)) return true;
    for (final SrsDirectoryState d in st.directories.values) {
      if (d.writers.keys.any(newer)) return true;
    }
    return false;
  }

  static (String, int)? _incarnationOf(String writerId) {
    final int i = writerId.lastIndexOf('#');
    if (i <= 0) return null;
    final int? n = int.tryParse(writerId.substring(i + 1));
    return n == null ? null : (writerId.substring(0, i), n);
  }

  static int _maxNo(List<String> files) {
    int max = 0;
    for (final String f in files) {
      final int? n = srsParseBatchName(f) ?? srsParseSnapshotName(f);
      if (n != null && n > max) max = n;
    }
    return max;
  }

  /// 起步：读每一个现存写入者的最新快照，逐个合并（幂等、顺序无关），起步 cursor = 各快照 vv 的逐项最大值。
  /// 只读一份覆盖最广的快照会漏掉只存在于另一份快照里的、已删目录写入者的数据（审查 001）。
  /// 这些快照的 vv 也记进这个目录的覆盖范围（[SrsDirectoryState.relayed]）：之后起步的设备同样读得到它们。
  Future<void> _bootstrap(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
    SrsSyncReport report,
  ) async {
    for (final String w in await directory.listWriters()) {
      final SrsSnapshot? snap = await _latestSnapshot(
        w,
        skipped: report.skippedFiles,
      );
      if (snap == null) continue;
      await _applySnapshot(st, snap, report);
      for (final MapEntry<String, int> e in snap.vv.entries) {
        if ((ds.relayed[e.key] ?? 0) < e.value) ds.relayed[e.key] = e.value;
      }
    }
    ds.bootstrapped = true;
  }

  /// 写入者 [writerId] 最新一份完好的快照（按 [decode] 解出）。
  /// [skipped] 非空时，跳过的坏快照记进去（较旧的完好快照照常可用）。
  Future<T?> _latestSnapshotOf<T>(
    String writerId,
    Future<SrsFileDecode<T>> Function(Uint8List bytes) decode, {
    List<String>? files,
    List<String>? skipped,
  }) async {
    final List<String>? names = files ?? await directory.listFiles(writerId);
    if (names == null) return null;
    final List<int> nos = <int>[
      for (final String f in names)
        if (srsParseSnapshotName(f) case final int n) n,
    ]..sort();
    for (final int n in nos.reversed) {
      final Uint8List? bytes = await directory.read(
        writerId,
        srsSnapshotName(n),
      );
      if (bytes == null) continue;
      switch (await decode(bytes)) {
        case SrsFileOk<T>(:final T value):
          return value;
        case SrsFileMalformed<T>(:final String reason):
          skipped?.add('$writerId/${srsSnapshotName(n)}: $reason');
        case SrsFileIncomplete<T>():
          break;
      }
    }
    return null;
  }

  /// [_latestSnapshotOf] 的完整内容（要应用其中的事件时）。
  Future<SrsSnapshot?> _latestSnapshot(
    String writerId, {
    List<String>? files,
    List<String>? skipped,
  }) => _latestSnapshotOf(
    writerId,
    srsDecodeSnapshot,
    files: files,
    skipped: skipped,
  );

  /// 只要最新快照的 vv 时：照样整份校验，但事件正文留在后台 isolate，不搬回来。
  Future<SrsSnapshotHeader?> _latestSnapshotHeader(String writerId) =>
      _latestSnapshotOf(writerId, srsDecodeSnapshotHeader);

  /// 应用一份快照（快照的写入者 [SrsSnapshot.writerId] 决定转发目标）。转发了的，记进目标目录的覆盖范围。
  Future<void> _applySnapshot(
    SrsSyncLocalState st,
    SrsSnapshot snap,
    SrsSyncReport report,
  ) async {
    final List<SrsDirectoryState> targets = _forwardTargets(st, snap.writerId);
    await replica.observeServerTimes(
      snap.serverTimes,
      forward: targets.isNotEmpty,
    );
    await replica.applyRemote(snap.events, forward: targets.isNotEmpty);
    report.applied += snap.events.length;
    for (final MapEntry<String, int> e in snap.vv.entries) {
      if (e.key == st.writerId) continue;
      if ((st.cursors[e.key] ?? 0) < e.value) st.cursors[e.key] = e.value;
      for (final SrsDirectoryState t in targets) {
        if (!t.alive.contains(e.key) && (t.relayed[e.key] ?? 0) < e.value) {
          t.relayed[e.key] = e.value;
        }
      }
    }
  }

  /// 拉取，同时清点这个目录里的写入者（[SrsDirectoryState.writers] / [SrsDirectoryState.alive]）。
  Future<void> _pull(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
    Map<String, SrsCursorFile> peers,
    int now,
    SrsSyncReport report,
  ) async {
    final List<String> writers = await directory.listWriters();
    final Map<String, List<String>> listed = <String, List<String>>{};
    for (final String w in writers) {
      if (w == st.writerId) continue;
      final List<String>? files = await directory.listFiles(w);
      if (files == null) continue;
      listed[w] = files;
      final int max = _maxNo(files);
      if ((ds.writers[w] ?? 0) < max || !ds.writers.containsKey(w)) {
        ds.writers[w] = max;
      }
    }
    ds.alive
      ..clear()
      ..addAll(<String>[
        for (final String w in listed.keys)
          if (!_superseded(st, w) &&
              (peers[w] == null ||
                  now - peers[w]!.updatedAtMs < options.retainSentForMs))
            w,
      ]);
    for (final MapEntry<String, List<String>> entry in listed.entries) {
      final String w = entry.key;
      final List<String> files = entry.value;
      final List<SrsDirectoryState> targets = _forwardTargets(st, w);
      final bool forward = targets.isNotEmpty;
      final Set<int> present = <int>{
        for (final String f in files)
          if (srsParseBatchName(f) case final int n) n,
      };
      int latestSnapshot = 0;
      for (final String f in files) {
        final int? n = srsParseSnapshotName(f);
        if (n != null && n > latestSnapshot) latestSnapshot = n;
      }
      int cursor = st.cursors[w] ?? 0;
      bool snapshotTried = false;
      while (true) {
        // 严格按批次号顺序应用；b+1 还不可见（列表延迟、上传未完成）就停在 b，不跳过、不提前确认。
        // b+1 在、但内容坏了（[SrsFileMalformed]）：同样不跳过（跳过 = 丢数据还谎报 cursor），
        // 记进报告，改走下面的快照；没有覆盖它的快照就停在 b，等写入者写出新快照。
        bool nextMalformed = false;
        while (present.contains(cursor + 1)) {
          final String name = srsBatchName(cursor + 1);
          final Uint8List? bytes = await directory.read(w, name);
          if (bytes == null) break;
          SrsBatch? batch;
          switch (await srsDecodeBatch(bytes)) {
            case SrsFileOk<SrsBatch>(:final SrsBatch value)
                when value.writerId == w && value.no == cursor + 1:
              batch = value;
            case SrsFileOk<SrsBatch>(:final SrsBatch value):
              report.skippedFiles.add(
                '$w/$name: header says ${value.writerId}/${value.no}',
              );
              nextMalformed = true;
            case SrsFileMalformed<SrsBatch>(:final String reason):
              report.skippedFiles.add('$w/$name: $reason');
              nextMalformed = true;
            case SrsFileIncomplete<SrsBatch>():
              // 写到一半：停在这里，下一轮再读。
              batch = null;
          }
          if (batch == null) break;
          await _applyBatch(batch, forward: forward);
          report.applied += batch.events.length;
          st.lastBatchServerTime[w] = batch.serverTimeMs;
          cursor = batch.no;
        }
        // 下一批不在（或坏了）、但 W 有覆盖到更后面的快照：中间的批次已被快照覆盖并清理，或 W 在这个
        // 目录里是用快照补齐的。读 W 的最新快照，再接着读之后的增量。
        if (snapshotTried ||
            (present.contains(cursor + 1) && !nextMalformed) ||
            latestSnapshot <= cursor) {
          break;
        }
        snapshotTried = true;
        final SrsSnapshot? snap = await _latestSnapshot(
          w,
          files: files,
          skipped: report.skippedFiles,
        );
        if (snap == null || snap.maxOwnBatch <= cursor) break;
        await _applySnapshot(st, snap, report);
        cursor = snap.maxOwnBatch;
      }
      st.cursors[w] = cursor;
      for (final SrsDirectoryState t in targets) {
        if ((t.relayed[w] ?? 0) < cursor) t.relayed[w] = cursor;
      }
    }
  }

  Future<void> _maybeSnapshot(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
    int s,
    SrsSyncReport report,
  ) async {
    final int own = st.nextBatchNo - 1;
    if (own <= 0 ||
        ds.confirmedThrough < own ||
        own - ds.lastSnapshotBatch < options.snapshotEveryBatches ||
        !_snapshotRetryDue(ds, own, s)) {
      return;
    }
    if (await _attemptSnapshot(st, ds, s)) report.snapshotWritten = true;
  }

  /// 上一次快照没写成时，本写入者又攒够 [SrsSyncOptions.snapshotEveryBatches] 个批次、或过了
  /// [SrsSyncOptions.snapshotRetryAfterMs] 才再试；没有失败记录时总是可以写。
  bool _snapshotRetryDue(SrsDirectoryState ds, int own, int s) =>
      ds.snapshotAttemptBatch <= ds.lastSnapshotBatch ||
      own - ds.snapshotAttemptBatch >= options.snapshotEveryBatches ||
      s - ds.snapshotAttemptAt >= options.snapshotRetryAfterMs;

  /// 先把「这次尝试」落盘再写快照：写不成、中途抛错（连接被关、后端出错）或进程被杀，
  /// 下一轮都按退避规则等，而不是每轮从头再导出、编码、上传一份整库快照。
  Future<bool> _attemptSnapshot(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
    int s,
  ) async {
    ds
      ..snapshotAttemptBatch = st.nextBatchNo - 1
      ..snapshotAttemptAt = s;
    await replica.saveSyncState(st);
    return _writeSnapshot(st, ds);
  }

  /// 往这个目录写一份完整状态快照（vv 只记无缺口前缀，且只增不减）。读回校验通过才算写成。
  ///
  /// 正文按页从副本读（[SrsSyncReplica.exportSnapshotPages]），拼接、SHA-256 与读回校验在后台
  /// isolate 做：整份快照是全部历史（几万条事件、几十 MB），以前一次物化成对象、在调用方 isolate 上
  /// 编码再整份解码校验，大库上单段阻塞秒级（反馈 OMWOurRQKb）。
  Future<bool> _writeSnapshot(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
  ) async {
    final int own = st.nextBatchNo - 1;
    final SrsSnapshotHeader? previous = await _latestSnapshotHeader(
      st.writerId,
    );
    final Map<String, int> vv = <String, int>{...?previous?.vv};
    for (final MapEntry<String, int> e in st.cursors.entries) {
      if ((vv[e.key] ?? 0) < e.value) vv[e.key] = e.value;
    }
    vv[st.writerId] = own;
    final BytesBuilder events = BytesBuilder(copy: false);
    final BytesBuilder times = BytesBuilder(copy: false)..addByte(0x7b);
    bool firstTime = true;
    await replica.exportSnapshotPages(
      onEvents: (List<String> lines) async {
        final StringBuffer sb = StringBuffer();
        for (final String l in lines) {
          sb
            ..write(l)
            ..writeCharCode(0x0a);
        }
        events.add(utf8.encode(sb.toString()));
      },
      onServerTimes: (List<(String, int)> page) async {
        final StringBuffer sb = StringBuffer();
        for (final (String id, int t) in page) {
          if (!firstTime) sb.write(',');
          firstTime = false;
          sb
            ..write(jsonEncode(id))
            ..write(':')
            ..write(t);
        }
        times.add(utf8.encode(sb.toString()));
      },
    );
    times.addByte(0x7d);
    final Uint8List bytes = await srsEncodeSnapshotParts(
      writerId: st.writerId,
      maxOwnBatch: own,
      vv: vv,
      serverTimesJson: times.takeBytes(),
      eventsBody: events.takeBytes(),
    );
    await directory.write(st.writerId, srsSnapshotName(own), bytes);
    final Uint8List? back = await directory.read(
      st.writerId,
      srsSnapshotName(own),
    );
    if (back == null ||
        await srsDecodeSnapshotHeader(back) is! SrsFileOk<SrsSnapshotHeader>) {
      return false;
    }
    ds.lastSnapshotBatch = own;
    return true;
  }

  /// 坏的 cursor 文件按「没有 cursor 文件」处理（记进 [skipped]）：这个写入者不参与
  /// 清理门（不会因为它被提前删掉谁的数据——本写入者只删已被自己快照覆盖的批次），也不会被当作退役删除。
  Future<Map<String, SrsCursorFile>> _peerCursors(
    String self,
    List<String> skipped,
  ) async {
    final Map<String, SrsCursorFile> out = <String, SrsCursorFile>{};
    for (final String w in await directory.listWriters()) {
      if (w == self) continue;
      final Uint8List? bytes = await directory.read(w, srsCursorName);
      if (bytes == null) continue;
      switch (SrsCursorFile.tryDecode(bytes)) {
        case SrsFileOk<SrsCursorFile>(:final SrsCursorFile value):
          out[w] = value;
        case SrsFileMalformed<SrsCursorFile>(:final String reason):
          skipped.add('$w/$srsCursorName: $reason');
        case SrsFileIncomplete<SrsCursorFile>():
          break;
      }
    }
    return out;
  }

  Future<void> _cleanup(
    SrsSyncLocalState st,
    SrsDirectoryState ds,
    Map<String, SrsCursorFile> peers,
    int now,
    SrsSyncReport report,
  ) async {
    bool active(SrsCursorFile c) => now - c.updatedAtMs < options.retireAfterMs;
    final Iterable<SrsCursorFile> activePeers = peers.values.where(active);

    // 1. 本写入者的旧批次：已被自己在这个目录里的快照覆盖，且所有活跃对端的 cursor[自己] 都已越过。
    final List<String>? own = await directory.listFiles(st.writerId);
    for (final String f in own ?? const <String>[]) {
      final int? n = srsParseBatchName(f);
      if (n == null || n > ds.lastSnapshotBatch) continue;
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
        final SrsSnapshotHeader? snap = await _latestSnapshotHeader(holder);
        if (snap != null && (snap.vv[w] ?? 0) >= last) {
          covered = true;
          break;
        }
      }
      if (!covered) continue;
      await directory.deleteWriter(w);
      // [SrsDirectoryState.writers] 保留它最后一批的记录：数据已在活跃快照里，不算这个目录缺的。
      ds.alive.remove(w);
      report.writersDeleted.add(w);
    }
  }

  /// 不再留存「最近同步过的所有目录都已确认」的批次；超过上限时丢最旧的（落后的目录用快照补齐）。
  Future<void> _pruneSent(SrsSyncLocalState st, int now) async {
    final int own = st.nextBatchNo - 1;
    int through = own;
    for (final SrsDirectoryState d in st.directories.values) {
      final int? at = d.lastSyncAt;
      if (at == null || now - at >= options.retainSentForMs) continue;
      if (d.confirmedThrough < through) through = d.confirmedThrough;
    }
    if (own - through > options.maxSentBatches) {
      through = own - options.maxSentBatches;
    }
    if (through > 0) {
      await replica.dropSentBatches(st.writerId, throughNo: through);
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
