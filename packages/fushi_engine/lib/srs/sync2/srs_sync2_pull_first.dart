/// 只拉不发的一轮（BUG-4011）：本机旧库迁移之前、档案合并之前，先把同步位置上别的设备已有的操作收进来。
///
/// - 迁移只包还没有任何设备的操作代表的旧行（内核 native/fushi_fsrs/src/store/sync2/mod.rs `enqueue_legacy_rows`）：
///   第二台设备迁移同一份旧库之前先收到第一台迁出的那份，就只包自己独有的，不再造第二条重复的操作流；
/// - 档案合并沿用目标里已有的写入者（srs_profile_merge.dart `_Writers.alias`）：合并之前目标 uid 的数据得先在本机。
///
/// 只读位置：不建 `meta.json`、不写围栏 / 段 / head、不删任何东西（与 [srsSync2Round] 的握手不同：那边位置上还没有
/// 集合时会新建 `meta.json`）。本机只多了收进来的操作（与一轮同步收段同一条路径，[srsSync2Pull]）。
///
/// **有界**（[srsSync2PullBounded]）：调用方（首次同步确认后的第一轮 / 档案合并）在一轮同步里等它，网络慢 / 卡住
/// 不能让这一轮无限等。旧库迁移之前按**进度**判（[SrsPullBound.progress]：还在收就一直等，停滞才放弃，另有一个
/// 很宽的总上限防挂死）；档案合并按固定时长（[SrsPullBound.budget]）。放弃时关上
/// [SrsSync2PullGate]：在途的那一次内核调用做完（本地、有界），开着的收段会话放掉，之后迟到的网络结果再也碰不到
/// 本机库；已收的批次都已提交，没收到的由之后的常规同步补齐（迁移照常做，只是可能多包几条，靠收敛合并与 Dedup）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;

/// 推迟的旧库迁移之前那轮只拉不发的**停滞判定**（app 首次同步确认后的第一轮里做一次，store 早已可用、不挡复习页；
/// 之后已迁移，不再等）：连续这么久没有任何一次进展（[srsSync2PullBounded] 的「进展」：位置上一次读取——列目录 /
/// 读文件——成功返回，或一次内核调用成功返回）就放弃、照常迁移。
///
/// 取值依据：等于旧的整段固定预算（2 分钟），即「完全卡死」时不比以前多等；两次进展之间最长是读完一个段，段的
/// 目标大小 4 MiB（内核 `SEGMENT_TARGET_BYTES`），2 分钟读完一个段只要求约 35 KB/s 的总吞吐。
const Duration kSrsPullBeforeMigrateStall = Duration(minutes: 2);

/// 推迟的旧库迁移之前那轮只拉不发的**总上限**：只防挂死（例如一个一直「有进展」却永远收不完的位置），不是正常的
/// 结束条件。取值依据：新设备收齐已有集合实测 229～413 秒，30 分钟是最慢实测的 4 倍多，给更慢的网络 / 更大的
/// 集合留余量；到上限照常迁移（重复的部分由 Dedup 操作收敛）。
const Duration kSrsPullBeforeMigrateCap = Duration(minutes: 30);

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
///
/// [onActivity]：位置上每一次读取成功返回（含「不存在」）调一次，交给 [srsSync2PullBounded] 的进度判定；
/// [onFetchProgress]：拉段进度（已收 / 要收的段数），给界面。
Future<SrsSync2Report> srsSync2PullOnly({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required int Function() nowMs,
  SrsLocationKey? key,
  bool Function()? shouldStop,
  int fetchConcurrency = kSrsSync2Concurrency,
  void Function()? onActivity,
  void Function(int done, int total)? onFetchProgress,
}) async {
  final SrsLocationStore source = onActivity == null
      ? location
      : SrsActivityLocationStore(location, onActivity);
  final SrsSync2Report report = SrsSync2Report();
  await host.sync2Command(<String, Object?>{'op': 'identity', 'now': nowMs()});
  final Uint8List? bytes = await source.get('meta.json');
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
    // 见过加密就记下（BUG-4299：之后 meta 上的 kdf 不见了也不往这里写明文）。
    SrsKdf? parsed;
    try {
      parsed = SrsKdf.fromJson(kdf.cast<String, Object?>());
    } on FormatException {
      parsed = null;
    }
    final Object? check = kdf['check'];
    await srsNoteLocationSealed(
      host,
      locationId,
      nowMs: nowMs(),
      kdf: parsed,
      check: check is String ? check : null,
      seen: parsed == null,
    );
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
    location: source,
    progressId: srsLocationProgressId(locationId, keyHex),
    keyHex: keyHex,
    report: report,
    shouldStop: shouldStop,
    fetchConcurrency: fetchConcurrency,
    onFetchProgress: onFetchProgress,
  );
  return report;
}

/// 把 [SrsLocationStore] 包一层：每一次读取（[list] / [get] / [exists]）**成功返回**就调 [onActivity]（出错不算
/// 进展）。只拉不发只读位置；写入原样转发、不计。
class SrsActivityLocationStore implements SrsLocationStore {
  SrsActivityLocationStore(this._inner, this._onActivity);

  final SrsLocationStore _inner;
  final void Function() _onActivity;

  Future<T> _read<T>(Future<T> f) => f.then((T v) {
    _onActivity();
    return v;
  });

  @override
  Future<List<SrsLocationEntry>> list(String dir) => _read(_inner.list(dir));

  @override
  Future<Uint8List?> get(String path) => _read(_inner.get(path));

  @override
  Future<bool> exists(String path) => _read(_inner.exists(path));

  @override
  Future<void> put(String path, Uint8List bytes) => _inner.put(path, bytes);

  @override
  Future<void> putNew(String path, Uint8List bytes) =>
      _inner.putNew(path, bytes);

  @override
  Future<void> delete(String path) => _inner.delete(path);
}

/// 把 [inner] 包起来交给有界的拉取：[close] 之后任何调用都抛 [SrsSync2PullClosed]。[onActivity]：每一次内核调用
/// **成功返回**调一次（进度判定，[srsSync2PullBounded]）。
class SrsSync2PullGate implements SrsSync2Host {
  SrsSync2PullGate(this._inner, {void Function()? onActivity})
    : _onActivity = onActivity;

  final SrsSync2Host _inner;
  final void Function()? _onActivity;
  bool _closed = false;
  bool _session = false;
  final Set<Future<void>> _inFlight = <Future<void>>{};

  bool get isClosed => _closed;

  @override
  String get profileUid => _inner.profileUid;

  Future<T> _call<T>(Future<T> Function() body) {
    if (_closed) return Future<T>.error(const SrsSync2PullClosed());
    final void Function()? activity = _onActivity;
    final Future<T> f = activity == null
        ? body()
        : body().then((T v) {
            activity();
            return v;
          });
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

/// 只拉不发等多久。
final class SrsPullBound {
  /// 固定时长：[total] 到点没做完就放弃（档案合并之前，[kSrsPullBeforeMergeBudget]）。
  const SrsPullBound.budget(Duration total) : stall = null, cap = total;

  /// 按进度：连续 [stall] 没有任何进展才放弃；[cap] 只是防挂死的总上限（旧库迁移之前，
  /// [kSrsPullBeforeMigrateStall] / [kSrsPullBeforeMigrateCap]）。
  const SrsPullBound.progress({
    required Duration this.stall,
    required this.cap,
  });

  /// 停滞判定；null = 不看进度，只看 [cap]。
  final Duration? stall;

  /// 总上限。
  final Duration cap;
}

/// [srsSync2PullBounded] 怎么结束的。
enum SrsPullOutcome {
  /// [srsSync2PullBounded] 的 body 自己做完了（收齐，或位置上没有可收的：没有集合 / 读不了，那时立即做完）。
  done,

  /// 按进度判：连续 [SrsPullBound.stall] 没有任何进展，放弃。
  stalled,

  /// 到了总上限 [SrsPullBound.cap]，放弃。
  capped,
}

/// 测试替换计时器用（默认 [Timer.new]）。
typedef SrsPullTimerFactory =
    Timer Function(Duration duration, void Function() callback);

/// 在 [bound] 之内跑 [body]（它只能经交给它的 [SrsSync2PullGate] 碰 [host]）。
///
/// **进展**（[SrsPullBound.stall] 非 null 时才看）：经闸门的一次内核调用成功返回，或 [body] 调了交给它的
/// `activity`（接 [srsSync2PullOnly] 的 `onActivity`：位置上一次读取成功返回）。**停滞** = 从开跑或上一次进展起
/// 连续 [SrsPullBound.stall] 没有新的进展。出错的调用 / 读取不算进展：只会出错的位置不能把等待无限续下去。
///
/// 停滞 / 到总上限就关上闸门、交回对应的 [SrsPullOutcome]；[body] 迟到的错误里 [SrsSync2PullClosed] 是预期的、
/// 不报，别的交给 [onError]（不吞）。[body] 出错也算做完（[SrsPullOutcome.done]，错误已交给 [onError]）。
Future<SrsPullOutcome> srsSync2PullBounded(
  SrsSync2Host host,
  Future<void> Function(SrsSync2Host gated, void Function() activity) body, {
  required SrsPullBound bound,
  required void Function(Object error, StackTrace stack) onError,
  SrsPullTimerFactory timer = Timer.new,
}) async {
  final Completer<SrsPullOutcome> outcome = Completer<SrsPullOutcome>();
  void finish(SrsPullOutcome o) {
    if (!outcome.isCompleted) outcome.complete(o);
  }

  final Duration? stall = bound.stall;
  Timer? stallTimer;
  void activity() {
    if (stall == null || outcome.isCompleted) return;
    stallTimer?.cancel();
    stallTimer = timer(stall, () => finish(SrsPullOutcome.stalled));
  }

  final SrsSync2PullGate gate = SrsSync2PullGate(host, onActivity: activity);
  final Timer capTimer = timer(bound.cap, () => finish(SrsPullOutcome.capped));
  activity();
  unawaited(
    body(gate, activity).then(
      (void _) => finish(SrsPullOutcome.done),
      onError: (Object e, StackTrace stack) {
        if (e is! SrsSync2PullClosed) onError(e, stack);
        finish(SrsPullOutcome.done);
      },
    ),
  );
  final SrsPullOutcome result = await outcome.future;
  capTimer.cancel();
  stallTimer?.cancel();
  await gate.close();
  return result;
}

/// 在 [budget] 之内跑 [body]（固定时长，[SrsPullBound.budget]）。返回是否在期限内做完。见 [srsSync2PullBounded]。
Future<bool> srsSync2PullWithin(
  SrsSync2Host host,
  Future<void> Function(SrsSync2Host gated) body, {
  required Duration budget,
  required void Function(Object error, StackTrace stack) onError,
}) async =>
    await srsSync2PullBounded(
      host,
      (SrsSync2Host gated, void Function() _) => body(gated),
      bound: SrsPullBound.budget(budget),
      onError: onError,
    ) ==
    SrsPullOutcome.done;
