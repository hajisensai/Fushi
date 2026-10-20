/// RWKV 排程服务：维护「整个 collection 的复习历史回放进 RWKV」这份状态，并在作答时给出间隔。
///
/// - 状态由后台 isolate 里的原生 runtime 持有（[RwkvWorker]）；本类只发粗粒度命令。
/// - **增量**：本机作答后追加这一条（[onAnswered]）；对端同步来的新评分若都在已回放的最后一条之后，
///   也只追加。其余变化（撤销、重置、学习序列重启、插进历史中间的旧日志）→ 后台全量重建。
/// - **快照缓存**：重建完与关闭时把状态写到磁盘，按（模型、精度、日志指纹）命中；下次启动只需追加
///   之后的新日志。
/// - 没准备好（权重没下载 / 正在重建 / 出错）时 [intervalsFor] 返回 null，调用方按 FSRS 排这一次
///   并在界面上说明（`SrsAnswerPreview.rwkvUnavailable`）。
///
/// 已知近似：卡片换牌组、预设归属变化不触发重建（上游 kuma3 把它们当改写历史）；这类变化在下次
/// 全量重建（日志指纹变了、快照失效、换模型）时才进入状态。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_history.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

export 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';

/// 后台 runtime 的命令面（生产实现是 [RwkvWorker]；测试可替换）。
abstract interface class SrsRwkvBackend {
  Future<void> replay(RwkvRows rows);
  Future<RwkvIntervals> nextIntervals(
    RwkvRows answer, {
    required double targetRetention,
    required int maxIntervalDays,
  });
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
  Future<RwkvIntervals> nextIntervals(
    RwkvRows answer, {
    required double targetRetention,
    required int maxIntervalDays,
  }) => worker.nextIntervals(
    answer,
    targetRetention: targetRetention,
    maxIntervalDays: maxIntervalDays,
  );
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

  /// 所选模型的权重没下载。
  needsModel,

  /// 正在加载 / 恢复快照 / 全量回放。
  preparing,

  /// 可以排程。
  ready,

  /// 出错（[SrsRwkvStatus.error]）；下次需要时重试。
  failed,
}

class SrsRwkvStatus {
  const SrsRwkvStatus(
    this.phase, {
    this.replayed = 0,
    this.total = 0,
    this.error,
  });

  final SrsRwkvPhase phase;

  /// 全量回放进度（条）。
  final int replayed;
  final int total;
  final Object? error;
}

/// `srs_review_logs` 的指纹：行数与最大 rowid（日志只追加，所以「只多了新行」= 行数与 rowid 同增）。
typedef _LogPrint = ({int count, int maxRowId});

class SrsRwkvService implements SrsRwkvScheduling {
  SrsRwkvService({
    required this.store,
    required this.models,
    required this.choice,
    required this.snapshotDir,
    this.threads = 0,
    Future<SrsRwkvBackend> Function(File weights, SrsRwkvModelChoice choice)?
    openBackend,
    void Function(String message)? log,
  }) : _open = openBackend ?? _openWorker,
       _log = log ?? ((String _) {});

  final SrsDbStore store;
  final SrsRwkvModels models;
  final SrsRwkvModelChoice choice;

  /// 快照缓存目录。
  final Directory snapshotDir;

  /// 原生线程数：0 = 全部核心。
  final int threads;
  final Future<SrsRwkvBackend> Function(File weights, SrsRwkvModelChoice choice)
  _open;
  final void Function(String message) _log;

  static Future<SrsRwkvBackend> _openWorker(
    File weights,
    SrsRwkvModelChoice choice,
  ) async => _WorkerBackend(
    await RwkvWorker.spawn(
      modelPath: weights.path,
      precision: choice == SrsRwkvModelChoice.small
          ? RwkvPrecision.int4
          : RwkvPrecision.int8,
    ),
  );

  SrsRwkvBackend? _backend;
  _LogPrint? _replayed;

  /// 已回放的最后一条评分时刻（增量追加只接受不早于它的）。
  int? _lastAt;
  int _appendsSinceSnapshot = 0;
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

  String get _modelKey =>
      '${choice.wire}-${choice == SrsRwkvModelChoice.small ? 'int4' : 'int8'}';
  File get _snapshotFile => File(
    p.join(snapshotDir.path, 'rwkv-${store.profileUid}-$_modelKey.snap'),
  );
  File get _snapshotMeta => File('${_snapshotFile.path}.json');

  /// 开始准备（下载好权重之后调用；已在准备时什么都不做，已就绪时只对齐日志）。
  Future<void> start() async {
    if (_closed) return;
    if (_current.phase == SrsRwkvPhase.ready) {
      await refresh();
      return;
    }
    await (_preparing ??= _prepare().whenComplete(() => _preparing = null));
  }

  Future<void> _prepare() async {
    if (!models.isReady(choice)) {
      _set(const SrsRwkvStatus(SrsRwkvPhase.needsModel));
      return;
    }
    _set(const SrsRwkvStatus(SrsRwkvPhase.preparing));
    try {
      final SrsRwkvBackend backend = _backend ??= await _open(
        models.weightsFile(choice),
        choice,
      );
      final bool restored = await _serial(() => _restoreSnapshot(backend));
      if (!restored) await _rebuild(backend);
      _set(const SrsRwkvStatus(SrsRwkvPhase.ready));
    } catch (error, stack) {
      _log('RWKV prepare failed: $error\n$stack');
      _set(SrsRwkvStatus(SrsRwkvPhase.failed, error: error));
    }
  }

  Future<_LogPrint> _fingerprint() async {
    final row = await store.db
        .customSelect(
          'SELECT COUNT(*) AS c, COALESCE(MAX(rowid), 0) AS m FROM srs_review_logs WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(store.profileUid)],
        )
        .getSingle();
    return (count: row.read<int>('c'), maxRowId: row.read<int>('m'));
  }

  Future<bool> _restoreSnapshot(SrsRwkvBackend backend) async {
    if (!await _snapshotFile.exists() || !await _snapshotMeta.exists())
      return false;
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

  /// 全量重建：读全部卡的有效历史，按时间回放。
  Future<void> _rebuild(SrsRwkvBackend backend) async {
    final _LogPrint fingerprint = await _fingerprint();
    final SrsDayContext day = await store.dayContext();
    final SrsDeckTree tree = await store.deckTree();
    final List<SrsCardCacheRow> cards = await (store.db.select(
      store.db.srsCardsCache,
    )..where((c) => c.profileUid.equals(store.profileUid))).get();
    cards.sort((SrsCardCacheRow a, SrsCardCacheRow b) => a.id.compareTo(b.id));
    final SrsRwkvReplayBuilder builder = SrsRwkvReplayBuilder(day);
    const int chunk = 2000;
    for (int i = 0; i < cards.length; i += chunk) {
      final List<SrsCardCacheRow> part = cards.sublist(
        i,
        i + chunk > cards.length ? cards.length : i + chunk,
      );
      final Map<String, SrsCardHistory> histories = await store.histories(
        part.map((SrsCardCacheRow c) => c.id),
      );
      for (final SrsRwkvCard card in _identities(part, histories, tree)) {
        builder.addCard(card);
      }
      _set(
        SrsRwkvStatus(
          SrsRwkvPhase.preparing,
          replayed: 0,
          total: builder.length,
        ),
      );
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
          SrsRwkvStatus(
            SrsRwkvPhase.preparing,
            replayed: end,
            total: rows.length,
          ),
        );
      }
      _replayed = fingerprint;
      _lastAt = lastAt;
      await _saveSnapshot(backend);
    });
  }

  /// 卡缓存行 + 历史 → 数字身份（53 位 hash，与 Anki 导出同一套），预设 = 参数归属牌组。
  List<SrsRwkvCard> _identities(
    List<SrsCardCacheRow> rows,
    Map<String, SrsCardHistory> histories,
    SrsDeckTree tree,
  ) {
    final List<String> ids = <String>[];
    for (final SrsCardCacheRow c in rows) {
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
      <SrsCardCacheRow>[row],
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
    final _LogPrint now = await _fingerprint();
    if (now == replayed) return true;
    if (now.maxRowId > replayed.maxRowId &&
        now.count - replayed.count == await _countNewRows(replayed.maxRowId) &&
        await _appendNew(backend, replayed.maxRowId, now)) {
      return true;
    }
    _set(const SrsRwkvStatus(SrsRwkvPhase.preparing));
    _preparing ??= () async {
      try {
        await _rebuild(backend);
        _set(const SrsRwkvStatus(SrsRwkvPhase.ready));
      } catch (error, stack) {
        _log('RWKV rebuild failed: $error\n$stack');
        _set(SrsRwkvStatus(SrsRwkvPhase.failed, error: error));
      }
    }().whenComplete(() => _preparing = null);
    return false;
  }

  Future<int> _countNewRows(int afterRowId) async {
    final row = await store.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM srs_review_logs WHERE profile_uid = ? AND rowid > ?',
          variables: <Variable<Object>>[
            Variable<String>(store.profileUid),
            Variable<int>(afterRowId),
          ],
        )
        .getSingle();
    return row.read<int>('c');
  }

  /// rowid 之后的日志若全是评分、都不早于已回放的最后一条、且各是其卡最后一条保留评分，
  /// 按时刻追加并返回 true；否则不动状态、返回 false。
  Future<bool> _appendNew(
    SrsRwkvBackend backend,
    int afterRowId,
    _LogPrint now,
  ) async {
    final List<({String id, String cardId, String kind, int at})>
    rows = <({String id, String cardId, String kind, int at})>[
      for (final r
          in await store.db
              .customSelect(
                'SELECT id, card_id, kind, occurred_at FROM srs_review_logs '
                'WHERE profile_uid = ? AND rowid > ? ORDER BY occurred_at, rowid',
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
        ),
    ];
    if (rows.any(
      (r) =>
          r.kind != SrsLogKind.review || (_lastAt != null && r.at < _lastAt!),
    )) {
      return false;
    }
    if (rows.map((r) => r.cardId).toSet().length != rows.length) {
      // 同一张卡来了多条：逐条追加需要每条之前的历史，交给重建。
      return false;
    }
    final SrsDayContext day = await store.dayContext();
    final RwkvRows batch = RwkvRows(rows.length);
    for (final r in rows) {
      final SrsRwkvCard? card = await _card(r.cardId);
      if (card == null) return false;
      final SrsReviewLog? log = card.history.effective
          .where((SrsReviewLog l) => l.id == r.id)
          .firstOrNull;
      if (log == null || !log.isRatingReview || log.rating == null)
        return false;
      final RwkvRows? row = srsRwkvAppendRow(card, log, day);
      if (row == null) return false;
      batch.addRows(row);
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
  Future<List<int>?> intervalsFor(
    String cardId, {
    required SrsSchedulingConfig config,
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
      final SrsRwkvCard? card = await _card(cardId);
      final SrsCardCacheRow? row = await store.cardRow(cardId);
      if (card == null || row == null) return null;
      final RwkvRows answer = srsRwkvAnswerRow(
        card,
        nowMs: nowMs,
        queue: SrsQueue.values.firstWhere(
          (SrsQueue q) => q.wire == row.queue,
          orElse: () => SrsQueue.review,
        ),
        day: await store.dayContext(),
      );
      final RwkvIntervals intervals = await _serial(
        () => backend.nextIntervals(
          answer,
          targetRetention: config.desiredRetention,
          maxIntervalDays: config.maxIntervalDays,
        ),
      );
      return intervals.days;
    } catch (error, stack) {
      // 例如本机时钟早于已回放的最后一条评分（对端设备时钟超前）：这一次按 FSRS 排。
      _log('RWKV intervals unavailable for $cardId: $error\n$stack');
      return null;
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
