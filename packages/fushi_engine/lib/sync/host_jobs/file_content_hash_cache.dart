/// 文件内容哈希（SHA-256）+ 按 `(路径, 大小, 修改时刻)` 的持久缓存。
///
/// 互联「把转录交给 host」时两端都要回答「这份文件的内容是什么」：本机为待上传的
/// 音频算哈希发清单，host 为自己库里的候选文件算哈希比对（见
/// [HostInputMatcher]）。判定「同一份文件」只认内容哈希，不认文件名 / 书 ID /
/// 时长（所有者拍板）；`(大小, 修改时刻)` 只用来判断缓存是否还能用。
///
/// 哈希由 `native/fushi_compute` 的流式 SHA-256 算（`ffcSha256File`：1 MiB 一块
/// 读进原生缓冲区），不把整个大音频读进内存。算完再 stat 一次：期间文件变了就不
/// 写缓存并抛 [FileContentChangedWhileHashing]，避免把半新半旧的哈希记下来。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart' show ffcSha256File;
import 'package:fushi_engine/foundation/engine_log.dart';

/// 一份文件在某一刻的内容指纹。
class FileContentFingerprint {
  const FileContentFingerprint({
    required this.path,
    required this.sha256,
    required this.size,
    required this.modifiedAt,
  });

  final String path;

  /// 64 位十六进制小写。
  final String sha256;
  final int size;

  /// 修改时刻（毫秒）。
  final int modifiedAt;
}

/// 哈希期间文件被改写（大小或修改时刻变了）。
class FileContentChangedWhileHashing implements Exception {
  const FileContentChangedWhileHashing(this.path);
  final String path;

  @override
  String toString() => 'FileContentChangedWhileHashing($path)';
}

class _CacheEntry {
  _CacheEntry({
    required this.size,
    required this.modifiedAt,
    required this.sha256,
    required this.usedAt,
  });

  factory _CacheEntry.fromJson(Map<String, dynamic> json) => _CacheEntry(
    size: json['size'] as int,
    modifiedAt: json['modifiedAt'] as int,
    sha256: json['sha256'] as String,
    usedAt: json['usedAt'] as int? ?? 0,
  );

  final int size;
  final int modifiedAt;
  final String sha256;
  int usedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'size': size,
    'modifiedAt': modifiedAt,
    'sha256': sha256,
    'usedAt': usedAt,
  };
}

class FileContentHashCache {
  FileContentHashCache({
    File? store,
    Future<String> Function(String path)? hasher,
    DateTime Function()? now,
    this.maxEntries = 4096,
  }) : _store = store,
       _hasher = hasher ?? ffcSha256File,
       _now = now ?? DateTime.now;

  /// 缓存落盘位置；null = 只在内存里（测试 / 不需要跨进程）。
  final File? _store;
  final Future<String> Function(String path) _hasher;
  final DateTime Function() _now;

  /// 超出后按最近使用淘汰。
  final int maxEntries;

  final Map<String, _CacheEntry> _entries = <String, _CacheEntry>{};
  final Map<String, Future<FileContentFingerprint>> _inFlight =
      <String, Future<FileContentFingerprint>>{};
  Future<void>? _loading;
  Future<void> _saving = Future<void>.value();

  /// 文件当前内容的指纹。`(大小, 修改时刻)` 与缓存一致就直接用缓存，否则流式重算。
  /// [force] = 无视缓存重算（用于「用完后核对内容没变」这种必须读真内容的场合）。
  ///
  /// 文件不存在抛 [FileSystemException]；哈希期间被改抛
  /// [FileContentChangedWhileHashing]。
  Future<FileContentFingerprint> fingerprint(
    String path, {
    bool force = false,
  }) async {
    await _ensureLoaded();
    final FileStat stat = await _statFile(path);
    final _CacheEntry? cached = _entries[path];
    if (!force &&
        cached != null &&
        cached.size == stat.size &&
        cached.modifiedAt == stat.modified.millisecondsSinceEpoch) {
      cached.usedAt = _now().millisecondsSinceEpoch;
      return FileContentFingerprint(
        path: path,
        sha256: cached.sha256,
        size: cached.size,
        modifiedAt: cached.modifiedAt,
      );
    }
    final String key = '$path${force ? '#force' : ''}';
    final Future<FileContentFingerprint>? pending = _inFlight[key];
    if (pending != null) return pending;
    final Future<FileContentFingerprint> computing = _compute(path, stat);
    _inFlight[key] = computing;
    try {
      return await computing;
    } finally {
      if (identical(_inFlight[key], computing)) _inFlight.remove(key);
    }
  }

  /// 等所有在飞的落盘写完（测试用）。
  Future<void> flush() => _saving;

  Future<FileContentFingerprint> _compute(String path, FileStat before) async {
    final String sha = await _hasher(path);
    final FileStat after = await _statFile(path);
    if (after.size != before.size || after.modified != before.modified) {
      throw FileContentChangedWhileHashing(path);
    }
    final int modifiedAt = after.modified.millisecondsSinceEpoch;
    _entries[path] = _CacheEntry(
      size: after.size,
      modifiedAt: modifiedAt,
      sha256: sha,
      usedAt: _now().millisecondsSinceEpoch,
    );
    _evict();
    _scheduleSave();
    return FileContentFingerprint(
      path: path,
      sha256: sha,
      size: after.size,
      modifiedAt: modifiedAt,
    );
  }

  static Future<FileStat> _statFile(String path) async {
    final FileStat stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('not a file', path);
    }
    return stat;
  }

  void _evict() {
    if (_entries.length <= maxEntries) return;
    final List<MapEntry<String, _CacheEntry>> byAge = _entries.entries.toList()
      ..sort(
        (MapEntry<String, _CacheEntry> a, MapEntry<String, _CacheEntry> b) =>
            a.value.usedAt.compareTo(b.value.usedAt),
      );
    for (int i = 0; i < byAge.length - maxEntries; i++) {
      _entries.remove(byAge[i].key);
    }
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final File? store = _store;
    if (store == null || !await store.exists()) return;
    try {
      final Object? decoded = jsonDecode(await store.readAsString());
      if (decoded is! Map) return;
      for (final MapEntry<Object?, Object?> e in decoded.entries) {
        final Object? value = e.value;
        if (e.key is! String || value is! Map) continue;
        _entries[e.key! as String] = _CacheEntry.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    } catch (e, stack) {
      // 缓存坏了只意味着要重算，不影响正确性。
      engineLog.log('FileContentHashCache.load(${store.path})', e, stack);
      _entries.clear();
    }
  }

  void _scheduleSave() {
    final File? store = _store;
    if (store == null) return;
    _saving = _saving.then((_) => _save(store));
  }

  Future<void> _save(File store) async {
    try {
      await store.parent.create(recursive: true);
      final File tmp = File('${store.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{
          for (final MapEntry<String, _CacheEntry> e in _entries.entries)
            e.key: e.value.toJson(),
        }),
        flush: true,
      );
      if (await store.exists()) await store.delete();
      await tmp.rename(store.path);
    } catch (e, stack) {
      engineLog.log('FileContentHashCache.save(${store.path})', e, stack);
    }
  }
}
