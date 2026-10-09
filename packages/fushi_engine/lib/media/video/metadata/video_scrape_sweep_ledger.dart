/// 库内自动补刮的跨进程记账（[VideoLibraryScrapeSweep] 用）。
///
/// 旧实现把「这部作品自动试过了」「这部作品刚刷新过」「TMDB 变更探针刚问过」
/// 全记在内存里，于是**每次启动**：查无 / 歧义的作品全部重新联网刮一轮（排 AniDB
/// 进程级限流队列，一部 3 秒起）、哈希查询失败的文件整份重读算 ED2K、过期刷新失败
/// 的作品再刷 20 部——用户看到的就是「每次打开都在重新加载资料、要等它刮完」。
///
/// 这里把三样状态落成 support 目录下的一个小 JSON 文件：设备本地（不进备份 / 同步，
/// 与 `anidb_anime/` XML 缓存同待遇），读写失败一律退化成进程内记账，绝不影响刮削。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:path/path.dart' as p;

class VideoScrapeSweepLedger {
  /// [file] 为 null = 纯内存（测试 / 未装配存储）。
  VideoScrapeSweepLedger({
    File? file,
    this.retryAttemptAfter = const Duration(days: 7),
    this.transientRetryAfter = const Duration(hours: 1),
  })  : _file = file,
        _resolveFile = null;

  /// 生产装配：`<support>/video_scrape_sweep_ledger.json`。
  VideoScrapeSweepLedger.inSupportDirectory({
    this.retryAttemptAfter = const Duration(days: 7),
    this.transientRetryAfter = const Duration(hours: 1),
  })  : _file = null,
        _resolveFile = (() async => File(p.join(
            (await enginePaths.supportRootDirectory()).path,
            'video_scrape_sweep_ledger.json')));

  static const int _version = 1;

  /// 查无 / 歧义 / 哈希失败的作品多久之后才再自动试一次。手动刮削不受影响。
  final Duration retryAttemptAfter;

  /// 只因资料源 / AI 临时不可用（504 / 握手失败 / 超时 / 限流）而失败的作品多久
  /// 之后才再自动试一次。
  ///
  /// 临时失败同样是一次「已尝试」：旧实现把它直接撤账（BUG-2796），于是任意
  /// 一次触发都会重新认领它——资料源连不上时同一作品每分钟被重刮十几次
  /// （BUG-3072）。这里给它一个有界的短间隔：不像查无那样挡 7 天，也不会在
  /// 资料源恢复之前被每一轮触发反复认领。
  final Duration transientRetryAfter;

  File? _file;
  final Future<File> Function()? _resolveFile;
  Future<void>? _loading;
  bool _dirty = false;
  Future<void> _saving = Future<void>.value();

  String? _fingerprint;
  final Map<String, int> _attemptedAt = <String, int>{};
  final Map<String, int> _transientFailedAt = <String, int>{};
  final Map<String, int> _refreshedAt = <String, int>{};
  int? _lastRefreshProbeAt;

  /// 首次使用前读盘（幂等）。[fingerprint] 是刮削配置指纹：配置变了（开了哈希、
  /// 换了主源 / 账号），上一套配置下「试过没中」的结论不再成立，清掉重试。
  Future<void> ensureLoaded({required String fingerprint}) async {
    await (_loading ??= _load());
    if (_fingerprint != fingerprint) {
      if (_fingerprint != null) {
        _attemptedAt.clear();
        _transientFailedAt.clear();
      }
      _fingerprint = fingerprint;
      _dirty = true;
    }
  }

  bool wasAttemptedRecently(String workKey, DateTime now) =>
      _within(_attemptedAt[workKey], now, retryAttemptAfter) ||
      _within(_transientFailedAt[workKey], now, transientRetryAfter);

  static bool _within(int? at, DateTime now, Duration window) =>
      at != null &&
      now.difference(DateTime.fromMillisecondsSinceEpoch(at)) < window;

  void markAttempted(Iterable<String> workKeys, DateTime now) {
    for (final String key in workKeys) {
      _attemptedAt[key] = now.millisecondsSinceEpoch;
      _transientFailedAt.remove(key);
      _dirty = true;
    }
  }

  /// 这些作品的这次尝试只因资料源临时不可用而失败，不是「查无 / 歧义」：
  /// 改按 [transientRetryAfter] 退避（从 [now] 起算），不挡 [retryAttemptAfter]。
  void markTransientFailure(Iterable<String> workKeys, DateTime now) {
    for (final String key in workKeys) {
      _attemptedAt.remove(key);
      _transientFailedAt[key] = now.millisecondsSinceEpoch;
      _dirty = true;
    }
  }

  DateTime? refreshedAt(String workKey) {
    final int? at = _refreshedAt[workKey];
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  void markRefreshed(Iterable<String> workKeys, DateTime now) {
    for (final String key in workKeys) {
      _refreshedAt[key] = now.millisecondsSinceEpoch;
      _dirty = true;
    }
  }

  DateTime? get lastRefreshProbeAt => _lastRefreshProbeAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_lastRefreshProbeAt!);

  void markRefreshProbe(DateTime now) {
    _lastRefreshProbeAt = now.millisecondsSinceEpoch;
    _dirty = true;
  }

  /// 有改动才写；写盘串行化，失败静默（下次改动再写）。
  Future<void> save({required DateTime now, required Duration refreshWindow}) {
    if (!_dirty) return _saving;
    _dirty = false;
    // 过期条目不再有判定作用，顺手剪掉，文件大小只跟「近期碰过的作品」走。
    final int nowMs = now.millisecondsSinceEpoch;
    _attemptedAt.removeWhere(
        (_, int at) => nowMs - at >= retryAttemptAfter.inMilliseconds);
    _transientFailedAt.removeWhere(
        (_, int at) => nowMs - at >= transientRetryAfter.inMilliseconds);
    _refreshedAt
        .removeWhere((_, int at) => nowMs - at >= refreshWindow.inMilliseconds);
    final String payload = jsonEncode(<String, Object?>{
      'v': _version,
      'fingerprint': _fingerprint,
      'attempted': _attemptedAt,
      // 新增字段不升版本：旧版本读到会忽略它（= 下次触发重试），不会读坏。
      'transient': _transientFailedAt,
      'refreshed': _refreshedAt,
      'lastRefreshProbeAt': _lastRefreshProbeAt,
    });
    return _saving = _saving.then((_) async {
      try {
        final File? file = await _targetFile();
        if (file == null) return;
        await file.parent.create(recursive: true);
        final File temp = File('${file.path}.tmp');
        await temp.writeAsString(payload, flush: true);
        await temp.rename(file.path);
      } on Object {
        // 记账是优化，不是正确性前提。
      }
    });
  }

  Future<File?> _targetFile() async {
    if (_file != null) return _file;
    final Future<File> Function()? resolve = _resolveFile;
    if (resolve == null) return null;
    try {
      return _file = await resolve();
    } on Object {
      return null;
    }
  }

  Future<void> _load() async {
    try {
      final File? file = await _targetFile();
      if (file == null || !await file.exists()) return;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> || decoded['v'] != _version) return;
      _fingerprint = decoded['fingerprint'] as String?;
      _readTimes(decoded['attempted'], _attemptedAt);
      _readTimes(decoded['transient'], _transientFailedAt);
      _readTimes(decoded['refreshed'], _refreshedAt);
      final Object? probe = decoded['lastRefreshProbeAt'];
      if (probe is int) _lastRefreshProbeAt = probe;
    } on Object {
      // 文件损坏 / 读失败：当作空账本，下次写盘覆盖。
    }
  }

  static void _readTimes(Object? raw, Map<String, int> into) {
    if (raw is! Map<String, Object?>) return;
    for (final MapEntry<String, Object?> entry in raw.entries) {
      final Object? value = entry.value;
      if (value is int) into[entry.key] = value;
    }
  }
}
