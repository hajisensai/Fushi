import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';

/// 列出要预热指纹的本地视频文件路径（每次跑都重新列，库变了自然跟上）。
typedef VideoFingerprintWarmPaths = Future<List<String>> Function();

/// 互联 host 后台低优先级预热视频全文件指纹（拍板台 left3657）。
///
/// 卡片回跳到 host 上的片子时要核验字节；指纹没算过就得当场整文件 SHA-256，几 GB 的
/// 片子要几十秒。这里在后台把视频库的指纹提前算好（结果经
/// [VideoSourceFingerprint.store] 落盘），回跳时 host 直接答出。
///
/// 低优先级：同一时刻只算一个文件（与回跳 / 制卡的请求共用
/// [VideoSourceFingerprint] 的在途去重，不会重复读盘），每算完一个歇 [pause] 再算下
/// 一个；已算过的只 stat 一下就跳过。[request] 在跑的期间再来只记一笔、跑完补一轮；
/// 两轮之间至少隔 [minInterval]，免得频繁的清单请求反复全库 stat。
class VideoFingerprintWarmer {
  VideoFingerprintWarmer({
    required VideoFingerprintWarmPaths listPaths,
    VideoSourceFingerprint? fingerprints,
    this.pause = const Duration(seconds: 2),
    this.minInterval = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _listPaths = listPaths,
       _fingerprints = fingerprints ?? VideoSourceFingerprint.instance,
       _now = now ?? DateTime.now;

  final VideoFingerprintWarmPaths _listPaths;
  final VideoSourceFingerprint _fingerprints;
  final DateTime Function() _now;

  /// 算完一个文件后歇多久再算下一个（只在真算了时歇，跳过已算过的不歇）。
  final Duration pause;

  /// 一轮跑完到下一轮开始的最短间隔。
  final Duration minInterval;

  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;
  DateTime? _lastFinished;
  Timer? _deferred;

  /// 两个文件之间的歇息（[pause]）；[dispose] 时提前结束，不让停机多等一个 [pause]。
  Timer? _pauseTimer;
  Completer<void>? _pauseDone;

  /// 当前这一轮（含补跑）；没在跑时为 null。供测试与停机等待。
  Future<void>? get running => _running;

  /// 请求跑一轮。在跑 → 跑完补一轮；距上一轮结束不足 [minInterval] → 推迟到间隔满。
  void request() {
    if (_disposed) return;
    if (_running != null) {
      _again = true;
      return;
    }
    final DateTime? last = _lastFinished;
    if (last != null) {
      final Duration wait = minInterval - _now().difference(last);
      if (wait > Duration.zero) {
        _deferred ??= Timer(wait, () {
          _deferred = null;
          request();
        });
        return;
      }
    }
    _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _runOnce();
      _lastFinished = _now();
    } while (_again && !_disposed);
  }

  Future<void> _runOnce() async {
    final List<String> paths;
    try {
      paths = await _listPaths();
    } on Object catch (error, stack) {
      engineLog.log('video.fingerprintWarm.list', error, stack);
      return;
    }
    for (final String path in paths) {
      if (_disposed) return;
      try {
        if (await _fingerprints.known(path) != null) continue;
        await _fingerprints.fingerprint(path);
      } on FileSystemException {
        // 文件不在 / 算的期间被改写：跳过，回跳时 host 会照实答「读不了」。
        continue;
      } on Object catch (error, stack) {
        engineLog.log('video.fingerprintWarm', error, stack);
        continue;
      }
      if (_disposed) return;
      await _rest();
    }
  }

  Future<void> _rest() {
    final Completer<void> done = Completer<void>();
    _pauseDone = done;
    _pauseTimer = Timer(pause, _endRest);
    return done.future;
  }

  void _endRest() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final Completer<void>? done = _pauseDone;
    _pauseDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// 停止：之后不再开新的文件，两文件间的歇息立即结束。当前在算的那个照常在后台
  /// isolate 算完（原生整文件哈希不可打断）；要等它收尾用 [close]。
  void dispose() {
    _disposed = true;
    _deferred?.cancel();
    _deferred = null;
    _endRest();
  }

  /// [dispose] 并等当前这一轮收尾：返回后预热不再读任何视频文件、不再写指纹落盘缓存
  /// （BUG-5078 / BUG-5087：host 停机后预热仍开着视频文件、仍往 sync-data 旁写
  /// `video_fingerprints.json`，Windows 上删 host 目录报文件被占用 / 目录非空）。
  /// 最多等正在算的那一个文件。
  Future<void> close() async {
    dispose();
    await _running;
  }
}
