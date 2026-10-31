/// RWKV 排程服务：维护「整个 collection 的复习历史回放进 RWKV」这份状态，排队时给候选复习卡打
/// 此刻的回忆率（RWKV-Instant，[instantRetrievability]）。
///
/// - 状态由后台 isolate 里的原生 runtime 持有（[RwkvWorker]）；本类只发粗粒度命令。
/// - **对齐日志，结果始终与全量回放逐位相同**（RWKV 的笔记 / 牌组 / 预设 / 全局状态是多张卡共用的，回放
///   顺序不同结果就不同，所以不做「乱序也直接追加」这类近似）。按代价从低到高：
///   1. **追加**（[_appendNew]）：新评分都晚于已回放的最后一条（严格晚于）、各是其卡末尾的保留评分 → 按顺序
///      追加，原生侧每条记一条撤销日志（带评分时刻）；撤销最近的作答（复习页 Ctrl+Z）按撤销日志原样撤回。
///   2. **退回重放**（[_rebase]）：其余变化（同步来的评分插在已回放的行中间、撤销更早的作答、重置、学习序列
///      重启……）由 Rust 在同一个快照里算出**分歧时刻**（回放序列最早从哪一行起不同），原生侧按撤销日志
///      退到这个时刻之前，再按时间顺序追加从这里起的全部行。撤销日志约 600 条（32 MB），覆盖最近的作答。
///   3. **从检查点重来**（[_rebaseFromCheckpoint]）：撤销日志够不着时，从磁盘上较早的状态快照（检查点，
///      [_saveSnapshot] 换日时把前一天的快照留下来；保留最近一份与一份一周前的）恢复，只回放它之后的行。
///   4. **全量重建**（[_rebuildAll]）：第一次准备、删过日志、检查点也够不着、设置里点「重建」。
///   3、4 期间「准备中」：RWKV 牌组的到期复习卡等它（不退回 FSRS-7 的到期日），新卡与学习中的卡照常出。
///   失败 → 「出错」，[_retryAfter] 后（或设置里「重试」）再来。
/// - **常驻分数表**（上游 JSchoreels/anki 的 per-deck 分数表 + 预测记忆化，状态在原生侧）：排队时
///   每张候选卡的 R 按（卡、最后一条有效日志、牌组、预设）记在原生分数表里，省掉的是「读历史、
///   建查询行」；原生侧作答 / 撤销只作废同一张卡与同一条笔记的项。
///   **表里别的卡的 R 并不因此还是最新的**：小模型有卡 / 笔记 / 牌组 / 预设 / 全局五条状态流，
///   今日复习数等输入也是共享的，答 B 之后用新状态查 A 的结果可能与 A 的旧分数不同。所以模型
///   状态每推进 N 次（牌组设置「每答几题刷新」[SrsRwkvQueueSettings.refreshEvery]，同一次排队涉及
///   多个牌组时取最小；追加的评分与撤回各算一次，本机与同步来的都算——数的是
///   状态真的变了几次，不是查询命中比例，HBK-AUDIT-019）就整表按此刻重查一次（原生侧改写查询行、
///   不回读历史）；缺省 1 = 每题。这一次重查**放到后台、下一次排队生效**：本次排队先用表里现有的
///   分数（作答卡与同笔记卡已按最新状态补算），出完这一张再在 worker 里重查，用户看卡的工夫里就
///   算完了。实测 1.2 万候选卡：同步重查让「作答 → 出下一张」从约 90 ms 变成约 300 ms，放后台
///   后不再算进这段（srs_rwkv_answer_bench_test）。代价是别的卡的分数晚一题跟上。另外换日、牌组
///   设置变化、同步合并后（[SrsDbStore.rwkvScoresKey]）、距上次整表重查满 [requeryAfter]（查询
///   行里的间隔秒数随时间走；只在下一次排队时检查，不是定时器）当场整表重查（这几种旧分数可能
///   整体失效，不能晚一题）；日界设置变化时清空
///   重建。增量与全量走同一个原生查询，每行的 R 不取决于同批别的行，逐位一致
///   （native/fushi_rwkv/tests/journal.rs）——这只证明查询实现一致，不证明旧分数仍准确。
/// - **清除**：卡被永久清除（srs_purge.dart）后它的项从表里删掉（[onCardsPurged]），否则一直占着
///   内存、每次整表重查都白算（HBK-AUDIT-020）。
/// - **快照缓存**：重建完、空闲 [_snapshotIdle] 后与关闭时把状态写到磁盘，按（模型、精度、日志
///   指纹）命中；下次启动只需追加快照之后的新日志。状态文件由 worker 内的 Rust 流式读写，
///   isolate 之间只传路径，不把整份模型状态复制进 Dart。
/// - **取数**：回放行（保留评分、card_type、间隔，规则同上游 kuma3，见 native/fushi_rwkv/README.md）、
///   日志指纹与尾巴都由 Rust 在 srs.db 上直读算出（native/fushi_fsrs/src/projection.rs、
///   src/store/projections.rs），日志不经 Dart；这里只编排。
/// - 没准备好（权重没下载 / 正在恢复或重建 / 出错）时 [instantRetrievability] 返回 null，调用方这一次不出 RWKV
///   牌组的复习卡、等就绪（`SrsStudyState.rwkvPending`），不退回按 FSRS-7 存下的到期日排队。
///
/// 已知近似：卡片换牌组、预设归属变化不触发重建（上游 kuma3 把它们当改写历史）；这类变化在下次
/// 全量重建（日志指纹变了、快照失效、换模型）时才进入状态。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

export 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

/// 后台 runtime 的命令面（生产实现是 [RwkvWorker]；测试可替换）。
abstract interface class SrsRwkvBackend {
  Future<void> replay(RwkvRows rows);

  /// 追加并记撤销日志（标签、评分时刻毫秒与行同序；时刻不得早于日志里最后一条）。false = 模型不支持
  /// 撤销日志，行已按普通回放追加。
  Future<bool> append(RwkvRows rows, List<int> tags, List<int> ats);

  /// 撤回最近一条 [append]（仅当标签是 [tag]）；false = 不是它，什么都没改。
  Future<bool> unappend(int tag);

  /// 退到时刻 [atMs] 之前：撤掉撤销日志里时刻 ≥ [atMs] 的全部条目，返回撤了几条（状态与只回放过时刻
  /// < [atMs] 的行逐位相同）。[floorMs]：最近一次 replay / restore / reset 之后不经撤销日志进来的行最晚
  /// 的时刻（[kRwkvFloorEmpty] / [kRwkvFloorUnknown]）。null = 退不到（那些行不早于 [atMs]），什么都没改。
  Future<int?> rewindFrom(int atMs, int floorMs);

  /// 每行（查询行）此刻的 R；不合法的行是 NaN。
  Future<Float32List> query(RwkvRows rows);

  /// 常驻分数表（见文件头）。
  Future<void> clearScores();
  Future<RwkvScoreLookup> lookupScores(Int64List cardIds, Uint64List versions);
  Future<Float32List> updateScores(
    RwkvRows rows,
    Uint64List versions,
    Int64List anchorsMs,
  );
  Future<int> requeryScores(int today, int nowMs);

  /// 从分数表删掉这些卡（永久清除的卡），返回删掉的项数。
  Future<int> removeScores(Int64List cardIds);

  Future<Uint8List> snapshot();
  Future<void> restore(Uint8List snapshot);

  /// 无损流式快照；调用者提供临时路径，成功后再提交文件和元数据。
  Future<void> snapshotToFile(String path);
  Future<void> restoreFromFile(String path);
  Future<void> reset();
  Future<void> close();
}

class _WorkerBackend implements SrsRwkvBackend {
  _WorkerBackend(this.worker);
  final RwkvWorker worker;

  @override
  Future<void> replay(RwkvRows rows) => worker.replay(rows);
  @override
  Future<bool> append(RwkvRows rows, List<int> tags, List<int> ats) =>
      worker.append(rows, tags, ats);
  @override
  Future<bool> unappend(int tag) => worker.unappend(tag);
  @override
  Future<int?> rewindFrom(int atMs, int floorMs) =>
      worker.rewindFrom(atMs, floorMs);
  @override
  Future<Float32List> query(RwkvRows rows) => worker.query(rows);
  @override
  Future<void> clearScores() => worker.clearScores();
  @override
  Future<RwkvScoreLookup> lookupScores(
    Int64List cardIds,
    Uint64List versions,
  ) => worker.lookupScores(cardIds, versions);
  @override
  Future<Float32List> updateScores(
    RwkvRows rows,
    Uint64List versions,
    Int64List anchorsMs,
  ) => worker.updateScores(rows, versions, anchorsMs);
  @override
  Future<int> requeryScores(int today, int nowMs) =>
      worker.requeryScores(today, nowMs);
  @override
  Future<int> removeScores(Int64List cardIds) => worker.removeScores(cardIds);
  @override
  Future<Uint8List> snapshot() => worker.snapshot();
  @override
  Future<void> restore(Uint8List snapshot) => worker.restore(snapshot);
  @override
  Future<void> snapshotToFile(String path) => worker.snapshotToFile(path);
  @override
  Future<void> restoreFromFile(String path) => worker.restoreFromFile(path);
  @override
  Future<void> reset() => worker.reset();
  @override
  Future<void> close() => worker.close();
}

/// 服务阶段（界面显示用）。
enum SrsRwkvPhase {
  /// 还没启动（没有 RWKV 牌组时不启动）。
  idle,

  /// 正在下载所选模型的权重（[SrsRwkvStatus.done] / [SrsRwkvStatus.total] 是字节）。
  downloading,

  /// 正在加载 / 恢复快照或检查点 / 全量回放。
  preparing,

  /// 可以排程。
  ready,

  /// 出错（[SrsRwkvStatus.error]）；下次需要时重试。
  failed,
}

class SrsRwkvStatus {
  const SrsRwkvStatus(this.phase, {this.done = 0, this.total = 0, this.error});

  final SrsRwkvPhase phase;

  /// 进度：下载时是字节，全量回放时是条数。
  final int done;
  final int total;
  final Object? error;
}

/// 复习日志表的指纹：行数与最大 rowid（日志只追加，所以「只多了新行」= 行数与 rowid 同增）。
typedef _LogPrint = ({int count, int maxRowId});

/// 新日志表里的一行（[SrsRwkvService._appendNew]）。
typedef _NewLog = ({
  String id,
  String cardId,
  String kind,
  int at,
  String? revokes,
});

/// [SrsRwkvService.requeryAfter] 的缺省值。
const Duration kSrsRwkvRequeryAfter = Duration(minutes: 30);

class SrsRwkvService implements SrsRwkvScheduling {
  SrsRwkvService({
    required this.store,
    required this.models,
    required this.snapshotDir,
    this.threads = 0,
    this.requeryAfter = kSrsRwkvRequeryAfter,
    Future<SrsRwkvBackend> Function(File weights)? openBackend,
    void Function(String message)? log,
  }) : _open = openBackend ?? _openWorker,
       _log = log ?? ((String _) {});

  final SrsDbStore store;
  final SrsRwkvModels models;

  /// 快照缓存目录。
  final Directory snapshotDir;

  /// 原生线程数：0 = 全部核心。
  final int threads;

  /// 距上次整表重查满这么久，下一次排队前整表重查（见文件头）。
  final Duration requeryAfter;
  final Future<SrsRwkvBackend> Function(File weights) _open;
  final void Function(String message) _log;

  /// 测试钩子：全量重建记下日志指纹（列卡之前）之后、开始取回放行之前调用（模拟用户在重建途中答题）。
  @visibleForTesting
  Future<void> Function()? debugAfterRebuildFingerprint;

  static Future<SrsRwkvBackend> _openWorker(File weights) async =>
      _WorkerBackend(
        await RwkvWorker.spawn(
          modelPath: weights.path,
          precision: RwkvPrecision.int4,
        ),
      );

  SrsRwkvBackend? _backend;
  _LogPrint? _replayed;

  /// 上次全量计数核对过 [_replayed] 时的 [SrsDbStore.contentFingerprint]：没变时日志只可能新增（复习日志
  /// 不推进内容修订号；删日志的清除、恢复、重读本机状态都推进），行数按新增的行累加，不必每次
  /// 作答都对整个 profile 计数。只在全量计数与 [_replayed] 对得上（或计数本身就成了新的 [_replayed]）
  /// 时记下：对不上（删过日志）时记了，下一次增量累加就会把删除掩盖掉，退回重放 / 重建永远等不到。
  String? _countedAt;

  /// 已回放的评分里最晚的时刻（追加只接受严格晚于它的；不晚于它的走 [_rebase]）。撤回一条后不往回退
  /// （保守：之后与它同时或更早的评分多走一次退回重放，结果照样精确）。
  int? _lastAt;
  int _appendsSinceSnapshot = 0;

  /// 状态里不经撤销日志进来的行（整块 replay 的、快照 / 检查点里的）最晚的时刻：退回重放只能退到它之后
  /// （[SrsRwkvBackend.rewindFrom] 的 floor）。每次 reset / restore / replay 时跟着改。
  int _journalFloor = kRwkvFloorUnknown;

  /// 有新的追加 / 撤回、还没写进快照时，空闲这么久后存一次（以前每 50 次作答整份导出写盘，
  /// 快照几十到几百 MB）。关闭时也存。
  static const Duration _snapshotIdle = Duration(minutes: 2);
  Timer? _snapshotTimer;

  /// 分数表的全量刷新状态（见文件头）。
  String? _scoresClearKey;
  String? _scoresRequeryKey;
  int? _scoresToday;
  int _scoresAt = 0;

  /// 上次整表重查以来模型状态推进的次数（[_appendNew] 追加的评分与撤回）。
  int _stateChangesSinceRequery = 0;

  /// 后台整表重查已排进 worker、还没跑完。
  bool _requeryPending = false;

  /// [SrsDbStore.changeFingerprint] 上次核对时的值（状态与日志表一致时记下）。
  String? _checkedRevision;
  Future<void>? _preparing;
  Future<void> _queue = Future<void>.value();
  Future<void> _refreshQueue = Future<void>.value();
  bool _closed = false;

  final StreamController<SrsRwkvStatus> _status =
      StreamController<SrsRwkvStatus>.broadcast();
  SrsRwkvStatus _current = const SrsRwkvStatus(SrsRwkvPhase.idle);

  SrsRwkvStatus get status => _current;
  Stream<SrsRwkvStatus> get statusChanges => _status.stream;

  void _set(SrsRwkvStatus status) {
    _current = status;
    if (!_status.isClosed) _status.add(status);
  }

  /// 串行执行（runtime 不是线程安全的，回放 / 查询 / 快照不能交错）。
  Future<T> _serial<T>(Future<T> Function() task) {
    final Future<T> result = _queue.then((_) => task());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 快照文件名里的模型键（沿用小模型 + int4 时的旧名，已有快照照样命中）。
  static const String _modelKey = 'small-int4';
  File _snapshotOf(String modelKey) =>
      File(p.join(snapshotDir.path, 'rwkv-${store.profileUid}-$modelKey.snap'));
  File get _snapshotFile => _snapshotOf(_modelKey);
  File get _snapshotMeta => File('${_snapshotFile.path}.json');

  /// 已移除的大模型留下的回放快照（大的每卡约 25.7 KB）与权重：准备时顺手删掉。
  Future<void> _deleteRetired() async {
    final File large = _snapshotOf('large-int8');
    for (final File f in <File>[large, File('${large.path}.json')]) {
      if (await f.exists()) await f.delete();
    }
    await models.deleteRetired();
  }

  /// 开始准备：权重没下载时先下载（RWKV 是新建牌组的默认算法，不能要求用户先去设置里点下载），
  /// 再恢复快照或全量回放。已在准备时什么都不做，已就绪时只对齐日志。失败后的自动重试（排队时
  /// 调用）最多每 [_retryAfter] 一次，免得断网时每出一张卡都重下一遍；[force]（设置里「重试」）
  /// 不受此限。
  Future<void> start({bool force = false}) async {
    if (_closed) return;
    if (_current.phase == SrsRwkvPhase.ready) {
      await refresh();
      return;
    }
    final DateTime? failedAt = _failedAt;
    if (!force &&
        _preparing == null &&
        failedAt != null &&
        DateTime.now().difference(failedAt) < _retryAfter) {
      return;
    }
    await (_preparing ??= _prepare().whenComplete(() => _preparing = null));
  }

  /// 设置里「重建 RWKV 状态」：按全部复习历史重新回放，期间「准备中」。
  ///
  /// 平时不需要：日志的任何变化都按文件头的四级对齐精确跟上。但卡片换牌组、预设归属变化不进状态（见
  /// 文件头「已知近似」），在那之后想让状态跟上就靠这里（对应上游的「Build Cache」）。还没准备好
  /// 时等同 [start]（force）。
  Future<void> rebuild() async {
    if (_closed) return;
    if (_backend == null || _current.phase != SrsRwkvPhase.ready) {
      await start(force: true);
      return;
    }
    await _recover(null);
  }

  static const Duration _retryAfter = Duration(minutes: 10);
  DateTime? _failedAt;

  void _fail(Object error) {
    _failedAt = DateTime.now();
    _set(SrsRwkvStatus(SrsRwkvPhase.failed, error: error));
  }

  Future<void> _prepare() async {
    try {
      await _deleteRetired();
    } catch (error) {
      _log('RWKV retired model cleanup failed: $error');
    }
    if (!models.isReady) {
      _set(const SrsRwkvStatus(SrsRwkvPhase.downloading));
      try {
        await for (final ModelDownloadEvent e in models.download()) {
          if (_closed) return;
          _set(
            SrsRwkvStatus(
              SrsRwkvPhase.downloading,
              done: e.receivedBytes,
              total: e.totalBytes,
            ),
          );
        }
      } catch (error, stack) {
        _log('RWKV model download failed: $error\n$stack');
        _fail(error);
        return;
      }
      if (_closed) return;
    }
    _set(const SrsRwkvStatus(SrsRwkvPhase.preparing));
    try {
      final SrsRwkvBackend backend = _backend ??= await _open(
        models.weightsFile,
      );
      final bool restored = await _serial(() => _restoreSnapshot(backend));
      if (!restored) await _rebuildAll(backend);
      _set(const SrsRwkvStatus(SrsRwkvPhase.ready));
    } catch (error, stack) {
      _log('RWKV prepare failed: $error\n$stack');
      _fail(error);
    }
  }

  /// 日志表指纹（行数与最大 rowid），Rust 在读连接上一条语句取出。
  /// 日志表指纹。[_replayed] 已知、且上次全量计数之后内容修订号没变（没删过日志）时，只数
  /// rowid 之后的新行（Rust 走 rowid 范围，O(新增)）；否则整表计数一次。
  Future<_LogPrint> _fingerprint() async {
    final _LogPrint? base = _replayed;
    final String content = store.contentFingerprint;
    if (base != null && _countedAt == content) {
      final SrsRwkvLogTail added = await store.rwkvLogTail(
        since: base.maxRowId,
        incremental: true,
      );
      return (
        count: base.count + added.count,
        maxRowId: added.count == 0 ? base.maxRowId : added.maxRowId,
      );
    }
    final SrsRwkvLogTail t = await store.rwkvLogTail(since: 0);
    // 没有 [_replayed] 时这次计数就是全量回放的基数；有时不知道它与 [_replayed] 是否一致，不记。
    if (base == null) _countedAt = content;
    return (count: t.count, maxRowId: t.maxRowId);
  }

  /// [_fingerprint] 连同 rowid 在 [afterRowId] 之后的行数（[withRows] 时连同这些行），同一个快照里
  /// 取出：两者对不上只可能是删过日志，不会是两次查询之间又落了作答。
  ///
  /// [afterRowId] 就是已回放的位置、且上次全量计数之后没删过日志（[_countedAt]）时只数新增的行
  /// （O(新增)，每次作答对齐都走这里）；否则整表计数一次。
  Future<(_LogPrint, int, List<SrsRwkvTailLog>)> _tailAfter(
    int afterRowId, {
    bool withRows = false,
  }) async {
    final _LogPrint? base = _replayed;
    final String content = store.contentFingerprint;
    if (base != null && base.maxRowId == afterRowId && _countedAt == content) {
      final SrsRwkvLogTail t = await store.rwkvLogTail(
        since: afterRowId,
        withRows: withRows,
        incremental: true,
      );
      return (
        (
          count: base.count + t.count,
          maxRowId: t.count == 0 ? base.maxRowId : t.maxRowId,
        ),
        t.newRows,
        t.logs,
      );
    }
    final SrsRwkvLogTail t = await store.rwkvLogTail(
      since: afterRowId,
      withRows: withRows,
    );
    if (base != null &&
        base.maxRowId == afterRowId &&
        t.count - t.newRows == base.count) {
      _countedAt = content;
    }
    return ((count: t.count, maxRowId: t.maxRowId), t.newRows, t.logs);
  }

  Future<bool> _restoreSnapshot(SrsRwkvBackend backend) async {
    if (!await _snapshotFile.exists() || !await _snapshotMeta.exists()) {
      return false;
    }
    try {
      final Map<String, Object?> meta =
          jsonDecode(await _snapshotMeta.readAsString())
              as Map<String, Object?>;
      if (meta['v'] != 1) return false;
      await backend.restoreFromFile(_snapshotFile.path);
      _replayed = (
        count: meta['count']! as int,
        maxRowId: meta['maxRowId']! as int,
      );
      _lastAt = meta['lastAt'] as int?;
      _journalFloor = _lastAt ?? kRwkvFloorEmpty;
      return true;
    } catch (error) {
      // 快照坏了或属于别的模型 / 精度：丢掉，全量重建。
      _log('RWKV snapshot ignored: $error');
      return false;
    }
  }

  Future<void> _saveSnapshot(SrsRwkvBackend backend) async {
    final _LogPrint? replayed = _replayed;
    if (replayed == null) return;
    await snapshotDir.create(recursive: true);
    // 先把新快照完整写进 .tmp，成功了才动磁盘上的旧主快照（留作检查点 / 被替换）：流式写到一半失败时
    // 旧主快照与元数据原样在，下次启动照常从它恢复。
    final File tmp = File('${_snapshotFile.path}.tmp');
    await backend.snapshotToFile(tmp.path);
    await _keepCheckpoint();
    await tmp.rename(_snapshotFile.path);
    await _snapshotMeta.writeAsString(
      jsonEncode(<String, Object?>{
        'v': 1,
        'count': replayed.count,
        'maxRowId': replayed.maxRowId,
        'lastAt': _lastAt,
      }),
      flush: true,
    );
    _appendsSinceSnapshot = 0;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
  }

  /// 有未存的追加 / 撤回：空闲 [_snapshotIdle] 后存快照（期间再有作答就顺延）。
  void _scheduleSnapshot(SrsRwkvBackend backend) {
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(_snapshotIdle, () {
      _snapshotTimer = null;
      if (_closed ||
          _appendsSinceSnapshot == 0 ||
          _current.phase != SrsRwkvPhase.ready) {
        return;
      }
      unawaited(
        _serial(() => _saveSnapshot(backend)).catchError((Object error) {
          _log('RWKV snapshot save failed: $error');
        }),
      );
    });
  }

  /// 检查点（见文件头第 3 级）：磁盘上较早的状态快照，状态 = 当时日志里时刻 ≤ [lastAt] 的全部保留评分。
  /// 文件名带 [lastAt]，元数据与主快照同格式。
  static const String _checkpointTag = '.cp-';

  /// 换日后第一次存快照时，把磁盘上前一天的主快照留作检查点（改名，不重写），再按 [_pruneCheckpoints] 修剪。
  Future<void> _keepCheckpoint() async {
    final _Checkpoint? previous = await _readCheckpoint(
      _snapshotFile,
      _snapshotMeta,
    );
    final int? last = previous?.lastAt;
    final int? now = _lastAt;
    if (previous == null || last == null || now == null) return;
    final SrsDayContext day = await store.dayContext();
    if (day.dayIndexOf(last) >= day.dayIndexOf(now)) return;
    final String base = _snapshotFile.path.replaceAll(RegExp(r'\.snap$'), '');
    final File snap = File('$base$_checkpointTag$last.snap');
    await previous.snap.rename(snap.path);
    await previous.meta.rename('${snap.path}.json');
    await _pruneCheckpoints(now);
  }

  /// 检查点只留两份：最新的一份（通常是前一天的），与最年轻的一份「比最新评分早一周以上」的（还没有
  /// 这么老的时候留最老的一份，让它慢慢变老）。每份和主快照一样大。
  Future<void> _pruneCheckpoints(int newestAt) async {
    final List<_Checkpoint> all = await _checkpoints();
    if (all.length <= 2) return;
    final Set<_Checkpoint> keep = <_Checkpoint>{all.first};
    final int weekAgo = newestAt - const Duration(days: 7).inMilliseconds;
    final Iterable<_Checkpoint> old = all.where(
      (_Checkpoint c) => c.lastAt! <= weekAgo,
    );
    keep.add(old.isEmpty ? all.last : old.first);
    for (final _Checkpoint c in all) {
      if (!keep.contains(c)) await _deleteCheckpoint(c);
    }
  }

  /// 本 profile 的检查点，评分时刻新的在前（读不了的丢掉）。
  Future<List<_Checkpoint>> _checkpoints() async {
    if (!await snapshotDir.exists()) return const <_Checkpoint>[];
    final String prefix = p.basename(
      _snapshotFile.path.replaceAll(RegExp(r'\.snap$'), _checkpointTag),
    );
    final List<_Checkpoint> out = <_Checkpoint>[];
    await for (final FileSystemEntity e in snapshotDir.list()) {
      final String name = p.basename(e.path);
      if (e is! File || !name.startsWith(prefix) || !name.endsWith('.snap')) {
        continue;
      }
      final _Checkpoint? c = await _readCheckpoint(e, File('${e.path}.json'));
      if (c == null || c.lastAt == null) {
        await e.delete();
        continue;
      }
      out.add(c);
    }
    out.sort((_Checkpoint a, _Checkpoint b) => b.lastAt!.compareTo(a.lastAt!));
    return out;
  }

  Future<_Checkpoint?> _readCheckpoint(File snap, File meta) async {
    if (!await snap.exists() || !await meta.exists()) return null;
    try {
      final Map<String, Object?> m =
          jsonDecode(await meta.readAsString()) as Map<String, Object?>;
      if (m['v'] != 1) return null;
      return (
        snap: snap,
        meta: meta,
        print: (count: m['count']! as int, maxRowId: m['maxRowId']! as int),
        lastAt: m['lastAt'] as int?,
      );
    } catch (error) {
      _log('RWKV checkpoint ignored: $error');
      return null;
    }
  }

  Future<void> _deleteCheckpoint(_Checkpoint c) async {
    for (final File f in <File>[c.snap, c.meta]) {
      if (await f.exists()) await f.delete();
    }
  }

  /// 全量重建（第一次准备、或 [_recover] 兜底）：在正在用的 runtime 上 reset 后回放全部历史，期间「准备中」。
  Future<void> _rebuildAll(SrsRwkvBackend backend) async {
    final _LogPrint fingerprint = await _fingerprint();
    await debugAfterRebuildFingerprint?.call();
    final SrsRwkvReplay replay = await _fetchReplay(
      since: fingerprint.maxRowId,
    );
    await _serial(() async {
      await backend.reset();
      _journalFloor = kRwkvFloorEmpty;
      await _replayRows(backend, replay, _preparingProgress);
      _replayed = (count: replay.count, maxRowId: replay.maxRowId);
      _lastAt = replay.lastAt;
      _forgetScores();
      await _saveSnapshot(backend);
    });
  }

  void _preparingProgress(int done, int total) =>
      _set(SrsRwkvStatus(SrsRwkvPhase.preparing, done: done, total: total));

  /// 状态整体换过（reset / restore）：原生分数表已清空，按此刻重来。
  void _forgetScores() {
    _checkedRevision = null;
    _scoresClearKey = null;
    _scoresRequeryKey = null;
    _scoresToday = null;
    _stateChangesSinceRequery = 0;
  }

  /// 撤销日志的种子：全量回放 / 从检查点重来时，最后这么多条 append 进撤销日志（其余整块 replay，快），
  /// 之后晚到的评分落在这一段里就能就地退回重放（[_rebase]）。与原生日志容量（约 600 条）同量级。
  static const int _journalSeed = 500;

  /// 把 [replay] 的行回放进 [backend]（已在 [_serial] 里，调用方已按 reset / restore 设好 [_journalFloor]）：
  /// 前面的按 65,536 条一块 replay，最后 [_journalSeed] 条 append 进撤销日志。
  Future<void> _replayRows(
    SrsRwkvBackend backend,
    SrsRwkvReplay replay,
    void Function(int done, int total) onProgress,
  ) async {
    final RwkvRows rows = replay.rows;
    final int split = max(0, rows.length - _journalSeed);
    final Uint8List bytes = rows.bytes;
    onProgress(0, rows.length);
    const int block = 65536;
    for (int start = 0; start < split; start += block) {
      final int end = min(start + block, split);
      await backend.replay(
        RwkvRows.fromBytes(
          Uint8List.sublistView(
            bytes,
            start * kFrwkvReviewSize,
            end * kFrwkvReviewSize,
          ),
        ),
      );
      onProgress(end, rows.length);
    }
    if (split > 0) _journalFloor = replay.ats[split - 1];
    if (split < rows.length) {
      await _append(
        backend,
        RwkvRows.fromBytes(
          Uint8List.sublistView(bytes, split * kFrwkvReviewSize),
        ),
        replay.tags.sublist(split),
        replay.ats.sublist(split),
      );
      onProgress(rows.length, rows.length);
    }
  }

  /// [SrsRwkvBackend.append]；模型不支持撤销日志（行已按普通回放进去）时把 [_journalFloor] 推到这些行。
  Future<void> _append(
    SrsRwkvBackend backend,
    RwkvRows rows,
    List<int> tags,
    List<int> ats,
  ) async {
    if (!await backend.append(rows, tags, ats)) {
      _journalFloor = max(_journalFloor, ats.last);
    }
  }

  /// 取回放行（[SrsDbStore.rwkvReplay]，参数同它）：全部卡由 Rust 一次取出、排好序，指纹出自同一个快照。
  /// 只列三列卡缓存（[SrsDbStore.cardColumns]）。列卡之后才新建（并已作答）的卡由 Rust 当「漏掉的卡」
  /// 报出来，补进卡表再取一次。
  Future<SrsRwkvReplay> _fetchReplay({
    required int since,
    int? rebaseSince,
    int? rowsFrom,
  }) async {
    final SrsDayContext day = await store.dayContext();
    final SrsDeckTree tree = await store.deckTree();
    final SrsColumns keys = await store.cardColumns(
      fields: const <String>['id', 'note_id', 'deck_id'],
    );
    final SrsStringColumn keyId = keys.strings('id');
    final SrsStringColumn keyNote = keys.strings('note_id');
    final SrsStringColumn keyDeck = keys.strings('deck_id');
    final List<_CardKey> cards = <_CardKey>[
      for (int i = 0; i < keys.rows; i++)
        (id: keyId[i], noteId: keyNote[i], deckId: keyDeck[i]),
    ]..sort((_CardKey a, _CardKey b) => a.id.compareTo(b.id));
    Future<SrsRwkvReplay> fetch(int since) => store.rwkvReplay(
      <String>[for (final _CardKey c in cards) c.id],
      _identities(cards, tree),
      day,
      since: since,
      rebaseSince: rebaseSince,
      rowsFrom: rowsFrom,
    );
    SrsRwkvReplay replay = await fetch(since);
    for (int round = 0; round < 5 && replay.strays.isNotEmpty; round++) {
      final Set<String> known = <String>{for (final _CardKey c in cards) c.id};
      bool added = false;
      for (final String id in replay.strays) {
        if (known.contains(id)) continue;
        final SrsCardCacheRow? row = await store.cardRow(id);
        if (row == null) continue;
        cards.add((id: row.id, noteId: row.noteId, deckId: row.deckId));
        added = true;
      }
      if (!added) break;
      replay = await fetch(replay.maxRowId);
    }
    return replay;
  }

  /// 第 2 级（见文件头）：Rust 算出 [done] 之后的日志造成的分歧时刻与从那里起的行，原生侧按撤销日志退到
  /// 它之前、再按时间顺序追加（取行与指纹出自同一个快照，读的途中又落的日志留给下一次对齐）。true = 已对齐；
  /// false = 删过日志，只能全量重建。撤销日志够不着时转第 3 级（[_recover]）并返回 true——那时已不在「就绪」。
  Future<bool> _rebase(SrsRwkvBackend backend, _LogPrint done) async {
    final SrsRwkvReplay replay = await _fetchReplay(
      since: done.maxRowId,
      rebaseSince: done.maxRowId,
    );
    // 同一个快照里：rowid 不超过已回放位置的行数没变 = 没删过日志。
    if (replay.count - replay.tailRows != done.count) return false;
    final _LogPrint now = (count: replay.count, maxRowId: replay.maxRowId);
    final int? diverge = replay.divergeAt;
    final bool reached = await _serial(() async {
      if (diverge == null) {
        // 新日志不改变任何回放行（例如暂停、改标签）。
        _replayed = now;
        return true;
      }
      int rewound = 0;
      final int? lastAt = _lastAt;
      if (lastAt != null && diverge <= lastAt) {
        final int? n = await backend.rewindFrom(diverge, _journalFloor);
        if (n == null) return false;
        rewound = n;
      }
      if (replay.rows.length > 0) {
        await _append(backend, replay.rows, replay.tags, replay.ats);
      }
      _replayed = now;
      _lastAt = replay.lastAt;
      _stateChangesSinceRequery += rewound + replay.rows.length;
      _appendsSinceSnapshot += rewound + replay.rows.length;
      _scheduleSnapshot(backend);
      return true;
    });
    if (!reached) unawaited(_recover(diverge));
    return true;
  }

  /// 第 3、4 级（见文件头）：「准备中」，先找评分时刻早于 [diverge] 的检查点恢复、回放它之后的行，不行就
  /// 全量重建（[diverge] 为 null = 直接全量）。同时只跑一个（与 [start] 共用 [_preparing]）；失败 → 「出错」。
  Future<void> _recover(int? diverge) {
    if (_closed) return Future<void>.value();
    final Future<void>? running = _preparing;
    if (running != null) return running;
    _set(const SrsRwkvStatus(SrsRwkvPhase.preparing));
    return _preparing = () async {
      final SrsRwkvBackend backend = _backend!;
      try {
        if (diverge == null || !await _rebaseFromCheckpoint(backend, diverge)) {
          await _rebuildAll(backend);
        }
        if (!_closed) _set(const SrsRwkvStatus(SrsRwkvPhase.ready));
      } catch (error, stack) {
        _log('RWKV recovery failed: $error\n$stack');
        _fail(error);
      }
    }().whenComplete(() => _preparing = null);
  }

  /// 第 3 级：从评分时刻早于 [diverge] 的检查点（新的先试）恢复，只回放它之后的行。检查点在这里按当前日志
  /// 当场核对——它之后没删过日志、它之后的日志造成的分歧晚于它的时刻——核对不过的删掉。都不行返回 false。
  Future<bool> _rebaseFromCheckpoint(
    SrsRwkvBackend backend,
    int diverge,
  ) async {
    for (final _Checkpoint c in await _checkpoints()) {
      final int at = c.lastAt!;
      if (at >= diverge) continue;
      final SrsRwkvReplay replay = await _fetchReplay(
        since: c.print.maxRowId,
        rebaseSince: c.print.maxRowId,
        rowsFrom: at + 1,
      );
      final int? since = replay.divergeAt;
      if (replay.count - replay.tailRows != c.print.count ||
          (since != null && since <= at)) {
        await _deleteCheckpoint(c);
        continue;
      }
      final bool restored = await _serial(() async {
        try {
          await backend.restoreFromFile(c.snap.path);
        } catch (error) {
          // 检查点坏了（截断 / 写坏 / 属于别的模型或精度）：与主快照（[_restoreSnapshot]）同一处置——不用它，
          // 删掉、试下一份，都不行就全量重建。backend 里半恢复的状态由下一份检查点的 restore 或重建的 reset
          // 整体覆盖。只兜 restore：回放出错是另一回事，照旧转「出错」。
          _log('RWKV checkpoint ignored: $error');
          return false;
        }
        _journalFloor = at;
        await _replayRows(backend, replay, _preparingProgress);
        _replayed = (count: replay.count, maxRowId: replay.maxRowId);
        _lastAt = replay.lastAt ?? at;
        _forgetScores();
        _appendsSinceSnapshot += replay.rows.length;
        return true;
      });
      if (!restored) {
        await _deleteCheckpoint(c);
        continue;
      }
      _scheduleSnapshot(backend);
      return true;
    }
    return false;
  }

  /// 卡 → 数字身份（53 位 hash，与 Anki 导出同一套），每卡 4 个：卡 / 笔记 / 牌组 / 预设（= 参数归属牌组）。
  List<int> _identities(List<_CardKey> rows, SrsDeckTree tree) =>
      SrsIds.ankiNumericIds(<String>[
        for (final _CardKey c in rows) ...<String>[
          c.id,
          c.noteId,
          c.deckId,
          _presetOf(tree, c.deckId),
        ],
      ]);

  static String _presetOf(SrsDeckTree tree, String deckId) {
    try {
      return tree.paramsOwner(deckId).id;
    } on Object {
      return deckId;
    }
  }

  /// 对齐日志（文件头的四级）：追加 → 退回重放 → 检查点 → 全量重建。返回 false = RWKV 现在没有可用状态
  /// （未就绪 / 已关闭 / 刚转去检查点或全量重建，「准备中」）。串行：作答与预览可能同时调用，同一条日志只能
  /// 追加一次。
  Future<bool> refresh() {
    final Future<bool> result = _refreshQueue.then((_) => _refreshOnce());
    _refreshQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _refreshOnce() async {
    if (_closed ||
        _backend == null ||
        _replayed == null ||
        _current.phase != SrsRwkvPhase.ready) {
      return false;
    }
    // 先比 store 的内存修订号（零成本）：没变就不必扫日志表（每张卡出题都会走到这里）。
    final String revision = await store.changeFingerprint();
    if (revision == _checkedRevision) return true;
    // 作答不等这里（`SrsDbStore.answer` 里 unawaited 的 onAnswered）：对齐途中用户可能又答了
    // 一题，读到的日志就比指纹新。这时按新指纹再对一次，而不是当成「历史被改写」去全量重建
    // ——连续答题时那样会一直退回「RWKV 还没准备好」。
    for (int attempt = 0; attempt < 10; attempt++) {
      final SrsRwkvBackend backend = _backend!;
      final _LogPrint done = _replayed!;
      final (_LogPrint now, int newRows, _) = await _tailAfter(done.maxRowId);
      if (now == done) {
        _checkedRevision = revision;
        return true;
      }
      // 没有新行而指纹变了 = 删过日志：改写了历史。
      if (now.maxRowId <= done.maxRowId) break;
      // 新增行数与行数差对不上（同一快照里取的，所以是删过日志）：重来一次；一直对不上时尝试用完，
      // 全量重建。
      if (now.count - done.count != newRows) continue;
      final bool? appended = await _appendNew(backend, done.maxRowId, now);
      if (appended == null) continue;
      if (!appended) {
        final bool rebased;
        try {
          rebased = await _rebase(backend, done);
        } catch (error, stack) {
          // 例如换过日界设置、行的日序对不上已回放的：状态可能退了一半，全量重建会先 reset。
          _log('RWKV rebase failed, rebuilding: $error\n$stack');
          break;
        }
        if (!rebased) break;
        // 撤销日志够不着、转去从检查点重来：这次没有可用状态。
        if (_current.phase != SrsRwkvPhase.ready) return false;
      }
      _checkedRevision = revision;
      return true;
    }
    unawaited(_recover(null));
    return false;
  }

  /// Rust 给出的日志尾巴 → [_NewLog]（kind 与撤销目标都由 `ffsrs_store_rwkv_log_tail` 直接给出）。
  List<_NewLog> _newLogs(List<SrsRwkvTailLog> logs) => <_NewLog>[
    for (final SrsRwkvTailLog l in logs)
      (id: l.id, cardId: l.cardId, kind: l.kind, at: l.at, revokes: l.revokes),
  ];

  /// 第 1 级（见文件头）：rowid 之后的新日志若只有评分与撤销、评分都严格晚于已回放的最后一条且按时间先后、
  /// 各是其卡末尾的保留评分、撤销撤的都是撤销日志里最近的那几条（复习页的 Ctrl+Z），就按日志顺序追加 /
  /// 撤回并返回 true；否则返回 false（调用方走 [_rebase]；中途失败时已追加的行记进了 [_lastAt]，退回重放
  /// 会一并撤掉）。读的途中日志表又变了（指纹不再是 [now]）返回 null，调用方按新指纹重来。
  Future<bool?> _appendNew(
    SrsRwkvBackend backend,
    int afterRowId,
    _LogPrint now,
  ) async {
    final (_LogPrint print, int _, List<SrsRwkvTailLog> logs) =
        await _tailAfter(afterRowId, withRows: true);
    if (print != now) return null;
    final List<_NewLog> fetched = _newLogs(logs);
    if (fetched.any(
      (_NewLog r) =>
          r.kind != SrsLogKind.review &&
          (r.kind != SrsLogKind.undo || r.revokes == null),
    )) {
      return false;
    }
    // 两次对齐之间答了又撤回（同一批里评分与撤销它的那条）：相互抵消，两条都不碰状态。
    final Set<String> revokedHere = <String>{
      for (final _NewLog r in fetched)
        if (r.kind == SrsLogKind.undo) r.revokes!,
    };
    final Set<String> cancelled = <String>{
      for (final _NewLog r in fetched)
        if (r.kind == SrsLogKind.review && revokedHere.contains(r.id)) r.id,
    };
    final List<_NewLog> rows = <_NewLog>[
      for (final _NewLog r in fetched)
        if (!cancelled.contains(r.id) &&
            !(r.kind == SrsLogKind.undo && cancelled.contains(r.revokes)))
          r,
    ];
    final List<_NewLog> ratings = <_NewLog>[
      for (final _NewLog r in rows)
        if (r.kind == SrsLogKind.review) r,
    ];
    // 只接受严格晚于已回放的最后一条、且彼此按时间先后的评分：RWKV 的笔记 / 牌组 / 预设 / 全局状态是多张卡
    // 共用的，追加顺序必须与全量回放的时间顺序一致才逐位相同。同一时刻也不追加——全量回放里同一时刻的行按卡
    // 排序，追加顺序未必是那样。这些都交给退回重放（[_rebase]），它同样精确，只是多读一次日志。
    int? last = _lastAt;
    for (final _NewLog r in ratings) {
      if (last != null && r.at <= last) return false;
      last = r.at;
    }
    final SrsDayContext day = await store.dayContext();
    // 同一张卡可能来了多条（两次对齐之间学习步「重来」后又答了一次）：按卡一次算出它末尾这几条
    // 的行，再按全局时间顺序拼。以前一见到同卡多条就全量重建，复习中会反复退回「RWKV 还没准备好」。
    final Map<String, List<String>> idsByCard = <String, List<String>>{};
    for (final _NewLog r in ratings) {
      (idsByCard[r.cardId] ??= <String>[]).add(r.id);
    }
    final SrsDeckTree tree = await store.deckTree();
    final List<_CardKey> cardKeys = <_CardKey>[];
    for (final String cardId in idsByCard.keys) {
      final SrsCardCacheRow? row = await store.cardRow(cardId);
      if (row == null) return false;
      cardKeys.add((id: row.id, noteId: row.noteId, deckId: row.deckId));
    }
    // 保留评分行由 Rust 从日志直读（一次调用）。
    final List<SrsRwkvCardRows> cards = await store.rwkvCardRows(
      <String>[for (final _CardKey c in cardKeys) c.id],
      _identities(cardKeys, tree),
      day,
    );
    // 取完再核对：取的途中又写进了日志，取到的行就比 [now] 新，按新指纹重来。
    if (await _fingerprint() != now) return null;
    final Map<String, RwkvRows> rowOf = <String, RwkvRows>{};
    for (int k = 0; k < cardKeys.length; k++) {
      final List<String> ids = idsByCard[cardKeys[k].id]!;
      final List<RwkvRows>? appended = cards[k].appendRows(ids);
      if (appended == null) return false;
      for (int i = 0; i < ids.length; i++) {
        rowOf[ids[i]] = appended[i];
      }
    }
    final List<int> tags = SrsIds.ankiNumericIds(<String>[
      for (final _NewLog r in rows) r.revokes ?? r.id,
    ]);
    return _serial(() async {
      // 排队期间后台重建换上了新 runtime：这批行属于新状态的指纹之后，按新状态重来。
      if (!identical(backend, _backend)) return null;
      List<RwkvRows> pending = <RwkvRows>[];
      List<int> pendingTags = <int>[];
      List<int> pendingAts = <int>[];
      Future<void> flush() async {
        if (pendingTags.isEmpty) return;
        final RwkvRows batch = RwkvRows(pending.length);
        pending.forEach(batch.addRows);
        await _append(backend, batch, pendingTags, pendingAts);
        // 先记下：后面的撤回失败时，退回重放要从不晚于这些行的时刻退。
        _lastAt = max(_lastAt ?? pendingAts.last, pendingAts.last);
        pending = <RwkvRows>[];
        pendingTags = <int>[];
        pendingAts = <int>[];
      }

      for (int i = 0; i < rows.length; i++) {
        final _NewLog r = rows[i];
        if (r.kind == SrsLogKind.review) {
          pending.add(rowOf[r.id]!);
          pendingTags.add(tags[i]);
          pendingAts.add(r.at);
          continue;
        }
        await flush();
        // 撤的不是撤销日志里最近的那条（更早的作答、重启前的作答）：退回重放。
        if (!await backend.unappend(tags[i])) return false;
      }
      await flush();
      _stateChangesSinceRequery += rows.length;
      _replayed = now;
      _appendsSinceSnapshot += fetched.length;
      if (fetched.isNotEmpty) _scheduleSnapshot(backend);
      return true;
    });
  }

  @override
  bool get ready => !_closed && _current.phase == SrsRwkvPhase.ready;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async {
    if (_current.phase != SrsRwkvPhase.ready) {
      unawaited(start());
      return null;
    }
    final SrsRwkvBackend? backend = _backend;
    if (backend == null) return null;
    try {
      if (!await refresh()) return null;
      if (cards.isEmpty) return const <double>[];
      final SrsDayContext day = await store.dayContext();
      final SrsDeckTree tree = await store.deckTree();
      final int today = day.dayIndexOf(nowMs);
      // 「每答几题刷新」：这次排队涉及的牌组里取最小（参数归属的 own 祖先的设置）。
      int refreshEvery = SrsRwkvQueueSettings.maxRefreshEvery;
      for (final String d in <String>{
        for (final SrsRwkvCandidate c in cards) c.deckId,
      }) {
        refreshEvery = min(
          refreshEvery,
          tree
              .paramsOwner(
                tree.effectiveDeckOf(d, fallback: store.defaultDeckId),
              )
              .rwkvQueue
              .refreshEvery,
        );
      }
      final bool requeryAfterThis = await _alignScores(
        backend,
        day,
        today,
        nowMs,
        refreshEvery: refreshEvery,
      );
      // 卡的数字 id 与「版本」（最后一条有效日志 + 牌组 + 预设：换了任何一个，这张卡的查询行就变了）。
      final Map<String, String> presetOf = <String, String>{};
      final List<int> numeric = SrsIds.ankiNumericIds(<String>[
        for (final SrsRwkvCandidate c in cards) ...<String>[
          c.id,
          '${c.lastLogId}|${c.deckId}|'
              '${presetOf[c.deckId] ??= _presetOf(tree, c.deckId)}',
        ],
      ]);
      final Int64List ids = Int64List(cards.length);
      final Uint64List versions = Uint64List(cards.length);
      for (int i = 0; i < cards.length; i++) {
        ids[i] = numeric[2 * i];
        versions[i] = numeric[2 * i + 1];
      }
      final RwkvScoreLookup found = await _serial(
        () => backend.lookupScores(ids, versions),
      );
      final Float32List scores = found.scores;
      final List<int> missing = <int>[
        for (int i = 0; i < cards.length; i++)
          if (found.found[i] == 0) i,
      ];
      if (missing.isNotEmpty) {
        final Float32List fresh = await _scoreMissing(
          backend,
          <SrsRwkvCandidate>[for (final int i in missing) cards[i]],
          Uint64List.fromList(<int>[for (final int i in missing) versions[i]]),
          tree,
          day,
          nowMs,
        );
        for (int k = 0; k < missing.length; k++) {
          scores[missing[k]] = fresh[k];
        }
      }
      if (requeryAfterThis) _requeryInBackground(backend, today, nowMs);
      return <double>[for (final double v in scores) v];
    } catch (error, stack) {
      _log('RWKV instant retrievability failed: $error\n$stack');
      _scoringFailed(backend, error);
      return null;
    }
  }

  /// 已就绪时打分失败（例如 worker 崩了 / 已关）。这不是「还没准备好」：留在「就绪」的话调用方（复习页、
  /// 牌组列表）等的「就绪」永远不会再来，RWKV 牌组的复习卡就一直静默不出。所以转「出错」（界面给错误与
  /// 「重试」），并丢掉这个后端——它的状态已不可信；重试（[start]）重新打开 worker、从快照恢复再按日志对齐。
  /// 正在准备（[_recover] 已接手）或已关闭时不动，由那边决定状态。
  void _scoringFailed(SrsRwkvBackend backend, Object error) {
    if (_closed || _preparing != null || _current.phase != SrsRwkvPhase.ready) {
      return;
    }
    if (identical(_backend, backend)) {
      _backend = null;
      _replayed = null;
      _countedAt = null;
      _appendsSinceSnapshot = 0;
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
      _forgetScores();
      unawaited(
        backend.close().catchError((Object e) {
          _log('RWKV backend close after scoring failure failed: $e');
        }),
      );
    }
    _fail(error);
  }

  /// 分数表的全量刷新时机（见文件头）：日界设置 / 本机状态纪元变了 → 清空（之后按历史重算）；
  /// 换日、牌组设置或同步合并（[SrsDbStore.rwkvScoresKey]）、距上次整表重查满 [requeryAfter]
  /// → 当场整表重查；只是模型状态推进满 [refreshEvery] 次 → 返回 true，调用方用完这次
  /// 的分数后在后台重查（[_requeryInBackground]）。
  Future<bool> _alignScores(
    SrsRwkvBackend backend,
    SrsDayContext day,
    int today,
    int nowMs, {
    required int refreshEvery,
  }) async {
    final String clearKey =
        '${store.rwkvScoresClearKey}|${day.utcOffsetMin}|${day.rolloverHour}';
    final String requeryKey = store.rwkvScoresKey;
    if (clearKey != _scoresClearKey) {
      await _serial(backend.clearScores);
    } else if (requeryKey != _scoresRequeryKey ||
        today != _scoresToday ||
        nowMs - _scoresAt >= requeryAfter.inMilliseconds ||
        nowMs < _scoresAt) {
      await _serial(() => backend.requeryScores(today, nowMs));
    } else {
      return _stateChangesSinceRequery >= refreshEvery;
    }
    _scoresClearKey = clearKey;
    _scoresRequeryKey = requeryKey;
    _scoresToday = today;
    _scoresAt = nowMs;
    _stateChangesSinceRequery = 0;
    return false;
  }

  /// 后台整表重查（见文件头）：排在本次排队的查询后面，同一个 worker 串行，不与查询交错。
  /// 计数在排进去时清零：重查期间又答的题算下一轮。已有一轮在排队时不再排。
  void _requeryInBackground(SrsRwkvBackend backend, int today, int nowMs) {
    if (_requeryPending) return;
    _requeryPending = true;
    _stateChangesSinceRequery = 0;
    unawaited(
      _serial(() => backend.requeryScores(today, nowMs))
          .then<void>((_) {
            if (today == _scoresToday && nowMs > _scoresAt) _scoresAt = nowMs;
          })
          .catchError((Object error) {
            _log('RWKV background requery failed: $error');
          })
          .whenComplete(() => _requeryPending = false),
    );
  }

  /// 分数表里没有（或版本变了）的卡：读历史、按此刻建查询行，一次原生调用算完并记进表里。
  Future<Float32List> _scoreMissing(
    SrsRwkvBackend backend,
    List<SrsRwkvCandidate> cards,
    Uint64List versions,
    SrsDeckTree tree,
    SrsDayContext day,
    int nowMs,
  ) async {
    final Int64List anchors = Int64List(cards.length);
    final List<SrsRwkvNowCard> now = <SrsRwkvNowCard>[];
    for (int at = 0; at < cards.length; at += 500) {
      final List<SrsRwkvCandidate> chunk = cards.sublist(
        at,
        min(at + 500, cards.length),
      );
      final List<int> numeric = SrsIds.ankiNumericIds(<String>[
        for (final SrsRwkvCandidate c in chunk) ...<String>[
          c.id,
          c.noteId,
          c.deckId,
          _presetOf(tree, c.deckId),
        ],
      ]);
      // 最后一条保留评分由 Rust 从日志直读（一块一次）。
      final List<SrsRwkvCardRows> kept = await store.rwkvCardRows(
        <String>[for (final SrsRwkvCandidate c in chunk) c.id],
        numeric,
        day,
      );
      for (int i = 0; i < chunk.length; i++) {
        final SrsRwkvLastRating? last = kept[i].last;
        anchors[at + i] = last?.at ?? -1;
        now.add((
          cardId: numeric[4 * i],
          noteId: numeric[4 * i + 1],
          deckId: numeric[4 * i + 2],
          presetId: numeric[4 * i + 3],
          last: last,
          queue: SrsQueue.review,
        ));
      }
    }
    final RwkvRows rows = srsRwkvNowRows(now, nowMs: nowMs, day: day);
    return _serial(() => backend.updateScores(rows, versions, anchors));
  }

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {
    if (_current.phase != SrsRwkvPhase.ready) return;
    // 本机这条与对端同步来的都在日志表里：统一按指纹对齐（见文件头的四级）。
    await refresh();
  }

  @override
  Future<void> onCardsPurged(List<String> cardIds) async {
    final SrsRwkvBackend? backend = _backend;
    if (backend == null || _closed || cardIds.isEmpty) return;
    final Int64List ids = Int64List.fromList(SrsIds.ankiNumericIds(cardIds));
    try {
      await _serial(() => backend.removeScores(ids));
    } catch (error) {
      // 删不掉只是多占内存；下次重建 / 清空时随整表一起没了。
      _log('RWKV score eviction failed: $error');
    }
  }

  /// 换模型 / 退出：存快照、关 worker。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    final SrsRwkvBackend? backend = _backend;
    try {
      if (backend != null) {
        try {
          if (_current.phase == SrsRwkvPhase.ready &&
              _appendsSinceSnapshot > 0) {
            await _serial(() => _saveSnapshot(backend));
          }
        } finally {
          await backend.close();
        }
      }
    } finally {
      await _status.close();
    }
  }
}

/// 取回放行时读卡缓存只要的三列。
typedef _CardKey = ({String id, String noteId, String deckId});

/// 磁盘上的一份状态快照（主快照或检查点）及其元数据。
typedef _Checkpoint = ({File snap, File meta, _LogPrint print, int? lastAt});
