import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 小组件封面缩略图：把 app 里本来就用的 [ImageProvider]（本地文件 / 带鉴权的远程取图器 /
/// 内存图）按 Flutter 自己的解码链缩到 [maxSide] 以内，编成 PNG 写进 App Group。
///
/// 小组件进程有严格的内存上限（大图会让整个组件渲染失败），所以只交缩略图；同一张封面
/// 按 [cacheKey] 命名，已经写过就不再解码。
class HomeWidgetCoverWriter {
  HomeWidgetCoverWriter(this.directory, {this.maxSide = 300});

  /// `<App Group>/home_widgets/`；封面在其下 `covers/`。
  final Directory directory;
  final int maxSide;

  Directory get _covers => Directory('${directory.path}/covers');

  /// 封面文件名：缓存键的 FNV-1a 哈希（键里有路径 / URL，不直接当文件名）。
  static String fileNameFor(String cacheKey) {
    int hash = 0x811c9dc5;
    for (final int unit in utf8.encode(cacheKey)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '${hash.toRadixString(16).padLeft(8, '0')}.png';
  }

  /// 写好（或已存在）返回相对路径 `covers/<name>.png`；解不出来 / 超时返回 null。
  Future<String?> write(String cacheKey, ImageProvider provider) async {
    final String name = fileNameFor(cacheKey);
    final File file = File('${_covers.path}/$name');
    if (file.existsSync()) return 'covers/$name';
    try {
      final ui.Image image = await _decode(provider);
      try {
        final ByteData? png = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) return null;
        await _covers.create(recursive: true);
        await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
        return 'covers/$name';
      } finally {
        image.dispose();
      }
    } on Object catch (e) {
      debugPrint('[home-widgets] cover "$cacheKey" skipped: $e');
      return null;
    }
  }

  /// 删掉这一轮快照不再引用的封面。
  Future<void> prune(Set<String> keep) async {
    if (!_covers.existsSync()) return;
    await for (final FileSystemEntity entity in _covers.list()) {
      if (entity is! File) continue;
      final String rel = 'covers/${entity.uri.pathSegments.last}';
      if (!keep.contains(rel)) {
        try {
          await entity.delete();
        } on FileSystemException {
          // 小组件进程正在读：下一轮再删。
        }
      }
    }
  }

  Future<ui.Image> _decode(ImageProvider provider) {
    final ImageProvider sized = ResizeImage(
      provider,
      width: maxSide,
      height: maxSide,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
    final Completer<ui.Image> completer = Completer<ui.Image>();
    final ImageStream stream = sized.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete(info.image.clone());
        info.dispose();
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        stream.removeListener(listener);
        throw TimeoutException('cover decode');
      },
    );
  }
}
