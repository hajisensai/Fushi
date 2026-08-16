import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 远端封面读盘缓存（BUG-847）。
///
/// [RemoteCoverImage] 原本只依赖 Flutter 进程内 [ImageCache]（纯内存）：冷启动即把所有
/// 远端封面全部重新网络拉取，滚动被 LRU 淘汰后滚回来也重下，低内存模式进后台还整清。
/// 本类在 `<temp>/remote_cover_cache/` 落一层**可丢弃磁盘缓存**，按**稳定 id**（video.id /
/// book identifier，而非易变的 `coverUrl`——换 IP / http↔https 会让 URL 变但封面不变）键控：
/// 命中直接读盘（跨重启存活），未命中才拉网并落盘。
///
/// 用 [AppPaths.tempRootDirectory]（系统临时目录）而非 documents 根：封面是纯 fetch 缓存、
/// 重下即可，不属用户数据，不进数据根迁移白名单，OS 清理临时目录也无副作用。
class RemoteCoverCache {
  RemoteCoverCache._();

  /// 缓存目录解析器（默认系统临时目录下 `remote_cover_cache`）。测试用
  /// [debugSetDirResolver] 覆盖到隔离目录，使读盘缓存在纯 Dart 单测里可断言。
  static Future<Directory> Function() _dirResolver = _defaultDir;

  static Future<Directory> _defaultDir() async {
    final Directory base = await AppPaths.tempRootDirectory();
    return Directory(p.join(base.path, 'remote_cover_cache'));
  }

  /// 目录只解析并 `create(recursive:true)` 一次（memoized）。
  static Future<Directory>? _ensured;

  static Future<Directory> _dir() =>
      _ensured ??= _dirResolver().then((Directory d) async {
        await d.create(recursive: true);
        return d;
      });

  /// 测试注入：覆盖缓存目录解析器（传 null 还原默认）。清空 memoized 目录。
  @visibleForTesting
  static void debugSetDirResolver(Future<Directory> Function()? resolver) {
    _dirResolver = resolver ?? _defaultDir;
    _ensured = null;
  }

  /// 稳定 id → 文件安全名：base64url（无 padding）编码，可逆且无碰撞，规避 id 里的
  /// `/` `:` `?` 等非法文件名字符。
  static String fileNameFor(String key) =>
      'c_${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}';

  /// 磁盘条目最长可信时长（BUG-1693 批审计：host 换封面后客户端永远旧图）。
  /// 超龄按未命中处理并删除——封面最迟一周自愈，且不需要任何「host 封面变了」
  /// 的失效信号（那种信号根本不存在）。
  static const Duration maxEntryAge = Duration(days: 7);

  /// 缓存目录条目上限（此前完全无界：只增不减，几台对端 + 大库能积到没边）。
  /// 超限在写入后概率性清理最旧的（按 mtime）。
  static const int maxEntries = 512;

  /// 命中返回字节；未命中 / 空文件 / 超龄 / 任何 IO 异常 → null（调用方回退网络）。
  static Future<Uint8List?> read(String key) async {
    try {
      final Directory dir = await _dir();
      final File f = File(p.join(dir.path, fileNameFor(key)));
      if (!await f.exists()) return null;
      final DateTime mtime = (await f.stat()).modified;
      if (DateTime.now().difference(mtime) > maxEntryAge) {
        // 超龄：删掉并按未命中走网络（拉网失败也只是这张封面回占位图）。
        try {
          await f.delete();
        } catch (_) {}
        return null;
      }
      final Uint8List bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      // 缓存尽力而为：读损坏 / 权限 / 竞态删除都退回网络，绝不因缓存挂掉封面。
      return null;
    }
  }

  /// 落盘（尽力而为，异常吞掉不影响显示）。空字节不写。写后概率性修剪容量。
  static Future<void> write(String key, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    try {
      final Directory dir = await _dir();
      final File f = File(p.join(dir.path, fileNameFor(key)));
      await f.writeAsBytes(bytes, flush: false);
      // 每 16 次写抽查一次容量（避免每写都列目录）；测试可用 debugTrimNow 直调。
      if ((_writeCounter = (_writeCounter + 1) & 15) == 0) {
        await _trim(dir);
      }
    } catch (_) {
      // 磁盘满 / 权限拒绝 → 忽略，下次再拉再试。
    }
  }

  static int _writeCounter = 0;

  /// 超过 [maxEntries] 时删最旧（mtime 升序）的溢出部分。尽力而为。
  static Future<void> _trim(Directory dir) async {
    try {
      final List<File> files = <File>[
        for (final FileSystemEntity e in dir.listSync())
          if (e is File) e,
      ];
      if (files.length <= maxEntries) return;
      files.sort((File a, File b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      for (final File f in files.take(files.length - maxEntries)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 测试可见：立即执行一次容量修剪。
  @visibleForTesting
  static Future<void> debugTrimNow() async => _trim(await _dir());
}
