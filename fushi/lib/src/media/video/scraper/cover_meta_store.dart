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

import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:path/path.dart' as p;

/// `cover_meta.json` 的读写器：惰性加载 + 内存缓存 + 原子写入 + 写入串行化。
class CoverMetaStore {
  /// [directory] 为存放 `cover_meta.json` 的目录（生产为封面目录）。
  CoverMetaStore(this.directory)
    : _state = _states.putIfAbsent(
        _directoryKey(directory),
        _CoverMetaStoreState.new,
      );

  static final Map<String, _CoverMetaStoreState> _states =
      <String, _CoverMetaStoreState>{};
  static int _tempSerial = 0;

  /// 封面元数据文件所在目录。
  final Directory directory;

  /// 同一目录的所有实例共享缓存与写锁；页面换封面、后台回填和全量清理会各自创建
  /// store，实例级锁无法阻止它们拿陈旧快照互相覆盖。
  final _CoverMetaStoreState _state;

  /// 元数据文件路径。
  String get _filePath => p.join(directory.path, 'cover_meta.json');

  /// 损坏文件的备份路径（便于事后排查）。
  String get _corruptPath => p.join(directory.path, 'cover_meta.json.corrupt');

  /// 查某本封面的来源元数据；无记录返回 null（上层按 autoFrame 处理）。
  Future<CoverMeta?> get(String bookUid) async {
    final Map<String, CoverMeta> cache = await _ensureLoaded();
    return cache[bookUid];
  }

  /// 绕过普通读缓存，在同目录写锁内重新读取当前来源。
  ///
  /// 只用于“来源准入 → 文件替换”这类 compare-before-write 临界区：批处理可能在
  /// 排队等待封面写锁前读过一次 autoFrame，真正落盘前必须再看一次最新来源。
  Future<CoverMeta?> getFresh(String bookUid) {
    return _synchronized(() async {
      final Map<String, CoverMeta> current = await _load();
      _state.cache = current;
      return current[bookUid];
    });
  }

  /// 写入 / 覆盖一本封面的来源元数据，并原子落盘。
  Future<void> set(String bookUid, CoverMeta meta) {
    return _synchronized(() async {
      final Map<String, CoverMeta> next = Map<String, CoverMeta>.from(
        await _load(),
      )..[bookUid] = meta;
      await _persist(next);
      _state.cache = next;
    });
  }

  /// 删除一本封面的来源元数据（无记录为 no-op），并原子落盘。
  Future<void> remove(String bookUid) {
    return _synchronized(() async {
      final Map<String, CoverMeta> next = Map<String, CoverMeta>.from(
        await _load(),
      );
      if (next.remove(bookUid) != null) {
        await _persist(next);
      }
      _state.cache = next;
    });
  }

  /// 仅当来源仍等于 [expectedOrigin] 时批量删除。破坏性清理使用它做最后一道
  /// compare-and-delete：用户若在清理快照之后手工换了封面并写入 `manual`，旧清理
  /// 不能再把这条新来源标记删掉。
  Future<void> removeAllWhereOrigin(
    Iterable<String> bookUids,
    CoverOrigin expectedOrigin,
  ) {
    return _synchronized(() async {
      final Map<String, CoverMeta> next = Map<String, CoverMeta>.from(
        await _load(),
      );
      bool changed = false;
      for (final String bookUid in bookUids.toSet()) {
        if (next[bookUid]?.origin != expectedOrigin) continue;
        next.remove(bookUid);
        changed = true;
      }
      if (changed) await _persist(next);
      _state.cache = next;
    });
  }

  /// 把已有所有权摘要的历史自动封面推进到可恢复的清理中间态。
  /// 已经处于同摘要中间态时幂等返回 true；来源已被用户改成保护态时返回 false。
  Future<bool> markAutoScrapedCleanupPending(
    String bookUid,
    String contentSha256,
  ) {
    return _synchronized(() async {
      final Map<String, CoverMeta> next = Map<String, CoverMeta>.from(
        await _load(),
      );
      final CoverMeta? current = next[bookUid];
      if (current?.origin == CoverOrigin.cleanupPending) {
        _state.cache = next;
        return current?.contentSha256?.toLowerCase() ==
            contentSha256.toLowerCase();
      }
      if (current?.origin == CoverOrigin.autoScraped) {
        if (current?.contentSha256?.toLowerCase() !=
            contentSha256.toLowerCase()) {
          _state.cache = next;
          return false;
        }
        next[bookUid] = CoverMeta(
          origin: CoverOrigin.cleanupPending,
          source: current?.source,
          entryId: current?.entryId,
          contentSha256: current?.contentSha256,
        );
        await _persist(next);
        _state.cache = next;
        return true;
      }
      _state.cache = next;
      return false;
    });
  }

  /// 清理隔离旧封面后发现同路径新文件时，将旧所有权标记转为用户保护态。
  /// fresh-load + compare-and-set 保证并发写者若已经写入其它来源不会被覆盖。
  Future<void> protectLegacyCleanupReplacement(String bookUid) {
    return _synchronized(() async {
      final Map<String, CoverMeta> next = Map<String, CoverMeta>.from(
        await _load(),
      );
      final CoverMeta? current = next[bookUid];
      final CoverOrigin? origin = current?.origin;
      if (origin == CoverOrigin.autoScraped ||
          origin == CoverOrigin.cleanupPending) {
        next[bookUid] = CoverMeta(
          origin: CoverOrigin.cleanupReplacement,
          contentSha256: current?.contentSha256,
        );
        await _persist(next);
      }
      _state.cache = next;
    });
  }

  /// 自动封面写盘前的来源准入。手选、sidecar、当前刮削结果及清理窗口替换物都
  /// 属于受保护资产，后台抽帧/远端回填不得覆盖；无记录、既有自动帧和历史
  /// autoScraped 才可继续。cleanupPending 代表隔离文件尚待恢复/收敛，必须保持
  /// fail-closed，不能让后台抽帧吞掉其摘要并把 quarantine 永久藏起来。
  Future<bool> allowsAutoFrameWrite(String bookUid) {
    return _synchronized(() async {
      final Map<String, CoverMeta> current = await _load();
      _state.cache = current;
      return switch (current[bookUid]?.origin) {
        CoverOrigin.manual ||
        CoverOrigin.scraped ||
        CoverOrigin.userScraped ||
        CoverOrigin.sidecar ||
        CoverOrigin.cleanupPending ||
        CoverOrigin.cleanupReplacement => false,
        _ => true,
      };
    });
  }

  /// 自动封面文件与 DB 指针都成功后，在同一 operation lease 释放前提交来源。
  /// 若准入后有另一写者把来源换成保护态，compare-and-set 返回 false，绝不覆盖
  /// 新来源；调用方必须把它视为写入冲突而不是静默成功。
  Future<bool> markAutoFrameAfterWrite(String bookUid) {
    return _synchronized(() async {
      final Map<String, CoverMeta> next = Map<String, CoverMeta>.from(
        await _load(),
      );
      final CoverOrigin? origin = next[bookUid]?.origin;
      if (origin == CoverOrigin.manual ||
          origin == CoverOrigin.scraped ||
          origin == CoverOrigin.userScraped ||
          origin == CoverOrigin.sidecar ||
          origin == CoverOrigin.cleanupPending ||
          origin == CoverOrigin.cleanupReplacement) {
        _state.cache = next;
        return false;
      }
      if (origin != CoverOrigin.autoFrame) {
        next[bookUid] = const CoverMeta(origin: CoverOrigin.autoFrame);
        await _persist(next);
      }
      _state.cache = next;
      return true;
    });
  }

  /// 返回全部记录的浅拷贝快照（改动副本不影响内部缓存）。
  Future<Map<String, CoverMeta>> all() async {
    final Map<String, CoverMeta> cache = await _ensureLoaded();
    return Map<String, CoverMeta>.from(cache);
  }

  /// 串行化写操作：前一个完成后才跑下一个，避免并发 persist 丢数据。
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final Future<T> result = _state.writeLock.then((_) => action());
    // 无论成功失败都释放锁，让后续操作继续。
    _state.writeLock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// 惰性加载：首次访问也进入同目录写锁，避免旧 reader 读到损坏 JSON 后，恰在
  /// 并发 set 已持久化合法文件之后把新文件 rename 成 `.corrupt`。后续直接命中缓存。
  Future<Map<String, CoverMeta>> _ensureLoaded() {
    final Map<String, CoverMeta>? cached = _state.cache;
    if (cached != null) {
      return Future<Map<String, CoverMeta>>.value(cached);
    }
    final Future<Map<String, CoverMeta>>? loading = _state.loading;
    if (loading != null) return loading;
    final Future<Map<String, CoverMeta>> result = _synchronized(() async {
      // 排队期间写者可能已发布缓存；此时不再重复读盘或 quarantine。
      final Map<String, CoverMeta>? published = _state.cache;
      if (published != null) return published;
      final Map<String, CoverMeta> loaded = await _load();
      _state.cache = loaded;
      return loaded;
    });
    _state.loading = result.whenComplete(() => _state.loading = null);
    return _state.loading!;
  }

  Future<Map<String, CoverMeta>> _load() async {
    final File file = File(_filePath);
    if (!await file.exists()) {
      return <String, CoverMeta>{};
    }
    // 文件已经存在却读失败时必须 fail closed。把权限/共享冲突当空记录再写回，
    // 会抹掉其它 book 的 manual/userScraped 保护标记。
    final String raw = await file.readAsString();
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
    final File tmp = File('$_filePath.tmp.$pid.${_tempSerial++}');
    try {
      await tmp.writeAsString(jsonEncode(json));
      await tmp.rename(_filePath);
    } finally {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } on FileSystemException {
          // rename 已完成时 tmp 不存在；失败残留只影响诊断，不得掩盖原异常。
        }
      }
    }
  }

  static String _directoryKey(Directory directory) {
    final String normalized = p.normalize(p.absolute(directory.path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

class _CoverMetaStoreState {
  Map<String, CoverMeta>? cache;
  Future<Map<String, CoverMeta>>? loading;
  Future<void> writeLock = Future<void>.value();
}
