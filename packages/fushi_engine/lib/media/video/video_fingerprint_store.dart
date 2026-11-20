import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';

/// 一条落盘的视频指纹：算的那一刻的文件状态 + 全文件 SHA-256。
final class _StoredFingerprint {
  const _StoredFingerprint({
    required this.size,
    required this.modifiedUs,
    required this.changedUs,
    required this.digest,
  });

  final int size;
  final int modifiedUs;
  final int changedUs;
  final String digest;

  bool matches(FileStat stat) =>
      stat.type == FileSystemEntityType.file &&
      stat.size == size &&
      stat.modified.microsecondsSinceEpoch == modifiedUs &&
      stat.changed.microsecondsSinceEpoch == changedUs;

  Map<String, Object> toJson() => <String, Object>{
    's': size,
    'm': modifiedUs,
    'c': changedUs,
    'h': digest,
  };

  static _StoredFingerprint? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? s = raw['s'];
    final Object? m = raw['m'];
    final Object? c = raw['c'];
    final Object? h = raw['h'];
    if (s is! int || m is! int || c is! int || h is! String) return null;
    if (!_digestPattern.hasMatch(h)) return null;
    return _StoredFingerprint(size: s, modifiedUs: m, changedUs: c, digest: h);
  }
}

final RegExp _digestPattern = RegExp(r'^[a-f0-9]{64}$');

/// 视频全文件指纹的落盘缓存（拍板台 left3657）：按绝对路径记「算的那一刻的文件状态
/// （大小 / 修改时间 / 状态变更时间）+ SHA-256」，状态完全一致才命中，文件一动就当
/// 没算过。互联 host 后台预热算过的指纹进程重启后还在，不必每次开机把整个视频库
/// 重读一遍；回跳时 host 能立刻答出指纹。
///
/// 存成 JSON 文件而不进数据库：它只是可随时丢弃重算的缓存（坏了 / 删了只会让下次
/// 重算），不该进 schema 迁移链。写入走临时文件 + rename，读到坏文件当空缓存。
class VideoFingerprintStore {
  VideoFingerprintStore(this.file, {this.maxEntries = 50000})
    : assert(maxEntries > 0);

  final File file;

  /// 条目上限：超出时按写入先后淘汰最旧的（真实视频库远小于此）。
  final int maxEntries;

  LinkedHashMap<String, _StoredFingerprint>? _entries;
  Future<LinkedHashMap<String, _StoredFingerprint>>? _loading;
  Future<void>? _saving;
  bool _dirty = false;

  Future<LinkedHashMap<String, _StoredFingerprint>> _load() {
    final LinkedHashMap<String, _StoredFingerprint>? loaded = _entries;
    if (loaded != null) return Future.value(loaded);
    return _loading ??= () async {
      final LinkedHashMap<String, _StoredFingerprint> map =
          LinkedHashMap<String, _StoredFingerprint>();
      try {
        if (await file.exists()) {
          final Object? decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            for (final MapEntry<Object?, Object?> e in decoded.entries) {
              final Object? key = e.key;
              final _StoredFingerprint? value = _StoredFingerprint.tryParse(
                e.value,
              );
              if (key is String && value != null) map[key] = value;
            }
          }
        }
      } on Object catch (error, stack) {
        // 坏文件 / 读不了：当空缓存，下次写入整份覆盖。
        engineLog.log('video.fingerprintStore.load', error, stack);
        map.clear();
      }
      _entries = map;
      return map;
    }();
  }

  /// [absolutePath] 当前状态为 [stat] 时记过的指纹；没记过或文件状态变了返回 null。
  Future<String?> lookup(String absolutePath, FileStat stat) async {
    final _StoredFingerprint? hit = (await _load())[absolutePath];
    return hit != null && hit.matches(stat) ? hit.digest : null;
  }

  /// 记下 [absolutePath] 在状态 [stat] 下的指纹 [digest]，并等它落盘。
  Future<void> put(String absolutePath, FileStat stat, String digest) async {
    if (!_digestPattern.hasMatch(digest)) return;
    final LinkedHashMap<String, _StoredFingerprint> map = await _load();
    map.remove(absolutePath);
    map[absolutePath] = _StoredFingerprint(
      size: stat.size,
      modifiedUs: stat.modified.microsecondsSinceEpoch,
      changedUs: stat.changed.microsecondsSinceEpoch,
      digest: digest,
    );
    while (map.length > maxEntries) {
      map.remove(map.keys.first);
    }
    _dirty = true;
    await (_saving ??= _flush());
  }

  /// 把内存里的改动写盘；写的期间又有新条目时接着再写一轮，同一时刻只有一个写者。
  Future<void> _flush() async {
    try {
      while (_dirty) {
        _dirty = false;
        final LinkedHashMap<String, _StoredFingerprint> map = await _load();
        final String json = jsonEncode(<String, Object>{
          for (final MapEntry<String, _StoredFingerprint> e in map.entries)
            e.key: e.value.toJson(),
        });
        try {
          await file.parent.create(recursive: true);
          final File tmp = File('${file.path}.tmp');
          await tmp.writeAsString(json, flush: true);
          await tmp.rename(file.path);
        } on Object catch (error, stack) {
          // 写不了只是少了落盘缓存（下次开机重算），不影响本次指纹结果。
          engineLog.log('video.fingerprintStore.save', error, stack);
        }
      }
    } finally {
      _saving = null;
    }
  }
}
