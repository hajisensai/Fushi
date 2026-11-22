import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/video_fingerprint_store.dart';
import 'package:meta/meta.dart';

/// 对 [absolutePath]（调用前 stat 得到 [stat]）算全文件身份；返回前须确认文件状态
/// 未变，变了就抛 [FileSystemException]。
///
/// [cancel] 被取消后应尽快停下、不再读文件，并抛 [VideoFingerprintCancelledException]
/// （已经算完的照常返回结果）。返回的 Future 结束即表示这次计算不再碰文件——
/// [VideoSourceFingerprint] 靠它兑现「取消返回后不再开着视频文件」。
typedef VideoFingerprintCompute =
    Future<String> Function(
      String absolutePath,
      FileStat stat,
      VideoFingerprintCancellation cancel,
    );

/// 指纹计算的取消信号（拍板台 host-stop-fingerprint-cancel）：互联 host 停机时用它打断
/// 自己发起的、正在整文件读盘的指纹计算，停机不必等几 GB 的片子算完。
///
/// 一个信号常常活得比单次计算长（预热器 / host 一次运行共用一个），所以单次计算挂的
/// 回调走 [onCancel]、算完即摘；不往 [whenCancelled] 上挂 `then`——那种监听摘不掉，
/// 会随请求数在信号的整个寿命里只增不减。
final class VideoFingerprintCancellation {
  final Completer<void> _cancelled = Completer<void>();
  final Set<_CancelListener> _listeners = <_CancelListener>{};

  bool get isCancelled => _cancelled.isCompleted;

  /// 取消时完成（不会出错）。只给与信号同寿命的等待用；单次计算的回调用 [onCancel]。
  Future<void> get whenCancelled => _cancelled.future;

  /// 取消时同步调用 [listener]（已取消则不登记、立即调用）。返回摘除函数（幂等），
  /// 回调不再需要时必须调，否则它活到信号取消或被回收为止。
  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
      return _noop;
    }
    final _CancelListener entry = _CancelListener(listener);
    _listeners.add(entry);
    return () => _listeners.remove(entry);
  }

  /// 还挂着的 [onCancel] 回调数（测试用：单次计算结束后应摘干净）。
  @visibleForTesting
  int get debugListenerCount => _listeners.length;

  /// 取消（幂等）：完成 [whenCancelled]，并按登记顺序同步调用全部 [onCancel] 回调。
  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    final List<_CancelListener> listeners = _listeners.toList();
    _listeners.clear();
    for (final _CancelListener entry in listeners) {
      entry.callback();
    }
  }

  static void _noop() {}
}

/// [VideoFingerprintCancellation.onCancel] 的一条登记（按身份摘除，同一函数登记两次也是两条）。
final class _CancelListener {
  _CancelListener(this.callback);

  final void Function() callback;
}

/// 调用方经 [VideoFingerprintCancellation] 撤走了：这次没有指纹。
final class VideoFingerprintCancelledException implements Exception {
  const VideoFingerprintCancelledException(this.path);

  final String path;

  @override
  String toString() =>
      'VideoFingerprintCancelledException: fingerprint cancelled ($path)';
}

/// 同一文件、同一状态正在算的那一次。
final class _PendingFingerprint {
  _PendingFingerprint(this.stat);

  final FileStat stat;

  /// 打断底层计算：最后一个可取消的等待方撤走、且没有不可取消的等待方时才置位。
  final VideoFingerprintCancellation abort = VideoFingerprintCancellation();

  /// 还在等这次结果的调用方数（不可取消的等待方永不减，所以有它在就不会被打断）。
  int waiters = 0;

  /// 计算 + 记缓存 + 落盘全部结束（成败都算）；[VideoSourceFingerprint.fingerprint]
  /// 里由 `_run` 赋值。
  late final Future<String> digest;
}

/// Full-file identity for card sources. The library UID alone is name-derived.
class VideoSourceFingerprint {
  VideoSourceFingerprint({
    this.maxCachedFiles = 128,
    VideoFingerprintCompute compute = hashInIsolate,
  }) : assert(maxCachedFiles > 0),
       _compute = compute;

  static final VideoSourceFingerprint instance = VideoSourceFingerprint();
  final int maxCachedFiles;
  final VideoFingerprintCompute _compute;
  final LinkedHashMap<String, (FileStat, String)> _cache =
      LinkedHashMap<String, (FileStat, String)>();

  /// 在途去重（BUG-4783）：host 上两个 client（或同一 client 制卡 + 回跳）同时要
  /// 同一个大文件的指纹时只整文件读一遍盘，后到的复用同一个 Future。
  final Map<String, _PendingFingerprint> _inFlight =
      <String, _PendingFingerprint>{};

  /// 落盘缓存（拍板台 left3657）：互联 host 起服务时挂上、停服务时摘掉。挂着时算过的
  /// 指纹进程重启后仍可直接命中；null = 只有内存缓存（单测 / host 未启用）。
  VideoFingerprintStore? store;

  static bool isLocalPath(String? path) =>
      path != null &&
      path.isNotEmpty &&
      !RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(path);

  /// [path] 当前状态下的全文件指纹：缓存命中直接答，否则算（同一文件同一状态的并发
  /// 调用共用一次计算，BUG-4783）。
  ///
  /// 给了 [cancel] 的调用可以撤走（拍板台 host-stop-fingerprint-cancel）：取消后本调用抛
  /// [VideoFingerprintCancelledException]。共用的那次计算只有在**所有**等待方都撤走时才被
  /// 打断（不带 [cancel] 的等待方——如本机制卡——永远不撤，有它在就照常算完）；撤走的是
  /// 最后一个等待方时，本调用等底层计算真正停下（不再开着文件、落盘也收尾）才结束，其余
  /// 情况立即结束。打断后同一文件的新请求重新开算，不并进正在停下的那一次。
  Future<String> fingerprint(
    String path, {
    VideoFingerprintCancellation? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) {
      throw VideoFingerprintCancelledException(path);
    }
    final (String absolutePath, FileStat stat) = await _statLocal(path);
    final String? known = await _knownFor(absolutePath, stat);
    if (known != null) return known;
    if (cancel?.isCancelled ?? false) {
      throw VideoFingerprintCancelledException(absolutePath);
    }
    _PendingFingerprint? pending = _inFlight[absolutePath];
    if (pending == null || !_sameFileState(stat, pending.stat)) {
      final _PendingFingerprint started = _PendingFingerprint(stat);
      _inFlight[absolutePath] = started;
      started.digest = _run(absolutePath, started);
      // 等待方全部撤走后，被打断的那次以取消告终、可能没人再接它的错误。
      started.digest.ignore();
      pending = started;
    }
    return _join(absolutePath, pending, cancel);
  }

  Future<String> _run(String absolutePath, _PendingFingerprint pending) async {
    try {
      final String digest = await _compute(
        absolutePath,
        pending.stat,
        pending.abort,
      );
      _remember(absolutePath, pending.stat, digest);
      await store?.put(absolutePath, pending.stat, digest);
      return digest;
    } finally {
      // 算的期间文件变了时，新状态的那一次已替换掉本条，不能把它摘掉。
      if (identical(_inFlight[absolutePath], pending)) {
        _inFlight.remove(absolutePath);
      }
    }
  }

  /// 作为一个等待方加入 [pending]；可取消的等待方撤走规则见 [fingerprint]。
  Future<String> _join(
    String absolutePath,
    _PendingFingerprint pending,
    VideoFingerprintCancellation? cancel,
  ) {
    pending.waiters++;
    if (cancel == null) return pending.digest;
    final Completer<String> result = Completer<String>();
    // 信号常比这次计算活得长（预热器 / host 一次运行共用一个）：计算结束就摘掉回调。
    final void Function() unregister = cancel.onCancel(() {
      if (result.isCompleted) return;
      if (--pending.waiters > 0) {
        // 还有别人在等：计算照常继续（文件归他们），本调用立即撤走。
        result.completeError(VideoFingerprintCancelledException(absolutePath));
        return;
      }
      // 最后一个等待方：打断计算，并让新请求不再并进来；本调用等它真正停下，结果由
      // 下面 digest 的监听带回（停下前恰好算完就照常给出指纹）。
      pending.abort.cancel();
      if (identical(_inFlight[absolutePath], pending)) {
        _inFlight.remove(absolutePath);
      }
    });
    pending.digest.then<void>(
      (String digest) {
        unregister();
        if (!result.isCompleted) result.complete(digest);
      },
      onError: (Object error, StackTrace stack) {
        unregister();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  /// 不算、只查：[path] 当前状态下已经算过（内存或落盘缓存）的指纹，没算过返回 null。
  /// 文件不在 / 不是本地文件同 [fingerprint] 一样抛 [FileSystemException]。回跳问 host
  /// 时用它，不让用户干等整文件哈希（拍板台 left3657）。
  Future<String?> known(String path) async {
    final (String absolutePath, FileStat stat) = await _statLocal(path);
    return _knownFor(absolutePath, stat);
  }

  Future<(String, FileStat)> _statLocal(String path) async {
    if (!isLocalPath(path)) {
      throw const FileSystemException(
        'Card sources require a local video file',
      );
    }
    final String absolutePath = File(path).absolute.path;
    final FileStat stat = await File(absolutePath).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Card source video is missing', path);
    }
    return (absolutePath, stat);
  }

  Future<String?> _knownFor(String absolutePath, FileStat stat) async {
    final (FileStat, String)? cached = _cache.remove(absolutePath);
    if (cached != null && _sameFileState(stat, cached.$1)) {
      _cache[absolutePath] = cached;
      return cached.$2;
    }
    final String? stored = await store?.lookup(absolutePath, stat);
    if (stored != null) _remember(absolutePath, stat, stored);
    return stored;
  }

  void _remember(String absolutePath, FileStat stat, String digest) {
    _cache.remove(absolutePath);
    _cache[absolutePath] = (stat, digest);
    while (_cache.length > maxCachedFiles) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<bool> matches(
    String path,
    String expected, {
    VideoFingerprintCancellation? cancel,
  }) async =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) &&
      await fingerprint(path, cancel: cancel) == expected;

  /// 默认计算：后台 isolate 里原生整文件 SHA-256，取消经原生取消标志打断读盘循环
  /// （每 1 MiB 查一次，停下即关文件）。
  @visibleForTesting
  static Future<String> hashInIsolate(
    String absolutePath,
    FileStat stat,
    VideoFingerprintCancellation cancel,
  ) async {
    if (cancel.isCancelled) {
      throw VideoFingerprintCancelledException(absolutePath);
    }
    final FfcCancelFlag flag = FfcCancelFlag.create();
    final void Function() unregister = cancel.onCancel(flag.cancel);
    try {
      final String? hash = await _hashWorker(absolutePath, stat, flag.address);
      if (hash == null) throw VideoFingerprintCancelledException(absolutePath);
      return hash;
    } finally {
      // worker 已返回、原生调用已结束，标志不再被读：先摘回调再释放内存。
      unregister();
      flag.dispose();
    }
  }

  /// 单独一个函数起 worker：闭包只捕获这里的三个可发送参数（与 [hashInIsolate] 里
  /// 持有原生指针的标志对象不共用闭包上下文）。被取消返回 null。
  static Future<String?> _hashWorker(
    String absolutePath,
    FileStat stat,
    int cancelAddress,
  ) => Isolate.run<String?>(() async {
    final String hash;
    try {
      // SHA-256 runs in native/fushi_compute (ffc_hash_sha256_file_cancellable),
      // same lowercase hex as before; sync reads are fine on this worker isolate.
      hash = ffcSha256FileSync(
        absolutePath,
        cancel: FfcCancelFlag.attach(cancelAddress),
      );
    } on FfcCancelledException {
      return null;
    }
    if (!_sameFileState(stat, await File(absolutePath).stat())) {
      throw FileSystemException(
        'Video changed while calculating identity',
        absolutePath,
      );
    }
    return hash;
  });

  static bool _sameFileState(FileStat a, FileStat b) =>
      a.type == FileSystemEntityType.file &&
      b.type == FileSystemEntityType.file &&
      a.size == b.size &&
      a.modified == b.modified &&
      a.changed == b.changed;
}
