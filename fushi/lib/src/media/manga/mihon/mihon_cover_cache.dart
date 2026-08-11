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
    this.maxBytes = 64 * 1024 * 1024,
    this.maxAge = const Duration(days: 30),
  })  : assert(maxEntries > 0),
        assert(maxBytes > 0);

  final Directory directory;
  final int maxEntries;

  /// 目录字节预算。只有条数上限时，单张 2-5MB 的源能把封面目录撑到 GB 级。
  final int maxBytes;
  final Duration maxAge;
  final Map<String, _SharedCoverLoad> _inFlight = <String, _SharedCoverLoad>{};
  Future<void>? _trimming;
  bool _trimAgain = false;

  /// 取回封面字节；同 key 的并发请求共享同一次磁盘读/网络取。
  ///
  /// [isActive] 是**调用方自己**是否还需要这张图（widget 未 dispose 等）。取消
  /// 判据属于缓存层而不是某一个调用方：共享请求只有在**所有**订阅者都退场时才
  /// 取消，否则先发起的 widget 一滚出屏幕，就会把还在等同一张图的其它 widget
  /// 一起打成破图。传 `null` 表示调用方没有生命周期，永远算活跃。
  ///
  /// [fetch] 收到的 `stillWanted` 必须在真正发请求前（例如拿到并发队列名额之
  /// 后）复查一次，这样排队期间整批退场的封面仍然不会打到漫画源。
  Future<Uint8List> load({
    required String extensionPackage,
    required String sourceId,
    required String url,
    required Future<Uint8List> Function(bool Function() stillWanted) fetch,
    bool Function()? isActive,
  }) {
    final String key = mihonCoverCacheKey(
      extensionPackage: extensionPackage,
      sourceId: sourceId,
      url: url,
    );
    final _SharedCoverLoad? active = _inFlight[key];
    if (active != null) {
      active.subscribe(isActive);
      return active.future;
    }

    final _SharedCoverLoad shared = _SharedCoverLoad()..subscribe(isActive);
    final Future<Uint8List> future = _load(
      key,
      () => fetch(shared.stillWanted),
    );
    shared.future = future;
    _inFlight[key] = shared;
    return future.whenComplete(() {
      if (identical(_inFlight[key], shared)) _inFlight.remove(key);
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
      unawaited(_scheduleTrim());
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
      // flush: true 才能保证 rename 之后落盘的是完整字节；否则崩溃/断电会留下
      // 截断文件，而 _readFresh 只判非空，坏封面能在缓存里赖 maxAge 那么久。
      await temporary.writeAsBytes(bytes, flush: true);
      // rename 本身就是覆盖式替换，先 delete 只会制造「目标不存在」的窗口。
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

  /// 串行化容量整理：一屏几十张封面同时写盘时，不能各自触发一次目录遍历。
  Future<void> _scheduleTrim() {
    final Future<void>? running = _trimming;
    if (running != null) {
      _trimAgain = true;
      return running;
    }
    final Future<void> next = _trim().whenComplete(() {
      _trimming = null;
      if (_trimAgain) {
        _trimAgain = false;
        unawaited(_scheduleTrim());
      }
    });
    _trimming = next;
    return next;
  }

  Future<void> _trim() async {
    try {
      if (!await directory.exists()) return;
      final List<File> files = await directory
          .list()
          .where((FileSystemEntity entity) => entity is File)
          .cast<File>()
          .toList();
      final List<({File file, DateTime modified, int length})> ranked =
          <({File file, DateTime modified, int length})>[];
      int totalBytes = 0;
      for (final File file in files) {
        final FileStat stat = await file.stat();
        totalBytes += stat.size;
        ranked.add((file: file, modified: stat.modified, length: stat.size));
      }
      if (ranked.length <= maxEntries && totalBytes <= maxBytes) return;
      // 按写入时间升序淘汰。这里刻意不做 LRU：把访问也算进排序需要在命中时回写
      // mtime，那会同时重置 maxAge 的过期时钟（常看的封面永不刷新），而 atime 在
      // Windows 上默认不更新、不可信。
      ranked.sort((left, right) => left.modified.compareTo(right.modified));
      int remaining = ranked.length;
      for (final ({File file, DateTime modified, int length}) entry in ranked) {
        if (remaining <= maxEntries && totalBytes <= maxBytes) break;
        await entry.file.delete();
        remaining--;
        totalBytes -= entry.length;
      }
    } on FileSystemException {
      // 并发清理/权限变化不应影响封面显示。
    }
  }
}

/// 一次共享的封面取回；订阅者只影响「是否还有人要」，不影响结果本身。
class _SharedCoverLoad {
  final List<bool Function()> _subscribers = <bool Function()>[];
  late final Future<Uint8List> future;

  void subscribe(bool Function()? isActive) {
    _subscribers.add(isActive ?? _alwaysActive);
  }

  bool stillWanted() =>
      _subscribers.any((bool Function() isActive) => isActive());

  static bool _alwaysActive() => true;
}

String mihonCoverCacheKey({
  required String extensionPackage,
  required String sourceId,
  required String url,
}) =>
    sha256
        .convert(utf8.encode('$extensionPackage\u0000$sourceId\u0000$url'))
        .toString();
