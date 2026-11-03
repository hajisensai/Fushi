/// 只拉不发的一轮（BUG-4005）：本机旧库迁移之前、档案合并之前，先把同步位置上别的设备已有的操作收进来。
///
/// - 迁移只包还没有任何设备的操作代表的旧行（内核 native/fushi_fsrs/src/store/sync2/mod.rs `enqueue_legacy_rows`）：
///   第二台设备迁移同一份旧库之前先收到第一台迁出的那份，就只包自己独有的，不再造第二条重复的操作流；
/// - 档案合并沿用目标里已有的写入者（srs_profile_merge.dart `_Writers.alias`）：合并之前目标 uid 的数据得先在本机。
///
/// 只读位置：不建 `meta.json`、不写围栏 / 段 / head、不删任何东西（与 [srsSync2Round] 的握手不同：那边位置上还没有
/// 集合时会新建 `meta.json`）。本机只多了收进来的操作（与一轮同步收段同一条路径，[srsSync2Pull]）。
///
/// **有界**（[srsSync2PullWithin]）：调用方在打开 store 的路上等它，网络慢 / 卡住不能让复习页无限等。到点就关上
/// [SrsSync2PullGate]：在途的那一次内核调用做完（本地、有界），开着的收段会话放掉，之后迟到的网络结果再也碰不到
/// 本机库；已收的批次都已提交，没收到的由之后的常规同步补齐（迁移照常做，只是可能多包几条，靠收敛合并）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;

/// 打开 store 时迁移前最多等多久（首次打开复习页最多多等这么久；之后的打开已迁移，不再等）。
const Duration kSrsPullBeforeMigrateBudget = Duration(seconds: 10);

/// 档案合并前收目标 uid 的数据最多等多久（用户在冲突弹窗里选定之后的一次性操作）。
const Duration kSrsPullBeforeMergeBudget = Duration(minutes: 2);

/// [SrsSync2PullGate] 关上之后还想调内核（到点之后才回来的网络结果）。
class SrsSync2PullClosed implements Exception {
  const SrsSync2PullClosed();

  @override
  String toString() => 'SrsSync2PullClosed: pull-first budget is over';
}

/// 只拉不发：读 `meta.json`（只读握手）→ [srsSync2Pull]。位置上还没有集合 / 要更新版本 / 口令不对或缺口令时什么都不收，
/// 原因放在 [SrsSync2Report.error] / [SrsSync2Report.needsUpgrade]（集合不存在不算错）。
Future<SrsSync2Report> srsSync2PullOnly({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required int Function() nowMs,
  SrsLocationKey? key,
  bool Function()? shouldStop,
  int fetchConcurrency = kSrsSync2Concurrency,
}) async {
  final SrsSync2Report report = SrsSync2Report();
  await host.sync2Command(<String, Object?>{'op': 'identity', 'now': nowMs()});
  final Uint8List? bytes = await location.get('meta.json');
  if (bytes == null) return report;
  final Map<String, Object?> meta;
  try {
    final Object? j = jsonDecode(utf8.decode(bytes));
    if (j is! Map) throw const FormatException('meta.json is not an object');
    meta = j.cast<String, Object?>();
  } on FormatException {
    return report..error = kSrsSync2MetaUnavailable;
  }
  if (((meta['minReader'] as num?)?.toInt() ?? 1) > kSrsSync2Protocol) {
    return report..needsUpgrade = true;
  }
  final Object? kdf = meta['kdf'];
  String? keyHex;
  if (kdf is Map) {
    if (key == null) return report..error = kSrsSync2NeedsKey;
    if (kdf['check'] != key.check) return report..error = kSrsSync2WrongKey;
    keyHex = key.keyHex;
  } else if (kdf != null) {
    return report..error = kSrsSync2BadKdf;
  } else if (key != null && !key.pendingEnable) {
    return report..error = kSrsSync2EncryptionMissing;
  }
  report.encrypted = keyHex != null;
  await srsSync2Pull(
    host: host,
    location: location,
    progressId: srsLocationProgressId(locationId, keyHex),
    keyHex: keyHex,
    report: report,
    shouldStop: shouldStop,
    fetchConcurrency: fetchConcurrency,
  );
  return report;
}

/// 把 [inner] 包起来交给有界的拉取：[close] 之后任何调用都抛 [SrsSync2PullClosed]。
class SrsSync2PullGate implements SrsSync2Host {
  SrsSync2PullGate(this._inner);

  final SrsSync2Host _inner;
  bool _closed = false;
  bool _session = false;
  final Set<Future<void>> _inFlight = <Future<void>>{};

  bool get isClosed => _closed;

  @override
  String get profileUid => _inner.profileUid;

  Future<T> _call<T>(Future<T> Function() body) {
    if (_closed) return Future<T>.error(const SrsSync2PullClosed());
    final Future<T> f = body();
    final Future<void> done = f.then((T _) {}, onError: (Object _) {});
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
    return f;
  }

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) => _call(() => _inner.sync2Command(request, blobs: blobs));

  @override
  Future<void> sync2IngestBegin() => _call(() async {
    await _inner.sync2IngestBegin();
    _session = true;
  });

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) => _call(() => _inner.sync2IngestBatch(segments, keyHex: keyHex));

  @override
  Future<Map<String, Object?>> sync2IngestFinish() =>
      _call(_inner.sync2IngestFinish);

  @override
  Future<void> sync2IngestEnd() async {
    // 关上时已经放掉了会话（[close]）：迟到的收尾什么都不做。
    if (_closed) return;
    await _call(() async {
      await _inner.sync2IngestEnd();
      _session = false;
    });
  }

  /// 关上：之后的调用一律拒绝；等在途的内核调用做完，开着的收段会话放掉。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
    if (_session) {
      _session = false;
      await _inner.sync2IngestEnd();
    }
  }
}

/// 在 [budget] 之内跑 [body]（它只能经交给它的 [SrsSync2PullGate] 碰 [host]）。返回是否在期限内做完；到点没做完就
/// 关上闸门、交回 false，[body] 迟到的错误里 [SrsSync2PullClosed] 是预期的、不报，别的交给 [onError]（不吞）。
Future<bool> srsSync2PullWithin(
  SrsSync2Host host,
  Future<void> Function(SrsSync2Host gated) body, {
  required Duration budget,
  required void Function(Object error, StackTrace stack) onError,
}) async {
  final SrsSync2PullGate gate = SrsSync2PullGate(host);
  final Completer<bool> outcome = Completer<bool>();
  final Timer timer = Timer(budget, () {
    if (!outcome.isCompleted) outcome.complete(false);
  });
  unawaited(
    body(gate).then(
      (void _) {
        if (!outcome.isCompleted) outcome.complete(true);
      },
      onError: (Object e, StackTrace stack) {
        if (e is! SrsSync2PullClosed) onError(e, stack);
        if (!outcome.isCompleted) outcome.complete(true);
      },
    ),
  );
  final bool done = await outcome.future;
  timer.cancel();
  await gate.close();
  return done;
}
