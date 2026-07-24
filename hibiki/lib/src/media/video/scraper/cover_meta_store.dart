/// 封面来源元数据存储（`cover_meta.json`）——批量刮削「永不覆盖手动封面」的依据。
///
/// 按 `bookUid` 记录每本视频封面的来源（[CoverMeta]）。批量匹配前查此表：
/// 只有 [CoverOrigin.autoFrame] 的封面才允许被在线刮削结果覆盖；
/// **没有记录的 bookUid 一律视同 [CoverOrigin.autoFrame]**（存量数据全无元数据，
/// 默认当作可覆盖的自动抽帧处理），因此新导入无需回填即可安全参与批量刮削。
///
/// 存储位置由调用方注入（生产传 `VideoStorage.coversDir()`，本类不 import
/// video_storage 以免耦合，仅接受一个 [Directory]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:path/path.dart' as p;

/// `cover_meta.json` 的读写器：惰性加载 + 内存缓存 + 原子写入 + 写入串行化。
class CoverMetaStore {
  /// [directory] 为存放 `cover_meta.json` 的目录（生产为封面目录）。
  CoverMetaStore(this.directory);

  /// 封面元数据文件所在目录。
  final Directory directory;

  /// 内存缓存；null 表示尚未加载。
  Map<String, CoverMeta>? _cache;

  /// 加载中的 Future（去重并发首次加载，保证所有调用共享同一份缓存 Map）。
  Future<Map<String, CoverMeta>>? _loading;

  /// 写入串行化锁：所有 set/remove 依次执行，避免并发 persist 互相覆盖。
  Future<void> _writeLock = Future<void>.value();

  /// 元数据文件路径。
  String get _filePath => p.join(directory.path, 'cover_meta.json');

  /// 损坏文件的备份路径（便于事后排查）。
  String get _corruptPath => p.join(directory.path, 'cover_meta.json.corrupt');

  /// 查某本封面的来源元数据；无记录返回 null（上层按 autoFrame 处理）。
  Future<CoverMeta?> get(String bookUid) async {
    final Map<String, CoverMeta> cache = await _ensureLoaded();
    return cache[bookUid];
  }

  /// 写入 / 覆盖一本封面的来源元数据，并原子落盘。
  Future<void> set(String bookUid, CoverMeta meta) {
    return _synchronized(() async {
      final Map<String, CoverMeta> cache = await _ensureLoaded();
      cache[bookUid] = meta;
      await _persist(cache);
    });
  }

  /// 删除一本封面的来源元数据（无记录为 no-op），并原子落盘。
  Future<void> remove(String bookUid) {
    return _synchronized(() async {
      final Map<String, CoverMeta> cache = await _ensureLoaded();
      if (cache.remove(bookUid) != null) {
        await _persist(cache);
      }
    });
  }

  /// 返回全部记录的浅拷贝快照（改动副本不影响内部缓存）。
  Future<Map<String, CoverMeta>> all() async {
    final Map<String, CoverMeta> cache = await _ensureLoaded();
    return Map<String, CoverMeta>.from(cache);
  }

  /// 串行化写操作：前一个完成后才跑下一个，避免并发 persist 丢数据。
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final Future<T> result = _writeLock.then((_) => action());
    // 无论成功失败都释放锁，让后续操作继续。
    _writeLock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// 惰性加载：首次访问读文件建缓存（并发去重）；后续直接命中内存缓存。
  Future<Map<String, CoverMeta>> _ensureLoaded() {
    final Map<String, CoverMeta>? cached = _cache;
    if (cached != null) {
      return Future<Map<String, CoverMeta>>.value(cached);
    }
    return _loading ??= _load().then((Map<String, CoverMeta> loaded) {
      _cache = loaded;
      _loading = null;
      return loaded;
    });
  }

  Future<Map<String, CoverMeta>> _load() async {
    final File file = File(_filePath);
    if (!await file.exists()) {
      return <String, CoverMeta>{};
    }
    String raw;
    try {
      raw = await file.readAsString();
    } on FileSystemException {
      return <String, CoverMeta>{};
    }
    if (raw.trim().isEmpty) {
      return <String, CoverMeta>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return await _quarantine(file);
      }
      final Map<String, CoverMeta> result = <String, CoverMeta>{};
      decoded.forEach((String key, Object? value) {
        if (value is Map<String, Object?>) {
          result[key] = CoverMeta.fromJson(value);
        }
      });
      return result;
    } on FormatException {
      // JSON 损坏：备份原文件后当空重建，绝不抛出毁掉调用链。
      return await _quarantine(file);
    }
  }

  /// 把损坏文件搬到 `.corrupt` 备份，返回空缓存。
  Future<Map<String, CoverMeta>> _quarantine(File file) async {
    try {
      await file.rename(_corruptPath);
    } on FileSystemException {
      // 备份失败不致命：仍以空缓存继续（下次 set 会原子覆盖坏文件）。
    }
    return <String, CoverMeta>{};
  }

  /// 原子落盘：写 `.tmp` 再 rename（Dart 在各平台均为替换式 rename）。
  Future<void> _persist(Map<String, CoverMeta> cache) async {
    await directory.create(recursive: true);
    final Map<String, Object?> json = <String, Object?>{
      for (final MapEntry<String, CoverMeta> entry in cache.entries)
        entry.key: entry.value.toJson(),
    };
    final File tmp = File('$_filePath.tmp');
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename(_filePath);
  }
}
