/// host 侧「这份输入我本地已经有了」的内容匹配。
///
/// 客户端发来 `(名字, sha256, 大小)` 清单；host 在注入的候选文件（生产是本机有声书
/// 库里会播的音频，见 `host_audiobook_inputs.dart`）里找**内容哈希相同**的那份。
/// 大小只用来缩小要算哈希的范围（大小不同的文件内容必不同），判定只认 SHA-256；
/// 哈希走 [FileContentHashCache]，同一文件没改过就不重算。
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
    if (json is! Map) throw const FormatException('match: entry must be object');
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

class HostInputMatcher {
  HostInputMatcher({required this.candidates, required this.cache});

  /// host 允许被复用的本地文件（绝对路径）。只有这里列出的文件会被匹配——客户端
  /// 不能借哈希让 host 去读任意路径。
  final Future<List<String>> Function() candidates;
  final FileContentHashCache cache;

  /// 返回 名字 → 命中的 host 文件；没命中的名字不在结果里。
  Future<Map<String, HostInputRef>> match(List<HostInputWanted> wanted) async {
    if (wanted.isEmpty) return const <String, HostInputRef>{};
    final Set<int> sizes = <int>{for (final HostInputWanted w in wanted) w.size};
    final Set<String> missing = <String>{
      for (final HostInputWanted w in wanted) w.sha256,
    };
    final Map<String, FileContentFingerprint> bySha =
        <String, FileContentFingerprint>{};
    for (final String path in (await candidates()).toSet()) {
      if (missing.isEmpty) break;
      final FileStat stat = await FileStat.stat(path);
      if (stat.type != FileSystemEntityType.file) continue;
      if (!sizes.contains(stat.size)) continue;
      final FileContentFingerprint fp;
      try {
        fp = await cache.fingerprint(path);
      } on FileSystemException {
        continue; // 期间被删：当没有
      } on FileContentChangedWhileHashing {
        continue; // 正在被写：当没有，宁可上传
      }
      if (missing.remove(fp.sha256)) bySha[fp.sha256] = fp;
    }
    return <String, HostInputRef>{
      for (final HostInputWanted w in wanted)
        if (bySha[w.sha256] case final FileContentFingerprint fp
            when fp.size == w.size)
          w.name: HostInputRef(
            path: fp.path,
            sha256: fp.sha256,
            size: fp.size,
            modifiedAt: fp.modifiedAt,
          ),
    };
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
