/// host 侧「这份输入我本地已经有了」的内容匹配。
///
/// 客户端发来 `(名字, sha256, 大小)` 清单；host 在注入的候选文件（生产是本机有声书
/// 库里会播的音频，见 `host_audiobook_inputs.dart`）里找**内容哈希相同**的那份。
/// 大小只用来缩小要算哈希的范围（大小不同的文件内容必不同），判定只认 SHA-256；
/// 哈希走 [FileContentHashCache]，同一文件没改过就不重算。
///
/// **匹配请求里不读文件内容**：冷文件（缓存里没有当前 `(大小, 修改时刻)` 的哈希）
/// 交给后台逐个预热，本次应答 `pending = true`，客户端隔一会儿再问。此前在请求里
/// 同步整份算哈希，慢盘上的大有声书超过客户端请求超时，整个转录直接失败。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/host_jobs/file_content_hash_cache.dart';
import 'package:fushi_engine/sync/host_jobs/host_job.dart';

/// 客户端想要的一份输入。
class HostInputWanted {
  const HostInputWanted({
    required this.name,
    required this.sha256,
    required this.size,
  });

  /// 解析 wire 上的一条；缺字段 / 类型不对抛 [FormatException]。
  factory HostInputWanted.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('match: entry must be object');
    }
    final Object? name = json['name'];
    final Object? sha = json['sha256'];
    final Object? size = json['size'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('match: name required');
    }
    if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw const FormatException('match: sha256 must be 64 lowercase hex');
    }
    if (size is! int || size < 0) {
      throw const FormatException('match: size must be a non-negative int');
    }
    return HostInputWanted(name: name, sha256: sha, size: size);
  }

  final String name;
  final String sha256;
  final int size;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'sha256': sha256,
    'size': size,
  };
}

/// 一次匹配的结果。
class HostInputMatchResult {
  const HostInputMatchResult({required this.matched, required this.pending});

  static const HostInputMatchResult none = HostInputMatchResult(
    matched: <String, HostInputRef>{},
    pending: false,
  );

  /// 名字 → 命中的 host 文件；没命中的名字不在结果里。
  final Map<String, HostInputRef> matched;

  /// 还有大小吻合的候选在后台算哈希：再问一次可能多命中几份。false = 这就是终局。
  final bool pending;
}

class HostInputMatcher {
  HostInputMatcher({required this.candidates, required this.cache});

  /// host 允许被复用的本地文件（绝对路径）。只有这里列出的文件会被匹配——客户端
  /// 不能借哈希让 host 去读任意路径。
  final Future<List<String>> Function() candidates;
  final FileContentHashCache cache;

  /// 待预热（含正在算）的路径，按入队顺序逐个算——慢盘上并发读只会更慢。
  final Set<String> _warmQueue = <String>{};

  /// 算哈希失败（读不了 / 算的时候被改写）的路径 → 失败时的 `(大小, 修改时刻)`。
  /// 文件没再变就不重试，否则客户端会一直收到 `pending`。
  final Map<String, (int, int)> _warmFailedAt = <String, (int, int)>{};
  Future<void>? _warming;

  /// 后台预热跑完（测试用）。
  Future<void> whenWarmIdle() => _warming ?? Future<void>.value();

  /// 只用缓存里的哈希回答；大小吻合但没缓存的候选排进后台预热并报 `pending`。
  Future<HostInputMatchResult> match(List<HostInputWanted> wanted) async {
    if (wanted.isEmpty) return HostInputMatchResult.none;
    final Set<int> sizes = <int>{
      for (final HostInputWanted w in wanted) w.size,
    };
    final Set<String> missing = <String>{
      for (final HostInputWanted w in wanted) w.sha256,
    };
    final Map<String, FileContentFingerprint> bySha =
        <String, FileContentFingerprint>{};
    bool pending = false;
    for (final String path in (await candidates()).toSet()) {
      if (missing.isEmpty) break;
      final FileStat stat = await FileStat.stat(path);
      if (stat.type != FileSystemEntityType.file) continue;
      if (!sizes.contains(stat.size)) continue;
      final FileContentFingerprint? fp = await cache.cachedFingerprint(
        path,
        stat: stat,
      );
      if (fp == null) {
        if (_scheduleWarm(path, stat)) pending = true;
        continue;
      }
      if (missing.remove(fp.sha256)) bySha[fp.sha256] = fp;
    }
    return HostInputMatchResult(
      matched: <String, HostInputRef>{
        for (final HostInputWanted w in wanted)
          if (bySha[w.sha256] case final FileContentFingerprint fp
              when fp.size == w.size)
            w.name: HostInputRef(
              path: fp.path,
              sha256: fp.sha256,
              size: fp.size,
              modifiedAt: fp.modifiedAt,
            ),
      },
      // 全部命中就不必再等别的候选。
      pending: pending && missing.isNotEmpty,
    );
  }

  /// 把 [path] 排进后台预热；返回它的哈希是否「还会算出来」（在队里 / 正在算）。
  /// 上次就算失败且文件没再变的不重排，返回 false。
  bool _scheduleWarm(String path, FileStat stat) {
    final (int, int)? failed = _warmFailedAt[path];
    if (failed != null &&
        failed.$1 == stat.size &&
        failed.$2 == stat.modified.millisecondsSinceEpoch) {
      return false;
    }
    _warmQueue.add(path);
    _warming ??= _drainWarmQueue();
    return true;
  }

  Future<void> _drainWarmQueue() async {
    try {
      while (_warmQueue.isNotEmpty) {
        final String path = _warmQueue.first;
        try {
          await cache.fingerprint(path);
          _warmFailedAt.remove(path);
        } on FileSystemException {
          await _recordWarmFailure(path); // 读不了 / 期间被删：当没有
        } on FileContentChangedWhileHashing {
          await _recordWarmFailure(path); // 正在被写：这一版当没有，宁可上传
        } catch (e, stack) {
          engineLog.log('HostInputMatcher.warm($path)', e, stack);
          await _recordWarmFailure(path);
        } finally {
          _warmQueue.remove(path);
        }
      }
    } finally {
      _warming = null;
    }
  }

  Future<void> _recordWarmFailure(String path) async {
    final FileStat stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) {
      _warmFailedAt.remove(path);
      return;
    }
    _warmFailedAt[path] = (stat.size, stat.modified.millisecondsSinceEpoch);
  }

  /// [ref] 指向的文件现在的内容是否仍是匹配时那份。[force] = 不信缓存、整份重读
  /// （任务结束后的核对用它：修改时刻没变不代表内容没变）。文件没了 / 读到一半被改
  /// 一律算「变了」。
  Future<bool> stillMatches(HostInputRef ref, {bool force = false}) async {
    try {
      final FileContentFingerprint fp = await cache.fingerprint(
        ref.path,
        force: force,
      );
      return fp.sha256 == ref.sha256 && fp.size == ref.size;
    } on FileSystemException {
      return false;
    } on FileContentChangedWhileHashing {
      return false;
    } catch (e, stack) {
      engineLog.log('HostInputMatcher.stillMatches(${ref.path})', e, stack);
      return false;
    }
  }
}
