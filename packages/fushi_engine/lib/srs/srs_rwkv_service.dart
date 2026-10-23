/// RWKV 排程服务：维护「整个 collection 的复习历史回放进 RWKV」这份状态，排队时给候选复习卡打
/// 此刻的回忆率（RWKV-Instant，[instantRetrievability]）。
///
/// - 状态由后台 isolate 里的原生 runtime 持有（[RwkvWorker]）；本类只发粗粒度命令。
/// - **增量**：本机作答后追加这一条（[onAnswered]）；对端同步来的新评分若都在已回放的最后一条之后，
///   也只追加。其余变化（撤销、重置、学习序列重启、插进历史中间的旧日志）→ 后台全量重建。
/// - **快照缓存**：重建完与关闭时把状态写到磁盘，按（模型、精度、日志指纹）命中；下次启动只需追加
///   之后的新日志。
/// - 没准备好（权重没下载 / 正在重建 / 出错）时 [instantRetrievability] 返回 null，调用方按存下的
///   到期日排队并在界面上说明（`SrsAnswerPreview.rwkvUnavailable`）。
///
/// - **取数**：回放行（保留评分、card_type、间隔，规则同上游 kuma3，见 native/fushi_rwkv/README.md）、
///   日志指纹与尾巴都由 Rust 在 srs.db 上直读算出（native/fushi_fsrs/src/projection.rs、
///   src/store/projections.rs），日志不经 Dart；这里只编排。
///
/// 已知近似：卡片换牌组、预设归属变化不触发重建（上游 kuma3 把它们当改写历史）；这类变化在下次
/// 全量重建（日志指纹变了、快照失效、换模型）时才进入状态。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
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

  /// 每行（查询行）此刻的 R；不合法的行是 NaN。
  Future<Float32List> query(RwkvRows rows);
  Future<Uint8List> snapshot();
  Future<void> restore(Uint8List snapshot);
  Future<void> reset();
  Future<void> close();
}

class _WorkerBackend implements SrsRwkvBackend {
  _WorkerBackend(this.worker);
  final RwkvWorker worker;

  @override
  Future<void> replay(RwkvRows rows) => worker.replay(rows);
  @override
  Future<Float32List> query(RwkvRows rows) => worker.query(rows);
  @override
  Future<Uint8List> snapshot() => worker.snapshot();
  @override
  Future<void> restore(Uint8List snapshot) => worker.restore(snapshot);
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

  /// 正在加载 / 恢复快照 / 全量回放。
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

class _QueryIdentity {
  const _QueryIdentity({
    required this.lastLogId,
    required this.deckId,
    required this.ids,
    required this.last,
  });

  final String? lastLogId;
  final String deckId;

  /// 卡 / 笔记 / 牌组 / 预设的数字 id。
  final List<int> ids;
  final SrsRwkvLastRating? last;
}

/// 复习日志表的指纹：行数与最大 rowid（日志只追加，所以「只多了新行」= 行数与 rowid 同增）。
typedef _LogPrint = ({int count, int maxRowId});

class SrsRwkvService implements SrsRwkvScheduling {
  SrsRwkvService({
    required this.store,
    required this.models,
    required this.snapshotDir,
    this.threads = 0,
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

  /// 已回放的最后一条评分时刻（增量追加只接受不早于它的）。
  int? _lastAt;
  int _appendsSinceSnapshot = 0;

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

  /// 设置里「重建 RWKV 状态」：丢掉当前状态与快照，按全部复习历史重新回放。
  ///
  /// 平时不需要：作答增量追加、日志被改写时自动重建。但卡片换牌组、预设归属变化不触发重建（见
  /// 文件头「已知近似」），在那之后想让状态跟上就靠这里（对应上游的「Build Cache」）。还没准备好
  /// 时等同 [start]（force）。
  Future<void> rebuild() async {
    if (_closed) return;
    final SrsRwkvBackend? backend = _backend;
    if (backend == null || _current.phase != SrsRwkvPhase.ready) {
      await start(force: true);
      return;
    }
    _set(const SrsRwkvStatus(SrsRwkvPhase.preparing));
    await (_preparing ??= () async {
      try {
        await _rebuild(backend);
        _set(const SrsRwkvStatus(SrsRwkvPhase.ready));
      } catch (error, stack) {
        _log('RWKV rebuild failed: $error\n$stack');
        _fail(error);
      }
    }().whenComplete(() => _preparing = null));
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
      if (!restored) await _rebuild(backend);
      _set(const SrsRwkvStatus(SrsRwkvPhase.ready));
    } catch (error, stack) {
      _log('RWKV prepare failed: $error\n$stack');
      _fail(error);
    }
  }

  Future<_LogPrint> _fingerprint() async {
    final SrsRwkvLogTail t = await store.rwkvLogTail(since: 0);
    return (count: t.count, maxRowId: t.maxRowId);
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
      await backend.restore(await _snapshotFile.readAsBytes());
      _replayed = (
        count: meta['count']! as int,
        maxRowId: meta['maxRowId']! as int,
      );
      _lastAt = meta['lastAt'] as int?;
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
    final Uint8List bytes = await backend.snapshot();
    final File tmp = File('${_snapshotFile.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
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
  }

  /// 全量重建：全部卡的保留评分行由 Rust 一次取出、排好序（[SrsDbStore.rwkvReplay]），按时间回放。
  Future<void> _rebuild(SrsRwkvBackend backend) async {
    _LogPrint fingerprint = await _fingerprint();
    await debugAfterRebuildFingerprint?.call();
    final SrsDayContext day = await store.dayContext();
    final SrsDeckTree tree = await store.deckTree();
    final List<SrsCardCacheRow> cards = await store.allCardRows();
    cards.sort((SrsCardCacheRow a, SrsCardCacheRow b) => a.id.compareTo(b.id));
    // 回放行与指纹出自同一个快照：列卡之后用户还在答题也对得上，之后对齐不会把已回放的再追加、也不会因
    // 「比已回放的最后一条更早」再重建。唯一要补的是列卡之后才新建（并已作答）的卡：Rust 把它们当
    // 「漏掉的卡」报出来，补进卡表再取一次。
    SrsRwkvReplay replay = await store.rwkvReplay(
      <String>[for (final SrsCardCacheRow c in cards) c.id],
      _identities(cards, tree),
      day,
      since: fingerprint.maxRowId,
    );
    for (int round = 0; round < 5 && replay.strays.isNotEmpty; round++) {
      final Set<String> known = <String>{
        for (final SrsCardCacheRow c in cards) c.id,
      };
      bool added = false;
      for (final String id in replay.strays) {
        if (known.contains(id)) continue;
        final SrsCardCacheRow? row = await store.cardRow(id);
        if (row == null) continue;
        cards.add(row);
        added = true;
      }
      if (!added) break;
      fingerprint = (count: replay.count, maxRowId: replay.maxRowId);
      replay = await store.rwkvReplay(
        <String>[for (final SrsCardCacheRow c in cards) c.id],
        _identities(cards, tree),
        day,
        since: fingerprint.maxRowId,
      );
    }
    fingerprint = (count: replay.count, maxRowId: replay.maxRowId);
    final RwkvRows rows = replay.rows;
    _set(SrsRwkvStatus(SrsRwkvPhase.preparing, done: 0, total: rows.length));
    await _serial(() async {
      await backend.reset();
      const int block = 65536;
      final Uint8List bytes = rows.bytes;
      for (int start = 0; start < rows.length; start += block) {
        final int end = start + block > rows.length
            ? rows.length
            : start + block;
        await backend.replay(
          RwkvRows.fromBytes(
            Uint8List.sublistView(
              bytes,
              start * kFrwkvReviewSize,
              end * kFrwkvReviewSize,
            ),
          ),
        );
        _set(
          SrsRwkvStatus(SrsRwkvPhase.preparing, done: end, total: rows.length),
        );
      }
      _replayed = fingerprint;
      _lastAt = replay.lastAt;
      await _saveSnapshot(backend);
    });
  }

  /// 卡缓存行 → 数字身份（53 位 hash，与 Anki 导出同一套），每卡 4 个：卡 / 笔记 / 牌组 / 预设（= 参数归属牌组）。
  List<int> _identities(List<SrsCardCacheRow> rows, SrsDeckTree tree) =>
      SrsIds.ankiNumericIds(<String>[
        for (final SrsCardCacheRow c in rows) ...<String>[
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

  /// 对齐日志：只多了能追加的新评分 → 追加，返回 true（状态是最新的）；需要全量重建时在后台
  /// 启动重建并返回 false（调用方这次不用 RWKV，不等几秒到几十秒的重建）。串行：作答与预览可能
  /// 同时调用，同一条日志只能追加一次。
  Future<bool> refresh() {
    final Future<bool> result = _refreshQueue.then((_) => _refreshOnce());
    _refreshQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _refreshOnce() async {
    final SrsRwkvBackend? backend = _backend;
    final _LogPrint? replayed = _replayed;
    if (_closed ||
        backend == null ||
        replayed == null ||
        _current.phase != SrsRwkvPhase.ready) {
      return false;
    }
    // 先比 store 的内存修订号（零成本）：没变就不必扫日志表（每张卡出题都会走到这里）。
    final String revision = await store.changeFingerprint();
    if (revision == _checkedRevision) return true;
    // 作答不等这里（`SrsDbStore.answer` 里 unawaited 的 onAnswered）：对齐途中用户可能又答了
    // 一题，读到的日志就比指纹新。这时按新指纹再对一次，而不是当成「历史被改写」去全量重建
    // ——连续答题时那样会一直退回「RWKV 还没准备好」。
    for (int attempt = 0; attempt < 5; attempt++) {
      final _LogPrint done = _replayed!;
      // 指纹与「已回放之后的新行数」必须是同一时刻的快照：分两条语句查，中间夹进一次作答
      // （作答不等对齐），新行数就比指纹多一条，被误判成「历史被改写」去全量重建。
      final (_LogPrint now, int newRows) = await _fingerprintSince(
        done.maxRowId,
      );
      if (now == done) {
        _checkedRevision = revision;
        return true;
      }
      if (now.maxRowId <= done.maxRowId || now.count - done.count != newRows) {
        break;
      }
      final bool? appended = await _appendNew(backend, done.maxRowId, now);
      if (appended == null) continue;
      if (!appended) break;
      _checkedRevision = revision;
      return true;
    }
    _set(const SrsRwkvStatus(SrsRwkvPhase.preparing));
    _preparing ??= () async {
      try {
        await _rebuild(backend);
        _set(const SrsRwkvStatus(SrsRwkvPhase.ready));
      } catch (error, stack) {
        _log('RWKV rebuild failed: $error\n$stack');
        _fail(error);
      }
    }().whenComplete(() => _preparing = null);
    return false;
  }

  /// [_fingerprint] 连同 rowid 在 [afterRowId] 之后的行数，一条语句（同一个快照）取出。
  Future<(_LogPrint, int)> _fingerprintSince(int afterRowId) async {
    final SrsRwkvLogTail t = await store.rwkvLogTail(since: afterRowId);
    return ((count: t.count, maxRowId: t.maxRowId), t.newRows);
  }

  /// rowid 之后的日志若全是评分、都不早于已回放的最后一条、且各是其卡末尾的保留评分，
  /// 按时刻追加并返回 true；否则不动状态、返回 false。读的途中日志表又变了（指纹不再是 [now]）
  /// 返回 null，调用方按新指纹重来。
  Future<bool?> _appendNew(
    SrsRwkvBackend backend,
    int afterRowId,
    _LogPrint now,
  ) async {
    final SrsRwkvLogTail tail = await store.rwkvLogTail(
      since: afterRowId,
      withRows: true,
    );
    if ((count: tail.count, maxRowId: tail.maxRowId) != now) return null;
    final List<SrsRwkvTailLog> rows = tail.logs;
    if (rows.any(
      (SrsRwkvTailLog r) => !r.isReview || (_lastAt != null && r.at < _lastAt!),
    )) {
      return false;
    }
    // 同一张卡可能来了多条（两次对齐之间学习步「重来」后又答了一次）：按卡一次算出它末尾这几条
    // 的行，再按全局时间顺序拼。以前一见到同卡多条就全量重建，复习中会反复退回「RWKV 还没准备好」。
    final Map<String, List<String>> idsByCard = <String, List<String>>{};
    for (final SrsRwkvTailLog r in rows) {
      (idsByCard[r.cardId] ??= <String>[]).add(r.id);
    }
    final SrsDayContext day = await store.dayContext();
    final SrsDeckTree tree = await store.deckTree();
    final List<SrsCardCacheRow> cardRows = <SrsCardCacheRow>[];
    for (final String cardId in idsByCard.keys) {
      final SrsCardCacheRow? row = await store.cardRow(cardId);
      if (row == null) return false;
      cardRows.add(row);
    }
    final List<SrsRwkvCardRows> cards = await store.rwkvCardRows(
      <String>[for (final SrsCardCacheRow c in cardRows) c.id],
      _identities(cardRows, tree),
      day,
    );
    // 取完再核对：取的途中又写进了日志，取到的行就比 [now] 新，按新指纹重来。
    if (await _fingerprint() != now) return null;
    final Map<String, RwkvRows> rowOf = <String, RwkvRows>{};
    for (int k = 0; k < cardRows.length; k++) {
      final List<String> ids = idsByCard[cardRows[k].id]!;
      final List<RwkvRows>? appended = cards[k].appendRows(ids);
      if (appended == null) return false;
      for (int i = 0; i < ids.length; i++) {
        rowOf[ids[i]] = appended[i];
      }
    }
    final RwkvRows batch = RwkvRows(rows.length);
    for (final SrsRwkvTailLog r in rows) {
      batch.addRows(rowOf[r.id]!);
    }
    await _serial(() async {
      await backend.replay(batch);
      _replayed = now;
      _lastAt = rows.isEmpty ? _lastAt : rows.last.at;
      _appendsSinceSnapshot += rows.length;
      if (_appendsSinceSnapshot >= 50) await _saveSnapshot(backend);
    });
    return true;
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
      await _refreshQueryIdentities(cards);
      final SrsDayContext day = await store.dayContext();
      final RwkvRows rows = srsRwkvNowRows(
        <SrsRwkvNowCard>[
          for (final _QueryIdentity q in <_QueryIdentity>[
            for (final SrsRwkvCandidate c in cards) _queryIdentities[c.id]!,
          ])
            (
              cardId: q.ids[0],
              noteId: q.ids[1],
              deckId: q.ids[2],
              presetId: q.ids[3],
              last: q.last,
              queue: SrsQueue.review,
            ),
        ],
        nowMs: nowMs,
        day: day,
      );
      final Float32List r = await _serial(() => backend.query(rows));
      return <double>[for (final double v in r) v];
    } catch (error, stack) {
      // 例如本机时钟早于已回放的最后一条评分（对端设备时钟超前）：这一次按到期日排。
      _log('RWKV instant retrievability unavailable: $error\n$stack');
      return null;
    }
  }

  /// 每张候选卡的数字身份与最后保留评分（[SrsRwkvLastRating]）：只为第一次见到、换了牌组或
  /// 最后一条有效日志变了的卡读历史（一次作答后只剩那一张）。
  final Map<String, _QueryIdentity> _queryIdentities =
      <String, _QueryIdentity>{};

  Future<void> _refreshQueryIdentities(List<SrsRwkvCandidate> cards) async {
    bool current(SrsRwkvCandidate c) {
      final _QueryIdentity? q = _queryIdentities[c.id];
      return q != null && q.lastLogId == c.lastLogId && q.deckId == c.deckId;
    }

    final List<SrsRwkvCandidate> stale = cards
        .where((SrsRwkvCandidate c) => !current(c))
        .toList();
    if (stale.isEmpty) return;
    final SrsDeckTree tree = await store.deckTree();
    final SrsDayContext day = await store.dayContext();
    for (int at = 0; at < stale.length; at += 500) {
      final List<SrsRwkvCandidate> chunk = stale.sublist(
        at,
        min(at + 500, stale.length),
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
        final SrsRwkvCandidate c = chunk[i];
        _queryIdentities[c.id] = _QueryIdentity(
          lastLogId: c.lastLogId,
          deckId: c.deckId,
          ids: numeric.sublist(4 * i, 4 * i + 4),
          last: kept[i].last,
        );
      }
    }
  }

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {
    if (_current.phase != SrsRwkvPhase.ready) return;
    // 本机这条与对端同步来的都在日志表里：统一按指纹对齐（追加或后台重建）。
    await refresh();
  }

  /// 换模型 / 退出：存快照、关 worker。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final SrsRwkvBackend? backend = _backend;
    if (backend != null) {
      try {
        if (_current.phase == SrsRwkvPhase.ready && _appendsSinceSnapshot > 0) {
          await _serial(() => _saveSnapshot(backend));
        }
      } finally {
        await backend.close();
      }
    }
    await _status.close();
  }
}
