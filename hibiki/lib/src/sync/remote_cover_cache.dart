import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

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

  /// 命中返回字节；未命中 / 空文件 / 任何 IO 异常 → null（调用方回退网络）。
  static Future<Uint8List?> read(String key) async {
    try {
      final Directory dir = await _dir();
      final File f = File(p.join(dir.path, fileNameFor(key)));
      if (!await f.exists()) return null;
      final Uint8List bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      // 缓存尽力而为：读损坏 / 权限 / 竞态删除都退回网络，绝不因缓存挂掉封面。
      return null;
    }
  }

  /// 落盘（尽力而为，异常吞掉不影响显示）。空字节不写。
  static Future<void> write(String key, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    try {
      final Directory dir = await _dir();
      final File f = File(p.join(dir.path, fileNameFor(key)));
      await f.writeAsBytes(bytes, flush: false);
    } catch (_) {
      // 磁盘满 / 权限拒绝 → 忽略，下次再拉再试。
    }
  }
}
