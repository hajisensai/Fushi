import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/video_fingerprint_store.dart';

/// 对 [absolutePath]（调用前 stat 得到 [stat]）算全文件身份；返回前须确认文件状态
/// 未变，变了就抛 [FileSystemException]。
typedef VideoFingerprintCompute =
    Future<String> Function(String absolutePath, FileStat stat);

/// 同一文件、同一状态正在算的那一次。
final class _PendingFingerprint {
  _PendingFingerprint(this.stat, this.digest);

  final FileStat stat;
  final Future<String> digest;
}

/// Full-file identity for card sources. The library UID alone is name-derived.
class VideoSourceFingerprint {
  VideoSourceFingerprint({
    this.maxCachedFiles = 128,
    VideoFingerprintCompute compute = _hashInIsolate,
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

  Future<String> fingerprint(String path) async {
    final (String absolutePath, FileStat stat) = await _statLocal(path);
    final String? known = await _knownFor(absolutePath, stat);
    if (known != null) return known;
    final _PendingFingerprint? running = _inFlight[absolutePath];
    if (running != null && _sameFileState(stat, running.stat)) {
      return running.digest;
    }
    final _PendingFingerprint pending = _PendingFingerprint(
      stat,
      _compute(absolutePath, stat).then((String digest) async {
        _remember(absolutePath, stat, digest);
        await store?.put(absolutePath, stat, digest);
        return digest;
      }),
    );
    _inFlight[absolutePath] = pending;
    try {
      return await pending.digest;
    } finally {
      // 算的期间文件变了时，新状态的那一次已替换掉本条，不能把它摘掉。
      if (identical(_inFlight[absolutePath], pending)) {
        _inFlight.remove(absolutePath);
      }
    }
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

  Future<bool> matches(String path, String expected) async =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) &&
      await fingerprint(path) == expected;

  static Future<String> _hashInIsolate(String absolutePath, FileStat stat) =>
      Isolate.run<String>(() async {
        final File file = File(absolutePath);
        // SHA-256 runs in native/fushi_compute (ffc_hash_sha256_*), same
        // lowercase hex as before; sync reads are fine on this worker isolate.
        final String hash = ffcSha256FileSync(absolutePath);
        if (!_sameFileState(stat, await file.stat())) {
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
