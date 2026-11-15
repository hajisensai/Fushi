/// RWKV 排程服务：排队时给候选复习卡打给定时刻的回忆率（RWKV-Instant）——排队里今天还没答过的卡给今天
/// 结束的时刻（[SrsRwkvService.instantRetrievability]，走常驻分数表）；今天答过的卡与统计页给此刻
/// （[SrsRwkvService.currentRetrievability]，直接查询、不进分数表）。
///
/// **编排在原生内核里**（native/fushi_rwkv 的 `sched` 模块，说明见那里的模块注释与 README「排程内核」）：
/// 「整个 collection 的复习历史回放进 RWKV」这份状态、runtime 本身、四级日志对齐（追加 → 退回重放 → 从检查点
/// 重来 → 全量重建）、常驻分数表何时清空 / 整表重查、快照与检查点文件、空闲存快照、准备 / 出错 / 重试，
/// 都由内核持有与决定；app 与无头服务端共用同一份。没准备好（权重没下载 / 正在恢复或重建 / 出错 / 已关闭）时
/// 内核对打分命令回「没有」，调用方这一次不出 RWKV 牌组的复习卡、等就绪（`SrsStudyState.rwkvPending`），
/// 不退回按 FSRS-7 存下的到期日排队。
///
/// 本文件只是内核的宿主，三件事：
/// - **递命令**：公开方法各对应一条内核命令（[RwkvSchedWire] 的 `cmd*`），等它的结果。
/// - **替内核取数**（effect）：复习库里的修订号、日志指纹与尾巴、回放行、追加行、查询行（都由 Rust 在 srs.db
///   上直读算出，见 native/fushi_fsrs/src/projection.rs、src/store/projections.rs；回放行的字节原样转给
///   内核，不在 Dart 里解码）、权重在哪 / 下载、调度日序、收段会话是否在进行。取数失败原样回给内核，由它决定
///   状态。
/// - **转事件**：内核的状态记录原样发到 [SrsRwkvService.statusChanges]；原生调用的开始 / 结束记进
///   [SrsOpLedger]（`rwkv:<调用>`，BUG-4075 取证）；空闲存快照的定时器由这里代为计时。
///
/// 这里不留内核状态的副本：[SrsRwkvService.status] 只是最后一条状态事件。
///
/// 已知近似（内核行为）：卡片换牌组、预设归属变化不触发重建（上游 kuma3 把它们当改写历史）；这类变化在下次
/// 全量重建（日志指纹变了、快照失效、设置里点「重建」）时才进入状态。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

export 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

/// 后台 runtime 的命令面：**测试接缝**。生产里 runtime 由内核自己持有；给了
/// [SrsRwkvService] 的 `openBackend` 时，内核把每次 runtime 调用转给这里（替身后端），编排照旧是内核的。
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

  /// 常驻分数表。
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

/// 内核自己报的错（例如快照文件写不了、runtime 拒绝了一批行）。宿主取数 / 替身后端抛的异常不包成它，
/// 原样出现在 [SrsRwkvStatus.error] 与命令的异常里。
class SrsRwkvKernelError implements Exception {
  const SrsRwkvKernelError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// [SrsRwkvService.journalSeed] 的缺省值（与原生撤销日志容量——约 600 条、32 MB——同量级）。
const int kSrsRwkvJournalSeed = 500;

/// [SrsRwkvService.requeryAfter] 的缺省值。
const Duration kSrsRwkvRequeryAfter = Duration(minutes: 30);

/// 一条在途命令：等它的结果，连同取数时要用的请求上下文。
class _Call {
  _Call(this.cards);

  final Completer<RwkvSchedReader?> done = Completer<RwkvSchedReader?>();

  /// 打分命令的候选卡（内核只知道张数，按下标要它们的输入与查询行）。
  final List<SrsRwkvCandidate> cards;

  /// 排队打分时取「打分输入」那一刻的牌组树与日界：之后建查询行用同一份。
  SrsDeckTree? tree;
  SrsDayContext? day;
}

class SrsRwkvService implements SrsRwkvScheduling, SrsRwkvStatusSource {
  SrsRwkvService({
    required this.store,
    required this.models,
    required this.snapshotDir,
    this.threads = 0,
    this.requeryAfter = kSrsRwkvRequeryAfter,
    this.journalSeed = kSrsRwkvJournalSeed,
    Future<SrsRwkvBackend> Function(File weights)? openBackend,
    void Function(String message)? log,
  }) : _open = openBackend,
       _log = log ?? ((String _) {});

  final SrsDbStore store;
  final SrsRwkvModels models;

  /// 快照缓存目录。
  final Directory snapshotDir;

  /// 原生线程数：0 = 全部核心。
  final int threads;

  /// 距上次整表重查满这么久，下一次排队前整表重查。
  final Duration requeryAfter;

  /// 整块回放（全量重建 / 检查点 / 退回重放）时最后这么多条 append 进撤销日志，其余整块 replay。
  final int journalSeed;

  /// 测试接缝（[SrsRwkvBackend]）；null = 内核自己持有 runtime。
  final Future<SrsRwkvBackend> Function(File weights)? _open;
  final void Function(String message) _log;

  /// 测试钩子：全量重建记下日志指纹（列卡之前）之后、开始取回放行之前调用（模拟用户在重建途中答题）。
  @visibleForTesting
  Future<void> Function()? debugAfterRebuildFingerprint;

  /// 排程用的状态精度（int4 卡状态 + int8 笔记状态，见 native/fushi_rwkv）。校准图的临时回放用同一个。
  static const RwkvPrecision precision = RwkvPrecision.int4;

  /// 有未存的追加 / 撤回时，空闲这么久后存一次快照。
  static const Duration _snapshotIdle = Duration(minutes: 2);

  /// 准备失败后的自动重试（排队时触发）最多每这么久一次；设置里的「重试」不受此限。
  static const Duration _retryAfter = Duration(minutes: 10);

  /// 复习统计页校准图的回放行：全部保留评分，与全量重建同一份（[_fetchReplay]）。不碰常驻状态，也不经
  /// 内核（内核的日志指纹簿记不能被它搅动）。
  Future<SrsRwkvReplay> calibrationReplay() async => srsDecodeRwkvReplay(
    await _fetchReplay(since: (await store.rwkvLogTail(since: 0)).maxRowId),
  );

  // ---------------------------------------------------------------- 状态事件

  final StreamController<SrsRwkvStatus> _status =
      StreamController<SrsRwkvStatus>.broadcast();

  /// 最后一条状态事件（不是内核状态的副本：内核那边才是真的）。
  SrsRwkvStatus _current = const SrsRwkvStatus(SrsRwkvPhase.idle);
  bool _closed = false;

  @override
  SrsRwkvStatus get status => _current;
  @override
  Stream<SrsRwkvStatus> get statusChanges => _status.stream;

  @override
  bool get ready => !_closed && _current.phase == SrsRwkvPhase.ready;

  void _set(SrsRwkvStatus status, {required bool phaseChanged}) {
    // 阶段切换记进账本（BUG-4075 取证：采样窗口里看得出 RWKV 是否卡在准备中、是否反复重建）。
    if (phaseChanged) SrsOpLedger.mark('rwkv:${status.phase.name}');
    _current = status;
    if (!_status.isClosed) _status.add(status);
  }

  // ---------------------------------------------------------------- 内核与消息泵

  /// 内核 worker；第一次需要时才起（对象本身很轻：没有 RWKV 牌组的库不起后台 isolate、不加载原生库）。
  Future<RwkvSchedWorker?>? _starting;
  RwkvSchedWorker? _kernel;
  StreamSubscription<Uint8List>? _outputs;

  /// 内核起不来（原生库缺失 / ABI 不符）：部署缺陷，只在「重试」时再试。
  bool _unavailable = false;

  int _nextOp = 1;
  final Map<int, _Call> _calls = <int, _Call>{};

  /// effect 回了失败时的原异常对象（按 effect id）：内核的状态 / 命令结果只带文本与出处，凭出处找回对象。
  final LinkedHashMap<int, Object> _faults = LinkedHashMap<int, Object>();

  /// 宿主后端模式下打开的替身后端（按内核给的编号）。
  final Map<int, SrsRwkvBackend> _backends = <int, SrsRwkvBackend>{};
  final Map<int, StreamSubscription<ModelDownloadEvent>> _downloads =
      <int, StreamSubscription<ModelDownloadEvent>>{};

  /// 在跑的原生调用（内核给的编号 → 账本令牌、字节、行数）。
  final Map<int, (int, int, int)> _nativeOps = <int, (int, int, int)>{};
  Timer? _timer;

  /// 递进去还没收尾的输入、在跑的取数、还没发出去的命令：都为 0 = 内核静下来了。
  int _inFlight = 0;
  int _handlers = 0;
  int _queued = 0;
  final List<Completer<void>> _settledWaiters = <Completer<void>>[];

  /// 测试的等待点：内核与宿主之间没有在途的消息、取数与命令（后台的整表重查、对齐都跑完了）。挂着的下载
  /// 算在途。内核在另一个 isolate 里，`pumpEventQueue` 等不到它。
  @visibleForTesting
  Future<void> debugSettled() {
    if (_isSettled) return Future<void>.value();
    final Completer<void> waiter = Completer<void>();
    _settledWaiters.add(waiter);
    return waiter.future;
  }

  bool get _isSettled => _inFlight == 0 && _handlers == 0 && _queued == 0;

  void _checkSettled() {
    if (!_isSettled || _settledWaiters.isEmpty) return;
    final List<Completer<void>> waiters = List<Completer<void>>.of(
      _settledWaiters,
    );
    _settledWaiters.clear();
    for (final Completer<void> waiter in waiters) {
      waiter.complete();
    }
  }

  Future<RwkvSchedWorker?> _spawn() async {
    try {
      final RwkvSchedWorker worker = await RwkvSchedWorker.spawn(
        config: rwkvSchedConfig(
          profile: store.profileUid,
          snapshotDir: snapshotDir.path,
          threads: threads,
          journalSeed: journalSeed,
          requeryAfter: requeryAfter,
          hostBackend: _open != null,
          snapshotIdle: _snapshotIdle,
          retryAfter: _retryAfter,
        ),
      );
      _outputs = worker.outputs.listen(
        _onOutput,
        onError: _onKernelError,
        onDone: _onKernelDone,
      );
      return _kernel = worker;
    } on Object catch (error, stack) {
      // 原生库是硬依赖：走到这里是部署坏了。RWKV 牌组的复习卡不出，界面给错误与「重试」。
      _log('RWKV kernel unavailable: $error\n$stack');
      _unavailable = true;
      if (!_closed) {
        _set(
          SrsRwkvStatus(SrsRwkvPhase.failed, error: error),
          phaseChanged: _current.phase != SrsRwkvPhase.failed,
        );
      }
      return null;
    }
  }

  /// 递一条命令并等结果（成功时是结果正文）。null = 这一次没有内核可问：已关闭、内核起不来，或
  /// [spawn] 为 false 而内核还没起过（没启动过的服务不为一次对齐 / 清除去起后台 isolate）。
  /// 命令失败时抛出原因（宿主取数抛的原异常，或 [SrsRwkvKernelError]）。
  Future<RwkvSchedReader?> _run(
    int command, {
    void Function(RwkvSchedWriter w)? args,
    List<SrsRwkvCandidate> cards = const <SrsRwkvCandidate>[],
    bool spawn = false,
    bool retry = false,
    bool closing = false,
  }) async {
    if (_closed && !closing) return null;
    if (_unavailable && retry) {
      _unavailable = false;
      _starting = null;
    }
    if (_unavailable || (_starting == null && !spawn)) return null;
    _queued++;
    final RwkvSchedWorker? kernel;
    try {
      kernel = await (_starting ??= _spawn());
    } finally {
      _queued--;
    }
    if (kernel == null ||
        !identical(kernel, _kernel) ||
        (_closed && !closing)) {
      _checkSettled();
      return null;
    }
    final int op = _nextOp++;
    final _Call call = _calls[op] = _Call(cards);
    final RwkvSchedWriter w = RwkvSchedWriter()
      ..u8(RwkvSchedWire.inCommand)
      ..u32(op)
      ..u8(command);
    args?.call(w);
    _send(<Uint8List>[w.take()]);
    return call.done.future;
  }

  void _send(List<Uint8List> parts) {
    final RwkvSchedWorker? kernel = _kernel;
    if (kernel == null) return;
    _inFlight++;
    kernel.send(parts);
  }

  void _onOutput(Uint8List output) {
    for (final RwkvSchedRecord record in rwkvSchedRecords(output)) {
      final RwkvSchedReader r = RwkvSchedReader(record.body);
      switch (record.tag) {
        case RwkvSchedWire.outStatus:
          final SrsRwkvPhase phase = SrsRwkvPhase.values[r.u8()];
          final bool changed = r.boolean();
          final int done = r.i64();
          final int total = r.i64();
          final Object? error = r.boolean() ? _faultOf(r.u32(), r.str()) : null;
          _set(
            SrsRwkvStatus(phase, done: done, total: total, error: error),
            phaseChanged: changed,
          );
        case RwkvSchedWire.outDone:
          final _Call? call = _calls.remove(r.u32());
          if (call == null) break;
          if (r.boolean()) {
            call.done.complete(r);
          } else {
            call.done.completeError(_faultOf(r.u32(), r.str()));
          }
        case RwkvSchedWire.outEffect:
          final int id = r.u32();
          final int kind = r.u8();
          _handlers++;
          if (kind == RwkvSchedWire.fxDownload) {
            _download(id);
          } else {
            unawaited(_effect(id, kind, r));
          }
        case RwkvSchedWire.outLog:
          _log(r.str());
        case RwkvSchedWire.outOpBegin:
          final int id = r.u32();
          final String name = r.str();
          _nativeOps[id] = (SrsOpLedger.begin('rwkv:$name'), r.i64(), r.i64());
        case RwkvSchedWire.outOpEnd:
          final (int, int, int)? op = _nativeOps.remove(r.u32());
          if (op != null) SrsOpLedger.end(op.$1, bytes: op.$2, rows: op.$3);
        case RwkvSchedWire.outTimer:
          final int generation = r.u32();
          final int afterMs = r.i64();
          _timer?.cancel();
          _timer = afterMs < 0
              ? null
              : Timer(Duration(milliseconds: afterMs), () {
                  _timer = null;
                  final RwkvSchedWriter w = RwkvSchedWriter()
                    ..u8(RwkvSchedWire.inTimer)
                    ..u32(generation);
                  _send(<Uint8List>[w.take()]);
                });
        case RwkvSchedWire.outCancel:
          final StreamSubscription<ModelDownloadEvent>? download = _downloads
              .remove(r.u32());
          if (download != null) {
            unawaited(download.cancel());
            _handlers--;
          }
      }
    }
    if (rwkvSchedSettles(output)) _inFlight--;
    _checkSettled();
  }

  Object _faultOf(int origin, String text) =>
      _faults[origin] ?? SrsRwkvKernelError(text);

  /// 内核拒绝了一条输入或 panic 过：它的状态不可信。在途的命令带着这个错结束，转「出错」；「重试」另起
  /// 一个内核（从快照恢复再按日志对齐）。
  void _onKernelError(Object error, StackTrace stack) {
    _log('RWKV kernel failed: $error\n$stack');
    final RwkvSchedWorker? kernel = _kernel;
    if (kernel == null) return;
    _dropKernel();
    unawaited(kernel.dispose());
    _unavailable = true;
    _finishCalls(error);
    if (!_closed) {
      _set(
        SrsRwkvStatus(SrsRwkvPhase.failed, error: error),
        phaseChanged: _current.phase != SrsRwkvPhase.failed,
      );
    }
    _checkSettled();
  }

  void _onKernelDone() {
    if (_kernel == null) return;
    _dropKernel();
    _finishCalls(null);
    _checkSettled();
  }

  /// 不再用现在这个内核：停掉代它计的时、代它下的载，在跑的原生调用记作结束。
  void _dropKernel() {
    _kernel = null;
    unawaited(_outputs?.cancel());
    _outputs = null;
    _timer?.cancel();
    _timer = null;
    for (final StreamSubscription<ModelDownloadEvent> download
        in _downloads.values) {
      unawaited(download.cancel());
      _handlers--;
    }
    _downloads.clear();
    for (final (int, int, int) op in _nativeOps.values) {
      SrsOpLedger.end(op.$1);
    }
    _nativeOps.clear();
    _backends.clear();
    _inFlight = 0;
  }

  /// 内核没了：还在等结果的命令到此为止（[error] 为 null = 当作「这一次没有内核可问」）。
  void _finishCalls(Object? error) {
    final List<_Call> calls = List<_Call>.of(_calls.values);
    _calls.clear();
    for (final _Call call in calls) {
      if (error == null) {
        call.done.complete(null);
      } else {
        call.done.completeError(error);
      }
    }
  }

  // ---------------------------------------------------------------- 回答 effect

  RwkvSchedWriter _replyHead(int effect, {required bool ok}) =>
      RwkvSchedWriter()
        ..u8(RwkvSchedWire.inReply)
        ..u32(effect)
        ..boolean(ok);

  void _fail(int effect, Object error) {
    // 只留最近的几个：内核收到失败后紧接着就会在状态 / 命令结果里引用它。
    _faults[effect] = error;
    while (_faults.length > 32) {
      _faults.remove(_faults.keys.first);
    }
    final RwkvSchedWriter w = _replyHead(effect, ok: false)..str('$error');
    _send(<Uint8List>[w.take()]);
  }

  Future<void> _effect(int id, int kind, RwkvSchedReader r) async {
    try {
      final RwkvSchedWriter head = _replyHead(id, ok: true);
      final Uint8List? body = await _answer(kind, r, head);
      _send(<Uint8List>[head.take(), ?body]);
    } on Object catch (error) {
      _fail(id, error);
    } finally {
      _handlers--;
      _checkSettled();
    }
  }

  /// 办 effect [kind]（参数在 [r]），把回复正文写进 [w]；大块的正文不拷进 [w]，作为返回值另给。
  Future<Uint8List?> _answer(
    int kind,
    RwkvSchedReader r,
    RwkvSchedWriter w,
  ) async {
    switch (kind) {
      case RwkvSchedWire.fxRevision:
        w.str(await store.changeFingerprint());
      case RwkvSchedWire.fxTail:
        await _tail(r, w);
      case RwkvSchedWire.fxReplay:
        return _fetchReplay(
          since: r.i64(),
          rebaseSince: r.optI64(),
          rowsFrom: r.optI64(),
        );
      case RwkvSchedWire.fxAppendRows:
        await _appendRows(r, w);
      case RwkvSchedWire.fxScoreInputs:
        await _scoreInputs(_callOf(r.u32()), r.i64(), w);
      case RwkvSchedWire.fxQueryRows:
        await _queryRowsFor(_callOf(r.u32()), r, w);
      case RwkvSchedWire.fxIngesting:
        w.boolean(store.sync2Ingesting);
      case RwkvSchedWire.fxIngestSettled:
        await store.sync2IngestSettled();
      case RwkvSchedWire.fxDayIndex:
        final int a = r.i64();
        final int b = r.i64();
        final SrsDayContext day = await store.dayContext();
        w
          ..i64(day.dayIndexOf(a))
          ..i64(day.dayIndexOf(b));
      case RwkvSchedWire.fxModelReady:
        w
          ..boolean(models.isReady)
          ..str(models.weightsFile.path);
      case RwkvSchedWire.fxDeleteRetired:
        await models.deleteRetired();
      case RwkvSchedWire.fxRebuildHook:
        await debugAfterRebuildFingerprint?.call();
      case RwkvSchedWire.fxOpenBackend:
        final int backend = r.u32();
        _backends[backend] = await _open!(File(r.str()));
      case RwkvSchedWire.fxBackend:
        await _backendCall(r, w);
      default:
        throw StateError('unknown RWKV kernel effect $kind');
    }
    return null;
  }

  _Call _callOf(int op) =>
      _calls[op] ?? (throw StateError('RWKV kernel asked about command $op'));

  /// 下载权重：进度一条条递给内核，下完 / 失败回复它；内核不等了（已关闭）就停。
  void _download(int id) {
    void finish() {
      if (_downloads.remove(id) == null) return;
      _handlers--;
      _checkSettled();
    }

    _downloads[id] = models.download().listen(
      (ModelDownloadEvent e) {
        final RwkvSchedWriter w = RwkvSchedWriter()
          ..u8(RwkvSchedWire.inProgress)
          ..u32(id)
          ..i64(e.receivedBytes)
          ..i64(e.totalBytes);
        _send(<Uint8List>[w.take()]);
      },
      onError: (Object error) {
        _fail(id, error);
        finish();
      },
      onDone: () {
        _send(<Uint8List>[_replyHead(id, ok: true).take()]);
        finish();
      },
      cancelOnError: true,
    );
  }

  /// 日志表指纹与尾巴。发查询的那一刻同步读内容修订号：它等于内核上次全量计数时记下的那个（没删过日志）
  /// 才只数新行（Rust 走 rowid 范围，O(新增)，每次作答对齐都走这里）；否则整表计数一次。
  Future<void> _tail(RwkvSchedReader r, RwkvSchedWriter w) async {
    final int sinceIncremental = r.i64();
    final int sinceFull = r.i64();
    final bool withRows = r.boolean();
    final String? ifContent = r.optStr();
    final String content = store.contentFingerprint;
    final bool incremental = ifContent != null && ifContent == content;
    final SrsRwkvLogTail t = await store.rwkvLogTail(
      since: incremental ? sinceIncremental : sinceFull,
      withRows: withRows,
      incremental: incremental,
    );
    w
      ..str(content)
      ..boolean(incremental)
      ..i64(t.count)
      ..i64(t.maxRowId)
      ..i64(t.newRows)
      ..u32(t.logs.length);
    for (final SrsRwkvTailLog l in t.logs) {
      w
        ..str(l.id)
        ..str(l.cardId)
        ..u8(switch (l.kind) {
          SrsLogKind.review => RwkvSchedWire.logReview,
          SrsLogKind.undo => RwkvSchedWire.logUndo,
          _ => RwkvSchedWire.logOther,
        })
        ..i64(l.at)
        ..optStr(l.revokes);
    }
  }

  /// 回放行（[SrsDbStore.rwkvReplayBytes]，参数同它）：全部卡由 Rust 一次取出、排好序，指纹出自同一个快照。
  /// 只列三列卡缓存（[SrsDbStore.cardColumns]）。列卡之后才新建（并已作答）的卡由 Rust 当「漏掉的卡」
  /// 报出来，补进卡表再取一次。返回未解码的字节（[srsDecodeRwkvReplay] 的布局）。
  Future<Uint8List> _fetchReplay({
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
    Future<Uint8List> fetch(int since) => store.rwkvReplayBytes(
      <String>[for (final _CardKey c in cards) c.id],
      _identities(cards, tree),
      day,
      since: since,
      rebaseSince: rebaseSince,
      rowsFrom: rowsFrom,
    );
    Uint8List replay = await fetch(since);
    for (int round = 0; round < 5; round++) {
      final List<String> strays = srsRwkvReplayStrays(replay);
      if (strays.isEmpty) break;
      final Set<String> known = <String>{for (final _CardKey c in cards) c.id};
      bool added = false;
      for (final String id in strays) {
        if (known.contains(id)) continue;
        final SrsCardCacheRow? row = await store.cardRow(id);
        if (row == null) continue;
        cards.add((id: row.id, noteId: row.noteId, deckId: row.deckId));
        added = true;
      }
      if (!added) break;
      final int next = srsRwkvReplayMaxRowId(replay);
      // 先放掉这一份再取下一份：两份都随日志总量线性占内存。
      replay = Uint8List(0);
      replay = await fetch(next);
    }
    return replay;
  }

  /// 追加用的行：每张卡末尾这几条日志各自的回放行（保留评分行由 Rust 从日志直读，一次调用），与撤销日志
  /// 标签。卡已不在 → 回「缺卡」；某张卡末尾对不上这几条日志 → 那张卡回「没有」（内核都改走退回重放）。
  Future<void> _appendRows(RwkvSchedReader r, RwkvSchedWriter w) async {
    final int count = r.u32();
    final List<String> cardIds = <String>[];
    final List<List<String>> logIds = <List<String>>[];
    for (int i = 0; i < count; i++) {
      cardIds.add(r.str());
      logIds.add(<String>[for (int k = r.u32(); k > 0; k--) r.str()]);
    }
    final List<String> tagIds = <String>[
      for (int k = r.u32(); k > 0; k--) r.str(),
    ];
    final SrsDayContext day = await store.dayContext();
    final SrsDeckTree tree = await store.deckTree();
    final List<_CardKey> cardKeys = <_CardKey>[];
    for (final String cardId in cardIds) {
      final SrsCardCacheRow? row = await store.cardRow(cardId);
      if (row == null) {
        w.boolean(true);
        return;
      }
      cardKeys.add((id: row.id, noteId: row.noteId, deckId: row.deckId));
    }
    final List<SrsRwkvCardRows> cards = await store.rwkvCardRows(
      <String>[for (final _CardKey c in cardKeys) c.id],
      _identities(cardKeys, tree),
      day,
    );
    w.boolean(false);
    for (int k = 0; k < cardKeys.length; k++) {
      final List<RwkvRows>? appended = cards[k].appendRows(logIds[k]);
      w.boolean(appended != null);
      if (appended == null) continue;
      for (final RwkvRows row in appended) {
        w.bytes(row.bytes);
      }
    }
    w.u64s(SrsIds.ankiNumericIds(tagIds));
  }

  /// 排队打分的输入：调度日、「每答几题刷新」（这次排队涉及的牌组里取最小，参数归属的 own 祖先的设置）、
  /// 分数表的两把钥匙（清空：本机状态纪元 + 日界设置；整表重查：[SrsDbStore.rwkvScoresKey]）、候选卡的
  /// 数字 id 与「版本」（最后一条有效日志 + 牌组 + 预设：换了任何一个，这张卡的查询行就变了）。
  Future<void> _scoreInputs(_Call call, int atMs, RwkvSchedWriter w) async {
    final List<SrsRwkvCandidate> cards = call.cards;
    final SrsDayContext day = call.day = await store.dayContext();
    final SrsDeckTree tree = call.tree = await store.deckTree();
    int refreshEvery = SrsRwkvQueueSettings.maxRefreshEvery;
    for (final String d in <String>{
      for (final SrsRwkvCandidate c in cards) c.deckId,
    }) {
      refreshEvery = min(
        refreshEvery,
        tree
            .paramsOwner(tree.effectiveDeckOf(d, fallback: store.defaultDeckId))
            .rwkvQueue
            .refreshEvery,
      );
    }
    final String clearKey =
        '${store.rwkvScoresClearKey}|${day.utcOffsetMin}|${day.rolloverHour}';
    final String requeryKey = store.rwkvScoresKey;
    final Map<String, String> presetOf = <String, String>{};
    final List<int> numeric = SrsIds.ankiNumericIds(<String>[
      for (final SrsRwkvCandidate c in cards) ...<String>[
        c.id,
        '${c.lastLogId}|${c.deckId}|'
            '${presetOf[c.deckId] ??= _presetOf(tree, c.deckId)}',
      ],
    ]);
    w
      ..i64(day.dayIndexOf(atMs))
      ..i64(refreshEvery)
      ..str(clearKey)
      ..str(requeryKey)
      ..i64s(<int>[for (int i = 0; i < cards.length; i++) numeric[2 * i]])
      ..u64s(<int>[for (int i = 0; i < cards.length; i++) numeric[2 * i + 1]]);
  }

  /// 命令 [call] 的候选卡（全部，或内核点名的那几张）在给定时刻的查询行与锚点。
  Future<void> _queryRowsFor(
    _Call call,
    RwkvSchedReader r,
    RwkvSchedWriter w,
  ) async {
    final int atMs = r.i64();
    final List<SrsRwkvCandidate> cards = r.boolean()
        ? <SrsRwkvCandidate>[for (final int i in r.u32s()) call.cards[i]]
        : call.cards;
    // 排队打分：与取打分输入时同一份牌组树与日界；「此刻」打分没有那一步，现取。
    final SrsDeckTree tree = call.tree ?? await store.deckTree();
    final SrsDayContext day = call.day ?? await store.dayContext();
    final ({RwkvRows rows, Int64List anchors}) q = await _queryRows(
      cards,
      tree,
      day,
      atMs,
    );
    w
      ..bytes(q.rows.bytes)
      ..i64s(q.anchors);
  }

  /// [cards] 在时刻 [atMs] 的查询行（读每张卡最后一条保留评分）与锚点（那条评分的时刻；没有 = -1）。
  Future<({RwkvRows rows, Int64List anchors})> _queryRows(
    List<SrsRwkvCandidate> cards,
    SrsDeckTree tree,
    SrsDayContext day,
    int atMs,
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
    return (rows: srsRwkvNowRows(now, nowMs: atMs, day: day), anchors: anchors);
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

  /// 宿主后端模式：把内核的一次 runtime 调用转给替身后端。
  Future<void> _backendCall(RwkvSchedReader r, RwkvSchedWriter w) async {
    final int id = r.u32();
    final int call = r.u8();
    final SrsRwkvBackend backend =
        _backends[id] ?? (throw StateError('RWKV backend $id is not open'));
    RwkvRows rows() => RwkvRows.fromBytes(r.bytes());
    Int64List words(Uint8List bytes) {
      final ByteData d = ByteData.sublistView(bytes);
      return Int64List.fromList(<int>[
        for (int i = 0; i < bytes.length; i += 8) d.getInt64(i, Endian.little),
      ]);
    }

    switch (call) {
      case RwkvSchedWire.bkReplay:
        await backend.replay(rows());
      case RwkvSchedWire.bkAppend:
        final RwkvRows appended = rows();
        final Int64List tags = words(r.bytes());
        w.boolean(await backend.append(appended, tags, words(r.bytes())));
      case RwkvSchedWire.bkUnappend:
        w.boolean(await backend.unappend(r.u64()));
      case RwkvSchedWire.bkRewind:
        final int at = r.i64();
        w.optI64(await backend.rewindFrom(at, r.i64()));
      case RwkvSchedWire.bkQuery:
        w.f32s(await backend.query(rows()));
      case RwkvSchedWire.bkClearScores:
        await backend.clearScores();
      case RwkvSchedWire.bkLookupScores:
        final Int64List ids = r.i64s();
        final RwkvScoreLookup found = await backend.lookupScores(ids, r.u64s());
        w
          ..f32s(found.scores)
          ..bytes(found.found);
      case RwkvSchedWire.bkUpdateScores:
        final RwkvRows queries = rows();
        final Uint64List versions = r.u64s();
        w.f32s(await backend.updateScores(queries, versions, r.i64s()));
      case RwkvSchedWire.bkRequeryScores:
        final int today = r.i64();
        w.i64(await backend.requeryScores(today, r.i64()));
      case RwkvSchedWire.bkRemoveScores:
        w.i64(await backend.removeScores(r.i64s()));
      case RwkvSchedWire.bkSnapshotToFile:
        await backend.snapshotToFile(r.str());
      case RwkvSchedWire.bkRestoreFromFile:
        await backend.restoreFromFile(r.str());
      case RwkvSchedWire.bkReset:
        await backend.reset();
      case RwkvSchedWire.bkClose:
        _backends.remove(id);
        await backend.close();
      default:
        throw StateError('unknown RWKV backend call $call');
    }
  }

  // ---------------------------------------------------------------- 命令

  /// 开始准备：权重没下载时先下载（RWKV 是新建牌组的默认算法，不能要求用户先去设置里点下载），
  /// 再恢复快照或全量回放。已在准备时等它，已就绪时只对齐日志。失败后的自动重试（排队时触发）有间隔
  /// 限制，免得断网时每出一张卡都重下一遍；[force]（设置里「重试」）不受此限。
  @override
  Future<void> start({bool force = false}) async {
    await _run(
      RwkvSchedWire.cmdStart,
      args: (RwkvSchedWriter w) => w.boolean(force),
      spawn: true,
      retry: force,
    );
  }

  /// 设置里「重建 RWKV 状态」：按全部复习历史重新回放，期间「准备中」。
  ///
  /// 平时不需要：日志的任何变化都由内核的四级对齐精确跟上。但卡片换牌组、预设归属变化不进状态（见
  /// 文件头「已知近似」），在那之后想让状态跟上就靠这里（对应上游的「Build Cache」）。还没准备好
  /// 时等同 [start]（force）。
  Future<void> rebuild() async {
    await _run(RwkvSchedWire.cmdRebuild, spawn: true, retry: true);
  }

  /// 对齐日志（追加 → 退回重放 → 检查点 → 全量重建）。返回 false = RWKV 现在没有可用状态（未就绪 / 已关闭 /
  /// 刚转去检查点或全量重建，「准备中」）。
  Future<bool> refresh() async =>
      (await _run(RwkvSchedWire.cmdRefresh))?.boolean() ?? false;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int atMs,
  }) => _score(RwkvSchedWire.cmdInstant, cards, atMs);

  @override
  Future<List<double>?> currentRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) => _score(RwkvSchedWire.cmdCurrent, cards, nowMs);

  /// 打分命令。null = 没就绪（内核已顺手开始准备）或打分失败（内核已转「出错」）——都不出卡。
  Future<List<double>?> _score(
    int command,
    List<SrsRwkvCandidate> cards,
    int atMs,
  ) async {
    final RwkvSchedReader? r = await _run(
      command,
      args: (RwkvSchedWriter w) => w
        ..u32(cards.length)
        ..i64(atMs),
      cards: cards,
      spawn: true,
    );
    if (r == null || !r.boolean()) return null;
    return <double>[for (final double v in r.f32s()) v];
  }

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {
    // 本机这条与对端同步来的都在日志表里：内核统一按指纹对齐。
    await _run(RwkvSchedWire.cmdAnswered);
  }

  @override
  Future<void> onCardsPurged(List<String> cardIds) async {
    if (cardIds.isEmpty) return;
    await _run(
      RwkvSchedWire.cmdPurged,
      args: (RwkvSchedWriter w) => w.i64s(SrsIds.ankiNumericIds(cardIds)),
    );
  }

  /// 换模型 / 退出：内核存快照、关 runtime，然后停掉它。关了的服务永远「没就绪」。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      try {
        await _run(RwkvSchedWire.cmdClose, closing: true);
      } finally {
        final RwkvSchedWorker? kernel = _kernel;
        if (kernel != null) {
          _dropKernel();
          await kernel.dispose();
        }
        _finishCalls(null);
        _checkSettled();
      }
    } finally {
      await _status.close();
    }
  }
}

/// 取回放行时读卡缓存只要的三列。
typedef _CardKey = ({String id, String noteId, String deckId});
