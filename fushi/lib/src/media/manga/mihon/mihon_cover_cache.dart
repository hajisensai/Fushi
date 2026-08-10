import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Mihon 在线漫画封面的可丢弃磁盘缓存。
///
/// 封面必须继续经扩展自己的网络栈拉取，不能直接交给 NetworkImage；这里缓存扩展
/// 已返回的字节，让刷新、切页与应用重启不再重复请求漫画站。正文页大图不走本缓存，
/// 避免整章图片挤占封面预算。
class MihonCoverCache {
  MihonCoverCache(
    this.directory, {
    this.maxEntries = 512,
    this.maxAge = const Duration(days: 30),
  }) : assert(maxEntries > 0);

  final Directory directory;
  final int maxEntries;
  final Duration maxAge;
  final Map<String, Future<Uint8List>> _inFlight =
      <String, Future<Uint8List>>{};

  Future<Uint8List> load({
    required String extensionPackage,
    required String sourceId,
    required String url,
    required Future<Uint8List> Function() fetch,
  }) {
    final String key = mihonCoverCacheKey(
      extensionPackage: extensionPackage,
      sourceId: sourceId,
      url: url,
    );
    final Future<Uint8List>? active = _inFlight[key];
    if (active != null) return active;

    final Future<Uint8List> future = _load(key, fetch);
    _inFlight[key] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
  }

  Future<Uint8List> _load(
    String key,
    Future<Uint8List> Function() fetch,
  ) async {
    final File target = File(p.join(directory.path, '$key.cover'));
    final Uint8List? cached = await _readFresh(target);
    if (cached != null) return cached;

    final Uint8List bytes = await fetch();
    if (bytes.isNotEmpty) {
      await _writeAtomically(target, bytes);
      unawaited(_trim());
    }
    return bytes;
  }

  Future<Uint8List?> _readFresh(File file) async {
    try {
      if (!await file.exists()) return null;
      final FileStat stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > maxAge) {
        await file.delete();
        return null;
      }
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
      await file.delete();
    } on FileSystemException {
      // 缓存损坏、被清理或无权限时退回扩展网络栈，不影响漫画浏览。
    }
    return null;
  }

  Future<void> _writeAtomically(File target, Uint8List bytes) async {
    File? temporary;
    try {
      await directory.create(recursive: true);
      temporary = File(
        '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
      );
      await temporary.writeAsBytes(bytes, flush: false);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } on FileSystemException {
      // 磁盘缓存尽力而为；写失败时本次仍直接显示已经取回的字节。
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } on FileSystemException {
        // 清理竞态同样忽略；下次容量整理会处理遗留临时文件。
      }
    }
  }

  Future<void> _trim() async {
    try {
      if (!await directory.exists()) return;
      final List<File> files = await directory
          .list()
          .where((FileSystemEntity entity) => entity is File)
          .cast<File>()
          .toList();
      if (files.length <= maxEntries) return;
      final List<({File file, DateTime modified})> ranked =
          <({File file, DateTime modified})>[];
      for (final File file in files) {
        ranked.add((file: file, modified: (await file.stat()).modified));
      }
      ranked.sort((left, right) => left.modified.compareTo(right.modified));
      for (final ({File file, DateTime modified}) entry
          in ranked.take(ranked.length - maxEntries)) {
        await entry.file.delete();
      }
    } on FileSystemException {
      // 并发清理/权限变化不应影响封面显示。
    }
  }
}

String mihonCoverCacheKey({
  required String extensionPackage,
  required String sourceId,
  required String url,
}) =>
    sha256
        .convert(utf8.encode('$extensionPackage\u0000$sourceId\u0000$url'))
        .toString();
