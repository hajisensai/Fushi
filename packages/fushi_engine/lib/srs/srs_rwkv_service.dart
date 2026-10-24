/// RWKV 排程服务：维护「整个 collection 的复习历史回放进 RWKV」这份状态，排队时给候选复习卡打
/// 此刻的回忆率（RWKV-Instant，[instantRetrievability]）。
///
/// - 状态由后台 isolate 里的原生 runtime 持有（[RwkvWorker]）；本类只发粗粒度命令。
/// - **增量**：本机作答后追加这一条（[onAnswered]），原生侧同时记一条撤销日志；撤销最近的作答
///   （复习页 Ctrl+Z）按撤销日志原样撤回（与没回放过它逐位相同），不全量重建、也不在重建期间
///   退回 FSRS-7。对端同步来的新评分若都在已回放的最后一条之后，也只追加。其余变化（撤销更早的
///   作答、重置、学习序列重启、插进历史中间的旧日志）→ 后台全量重建。
/// - **常驻分数表**（上游 JSchoreels/anki 的 per-deck 分数表 + 预测记忆化，状态在原生侧）：排队时
///   每张候选卡的 R 按（卡、最后一条有效日志、牌组、预设）记在原生分数表里；作答 / 撤销只作废
///   同一张卡与同一条笔记的项，下一次排队只重算这几张。牌组 / 预设 / 全局状态被别的卡的作答带动
///   的变化不逐卡追：换日、距上次全量刷新满 [_requeryAfter] 或 [_requeryEveryPatches] 次增量、
///   牌组设置变化、同步合并后（[SrsDbStore.rwkvScoresKey]）整表按此刻重查一遍（原生侧改写查询行，
///   不回读历史）；日界设置变化时清空重建。增量与全量走同一个原生查询，每行的 R 不取决于同批
///   别的行，逐位一致（native/fushi_rwkv/tests/journal.rs）。
/// - **快照缓存**：重建完、空闲 [_snapshotIdle] 后与关闭时把状态写到磁盘，按（模型、精度、日志
///   指纹）命中；下次启动只需追加快照之后的新日志。
/// - 没准备好（权重没下载 / 正在重建 / 出错）时 [instantRetrievability] 返回 null，调用方按存下的
///   到期日排队并在界面上说明（`SrsAnswerPreview.rwkvUnavailable`）。
///
/// 已知近似：卡片换牌组、预设归属变化不触发重建（上游 kuma3 把它们当改写历史）；这类变化在下次
/// 全量重建（日志指纹变了、快照失效、换模型）时才进入状态。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_history.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

export 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

/// 后台 runtime 的命令面（生产实现是 [RwkvWorker]；测试可替换）。
abstract interface class SrsRwkvBackend {
  Future<void> replay(RwkvRows rows);

  /// 追加并记撤销日志（标签与行同序）。false = 模型不支持撤销日志，行已按普通回放追加。
  Future<bool> append(RwkvRows rows, List<int> tags);

  /// 撤回最近一条 [append]（仅当标签是 [tag]）；false = 不是它，什么都没改。
  Future<bool> unappend(int tag);

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
  Future<bool> append(RwkvRows rows, List<int> tags) =>
      worker.append(rows, tags);
  @override
  Future<bool> unappend(int tag) => worker.unappend(tag);
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

/// `srs_review_logs` 的指纹：行数与最大 rowid（日志只追加，所以「只多了新行」= 行数与 rowid 同增）。
typedef _LogPrint = ({int count, int maxRowId});

/// 新日志表里的一行（[SrsRwkvService._appendNew]）。
typedef _NewLog = ({
  String id,
  String cardId,
  String kind,
  int at,
  String? revokes,
});

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

  /// 测试钩子：全量重建记下日志指纹之后、开始读历史之前调用（模拟用户在重建途中答题）。
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

  /// 已回放的最后一条评分时刻（增量追加只接受不早于它的）。撤回一条后不往回退（保守：之后
  /// 同步来的、早于被撤回那条的评分照样触发全量重建）。
  int? _lastAt;
  int _appendsSinceSnapshot = 0;

  /// 有新的追加 / 撤回、还没写进快照时，空闲这么久后存一次（以前每 50 次作答整份导出写盘，
  /// 快照几十到几百 MB）。关闭时也存。
  static const Duration _snapshotIdle = Duration(minutes: 2);
  Timer? _snapshotTimer;

  /// 上次全量对日志表计数时的 [SrsDbStore.contentFingerprint]：没变时日志只可能新增（复习日志
  /// 不推进内容修订号；删日志的清除、恢复、重读本机状态都推进），行数按新增的行累加，不必每次
  /// 作答都 `COUNT(*)` 整个 profile。
  String? _countedAt;

  /// 分数表的全量刷新状态（见文件头）。
  String? _scoresClearKey;
  String? _scoresRequeryKey;
  int? _scoresToday;
  int _scoresAt = 0;
  int _patchesSinceRequery = 0;
  static const Duration _requeryAfter = Duration(minutes: 30);
  static const int _requeryEveryPatches = 50;

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

  /// 日志表指纹。[_replayed] 已知、且上次全量计数之后内容修订号没变（没删过日志）时，只数
  /// rowid 之后的新行（`+profile_uid` 让 SQLite 走 rowid 范围，O(新增)）；否则整表计数一次。
  Future<_LogPrint> _fingerprint() async {
    final _LogPrint? base = _replayed;
    final String content = store.contentFingerprint;
    if (base != null && _countedAt == content) {
      final row = await store.db
          .customSelect(
            'SELECT COUNT(*) AS c, COALESCE(MAX(rowid), 0) AS m FROM srs_review_logs '
            'WHERE rowid > ? AND +profile_uid = ?',
            variables: <Variable<Object>>[
              Variable<int>(base.maxRowId),
              Variable<String>(store.profileUid),
            ],
          )
          .getSingle();
      final int added = row.read<int>('c');
      return (
        count: base.count + added,
        maxRowId: added == 0 ? base.maxRowId : row.read<int>('m'),
      );
    }
    final row = await store.db
        .customSelect(
          'SELECT COUNT(*) AS c, COALESCE(MAX(rowid), 0) AS m FROM srs_review_logs WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(store.profileUid)],
        )
        .getSingle();
    _countedAt = content;
    return (count: row.read<int>('c'), maxRowId: row.read<int>('m'));
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
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
  }

  /// 有未存的追加 / 撤回：空闲 [_snapshotIdle] 后存快照（期间再有作答就顺延）。
  void _scheduleSnapshot(SrsRwkvBackend backend) {
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(_snapshotIdle, () {
      _snapshotTimer = null;
      if (_closed || _appendsSinceSnapshot == 0) return;
      unawaited(
        _serial(() => _saveSnapshot(backend)).catchError((Object error) {
          _log('RWKV snapshot save failed: $error');
        }),
      );
    });
  }

  /// 全量重建：读全部卡的有效历史，按时间回放。
  Future<void> _rebuild(SrsRwkvBackend backend) async {
    _LogPrint fingerprint = await _fingerprint();
    await debugAfterRebuildFingerprint?.call();
    final SrsDayContext day = await store.dayContext();
    final SrsDeckTree tree = await store.deckTree();
    final List<_CardKey> cards = <_CardKey>[
      for (final QueryRow r
          in await store.db
              .customSelect(
                'SELECT id, note_id, deck_id FROM srs_cards_cache '
                'WHERE profile_uid = ? ORDER BY id',
                variables: <Variable<Object>>[
                  Variable<String>(store.profileUid),
                ],
              )
              .get())
        (
          id: r.read<String>('id'),
          noteId: r.read<String>('note_id'),
          deckId: r.read<String>('deck_id'),
        ),
    ];
    final SrsRwkvReplayBuilder builder = SrsRwkvReplayBuilder(day);
    const int chunk = 2000;
    for (int i = 0; i < cards.length; i += chunk) {
      final List<_CardKey> part = cards.sublist(
        i,
        i + chunk > cards.length ? cards.length : i + chunk,
      );
      final Map<String, SrsCardHistory> histories = await store.histories(
        part.map((_CardKey c) => c.id),
      );
      for (final SrsRwkvCard card in _identities(part, histories, tree)) {
        builder.addCard(card);
      }
      _set(
        SrsRwkvStatus(SrsRwkvPhase.preparing, done: 0, total: builder.length),
      );
    }
    // 分块读历史要一段时间（大收藏几秒到几十秒），用户多半正停在复习页上继续答题：读到的历史
    // 有的含这些新评分、有的不含，与开头的指纹对不上。之后对齐时它们会比已回放的最后一条还早，
    // 又触发全量重建——边答边重建，一直显示「RWKV 还没准备好」。所以读完核对指纹：这期间有新
    // 日志的卡丢掉已加入的行、按最新历史重读，直到指纹不再变。
    for (int round = 0; round < 5; round++) {
      final _LogPrint after = await _fingerprint();
      if (after == fingerprint) break;
      final List<String> changed = await _cardsWithLogsAfter(
        fingerprint.maxRowId,
      );
      fingerprint = after;
      final List<_CardKey> part = <_CardKey>[
        for (final String id in changed)
          if (await store.cardRow(id) case final SrsCardCacheRow c)
            (id: c.id, noteId: c.noteId, deckId: c.deckId),
      ];
      final List<SrsRwkvCard> fresh = _identities(
        part,
        await store.histories(part.map((_CardKey c) => c.id)),
        tree,
      );
      builder.dropCards(<int>{for (final SrsRwkvCard c in fresh) c.cardId});
      fresh.forEach(builder.addCard);
    }
    final (RwkvRows rows, int? lastAt) = builder.build();
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
      _lastAt = lastAt;
      await _saveSnapshot(backend);
    });
  }

  /// 卡缓存行 + 历史 → 数字身份（53 位 hash，与 Anki 导出同一套），预设 = 参数归属牌组。
  List<SrsRwkvCard> _identities(
    List<_CardKey> rows,
    Map<String, SrsCardHistory> histories,
    SrsDeckTree tree,
  ) {
    final List<String> ids = <String>[];
    for (final _CardKey c in rows) {
      ids
        ..add(c.id)
        ..add(c.noteId)
        ..add(c.deckId)
        ..add(_presetOf(tree, c.deckId));
    }
    final List<int> numeric = SrsIds.ankiNumericIds(ids);
    return <SrsRwkvCard>[
      for (int i = 0; i < rows.length; i++)
        if (histories[rows[i].id] case final SrsCardHistory history)
          SrsRwkvCard(
            cardId: numeric[4 * i],
            noteId: numeric[4 * i + 1],
            deckId: numeric[4 * i + 2],
            presetId: numeric[4 * i + 3],
            history: history,
          ),
    ];
  }

  static String _presetOf(SrsDeckTree tree, String deckId) {
    try {
      return tree.paramsOwner(deckId).id;
    } on Object {
      return deckId;
    }
  }

  Future<SrsRwkvCard?> _card(String cardId) async {
    final SrsCardCacheRow? row = await store.cardRow(cardId);
    if (row == null) return null;
    final SrsDeckTree tree = await store.deckTree();
    final List<SrsRwkvCard> cards = _identities(
      <_CardKey>[(id: row.id, noteId: row.noteId, deckId: row.deckId)],
      <String, SrsCardHistory>{cardId: await store.history(cardId)},
      tree,
    );
    return cards.single;
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
    for (int attempt = 0; attempt < 10; attempt++) {
      final _LogPrint done = _replayed!;
      final _LogPrint now = await _fingerprint();
      if (now == done) {
        _checkedRevision = revision;
        return true;
      }
      // 没有新行而指纹变了 = 删过日志：改写了历史。
      if (now.maxRowId <= done.maxRowId) break;
      // 新增行数与行数差对不上：要么删过日志，要么两次查询之间又落了新作答（连续快速作答时
      // 常见）——重来一次；一直对不上（真删过）时尝试用完，全量重建。
      if (now.count - done.count != await _countNewRows(done.maxRowId)) {
        continue;
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

  Future<List<String>> _cardsWithLogsAfter(int afterRowId) async => <String>[
    for (final r
        in await store.db
            .customSelect(
              'SELECT DISTINCT card_id FROM srs_review_logs WHERE +profile_uid = ? AND rowid > ?',
              variables: <Variable<Object>>[
                Variable<String>(store.profileUid),
                Variable<int>(afterRowId),
              ],
            )
            .get())
      r.read<String>('card_id'),
  ];

  Future<int> _countNewRows(int afterRowId) async {
    final row = await store.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM srs_review_logs WHERE +profile_uid = ? AND rowid > ?',
          variables: <Variable<Object>>[
            Variable<String>(store.profileUid),
            Variable<int>(afterRowId),
          ],
        )
        .getSingle();
    return row.read<int>('c');
  }

  /// rowid 之后的新日志若只有评分与撤销、评分都不早于已回放的最后一条且各是其卡末尾的保留评分、
  /// 撤销撤的都是撤销日志里最近的那几条（复习页的 Ctrl+Z），就按时间顺序追加 / 撤回并返回 true；
  /// 否则返回 false（调用方全量重建；中途失败时状态可能已改了一半，重建会先 reset）。读的途中
  /// 日志表又变了（指纹不再是 [now]）返回 null，调用方按新指纹重来。
  Future<bool?> _appendNew(
    SrsRwkvBackend backend,
    int afterRowId,
    _LogPrint now,
  ) async {
    final List<_NewLog> fetched = <_NewLog>[
      for (final r
          in await store.db
              .customSelect(
                'SELECT id, card_id, kind, occurred_at, '
                "CASE WHEN kind = 'undo' THEN json END AS j FROM srs_review_logs "
                'WHERE +profile_uid = ? AND rowid > ? ORDER BY occurred_at, rowid',
                variables: <Variable<Object>>[
                  Variable<String>(store.profileUid),
                  Variable<int>(afterRowId),
                ],
              )
              .get())
        (
          id: r.read<String>('id'),
          cardId: r.read<String>('card_id'),
          kind: r.read<String>('kind'),
          at: r.read<int>('occurred_at'),
          revokes: switch (r.read<String?>('j')) {
            final String j =>
              (jsonDecode(j) as Map<String, Object?>)['revokes'] as String?,
            null => null,
          },
        ),
    ];
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
    if (ratings.any((_NewLog r) => _lastAt != null && r.at < _lastAt!)) {
      return false;
    }
    // 同一张卡可能来了多条（两次对齐之间学习步「重来」后又答了一次）：按卡一次算出它末尾这几条
    // 的行，再按全局时间顺序拼。以前一见到同卡多条就全量重建，复习中会反复退回「RWKV 还没准备好」。
    final Map<String, List<String>> idsByCard = <String, List<String>>{};
    for (final _NewLog r in ratings) {
      (idsByCard[r.cardId] ??= <String>[]).add(r.id);
    }
    final SrsDayContext day = await store.dayContext();
    final Map<String, SrsRwkvCard> cardOf = <String, SrsRwkvCard>{};
    for (final String cardId in idsByCard.keys) {
      final SrsRwkvCard? card = await _card(cardId);
      if (card == null) return false;
      cardOf[cardId] = card;
    }
    // 历史读完再核对：读的途中又写进了日志，读到的历史就比 [now] 新，按新指纹重来。
    if (await _fingerprint() != now) return null;
    final Map<String, RwkvRows> rowOf = <String, RwkvRows>{};
    for (final MapEntry<String, List<String>> e in idsByCard.entries) {
      final SrsRwkvCard card = cardOf[e.key]!;
      for (final String id in e.value) {
        final SrsReviewLog? log = card.history.effective
            .where((SrsReviewLog l) => l.id == id)
            .firstOrNull;
        if (log == null || !log.isRatingReview || log.rating == null) {
          return false;
        }
      }
      final List<RwkvRows>? cardRows = srsRwkvAppendRows(card, e.value, day);
      if (cardRows == null) return false;
      for (int i = 0; i < e.value.length; i++) {
        rowOf[e.value[i]] = cardRows[i];
      }
    }
    final List<int> tags = SrsIds.ankiNumericIds(<String>[
      for (final _NewLog r in rows) r.revokes ?? r.id,
    ]);
    return _serial(() async {
      List<RwkvRows> pending = <RwkvRows>[];
      List<int> pendingTags = <int>[];
      Future<void> flush() async {
        if (pendingTags.isEmpty) return;
        final RwkvRows batch = RwkvRows(pending.length);
        pending.forEach(batch.addRows);
        await backend.append(batch, pendingTags);
        pending = <RwkvRows>[];
        pendingTags = <int>[];
      }

      for (int i = 0; i < rows.length; i++) {
        final _NewLog r = rows[i];
        if (r.kind == SrsLogKind.review) {
          pending.add(rowOf[r.id]!);
          pendingTags.add(tags[i]);
          continue;
        }
        await flush();
        // 撤的不是撤销日志里最近的那条（更早的作答、重启前的作答、超出日志容量）：全量重建。
        if (!await backend.unappend(tags[i])) return false;
      }
      await flush();
      _replayed = now;
      if (ratings.isNotEmpty) _lastAt = ratings.last.at;
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
      await _alignScores(backend, day, today, nowMs);
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
        // 一次增量（不是首次 / 清空后的整表建立）算一次。
        if (missing.length < cards.length) _patchesSinceRequery++;
      }
      return <double>[for (final double v in scores) v];
    } catch (error, stack) {
      // 例如本机时钟早于已回放的最后一条评分（对端设备时钟超前）：这一次按到期日排。
      _log('RWKV instant retrievability unavailable: $error\n$stack');
      return null;
    }
  }

  /// 分数表的全量刷新时机（见文件头）：日界设置 / 本机状态纪元变了 → 清空（之后按历史重算）；
  /// 换日、牌组设置或同步合并（[SrsDbStore.rwkvScoresKey]）、满 [_requeryAfter] 或
  /// [_requeryEveryPatches] 次增量（一次排队补算了几张卡算一次）→ 原生侧按此刻整表重查。
  Future<void> _alignScores(
    SrsRwkvBackend backend,
    SrsDayContext day,
    int today,
    int nowMs,
  ) async {
    final String clearKey =
        '${store.rwkvScoresClearKey}|${day.utcOffsetMin}|${day.rolloverHour}';
    final String requeryKey = store.rwkvScoresKey;
    if (clearKey != _scoresClearKey) {
      await _serial(backend.clearScores);
    } else if (requeryKey != _scoresRequeryKey ||
        today != _scoresToday ||
        nowMs - _scoresAt >= _requeryAfter.inMilliseconds ||
        nowMs < _scoresAt ||
        _patchesSinceRequery >= _requeryEveryPatches) {
      await _serial(() => backend.requeryScores(today, nowMs));
    } else {
      return;
    }
    _scoresClearKey = clearKey;
    _scoresRequeryKey = requeryKey;
    _scoresToday = today;
    _scoresAt = nowMs;
    _patchesSinceRequery = 0;
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
    final RwkvRows rows = RwkvRows(cards.length);
    final Int64List anchors = Int64List(cards.length);
    for (int at = 0; at < cards.length; at += 500) {
      final List<SrsRwkvCandidate> chunk = cards.sublist(
        at,
        min(at + 500, cards.length),
      );
      final Map<String, SrsCardHistory> histories = await store.histories(
        chunk.map((SrsRwkvCandidate c) => c.id),
      );
      final List<int> numeric = SrsIds.ankiNumericIds(<String>[
        for (final SrsRwkvCandidate c in chunk) ...<String>[
          c.id,
          c.noteId,
          c.deckId,
          _presetOf(tree, c.deckId),
        ],
      ]);
      for (int i = 0; i < chunk.length; i++) {
        final SrsCardHistory? history = histories[chunk[i].id];
        final SrsRwkvLastRating? last = history == null
            ? null
            : SrsRwkvLastRating.of(history);
        anchors[at + i] = last?.at ?? -1;
        srsRwkvAddNowRow(
          rows,
          cardId: numeric[4 * i],
          noteId: numeric[4 * i + 1],
          deckId: numeric[4 * i + 2],
          presetId: numeric[4 * i + 3],
          last: last,
          queue: SrsQueue.review,
          nowMs: nowMs,
          day: day,
        );
      }
    }
    return _serial(() => backend.updateScores(rows, versions, anchors));
  }

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {
    if (_current.phase != SrsRwkvPhase.ready) return;
    // 本机这条与对端同步来的都在日志表里：统一按指纹对齐（追加 / 撤回，或后台重建）。
    await refresh();
  }

  /// 换模型 / 退出：存快照、关 worker。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
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

/// 全量重建读卡缓存时只要的三列。
typedef _CardKey = ({String id, String noteId, String deckId});
