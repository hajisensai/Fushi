// 封面解码缓存驱逐断言共享 helper（BUG-1118 抽取）。
//
// 「同路径覆盖写后必须双键驱逐解码缓存」不变量（见 MediaCoverService 类注释）：
// 裸 FileImage 键 + resizedFileImage 的 ResizeImage 键是两个不同的 ImageCache
// key，只清其一则走另一条渲染路径的卡片重建仍命中旧解码。本文件从
// test/media/media_cover_service_test.dart 提取五个断言 helper，供刮削链路
// （cover_downloader / cover_scraper_service）等其它落盘点的测试复用。

import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/cover_image.dart';

/// 把 [provider] 真实解码进 ImageCache（等待首帧完成），模拟卡片渲染过一次。
Future<void> resolveIntoCache(ImageProvider provider) async {
  final Completer<void> done = Completer<void>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      info.dispose();
      if (!done.isCompleted) done.complete();
    },
    onError: (Object error, StackTrace? _) {
      if (!done.isCompleted) done.completeError(error);
    },
  );
  stream.addListener(listener);
  await done.future;
  stream.removeListener(listener);
}

/// [path] 的裸 FileImage 键是否还在 ImageCache。
Future<bool> fileImageCached(String path) async {
  final Object key =
      await FileImage(File(path)).obtainKey(ImageConfiguration.empty);
  return PaintingBinding.instance.imageCache.containsKey(key);
}

/// [path] 的降采样（ResizeImage）键是否还在 ImageCache。
Future<bool> resizedImageCached(String path) async {
  final Object key =
      await resizedFileImage(File(path)).obtainKey(ImageConfiguration.empty);
  return PaintingBinding.instance.imageCache.containsKey(key);
}

/// 把 [path] 的两个键都真实解码进缓存并断言在场（驱逐断言的前置状态）。
Future<void> populateBothCoverKeys(String path) async {
  await resolveIntoCache(FileImage(File(path)));
  await resolveIntoCache(resizedFileImage(File(path)));
  expect(await fileImageCached(path), isTrue, reason: '前置：裸 FileImage 键已入缓存');
  expect(await resizedImageCached(path), isTrue,
      reason: '前置：ResizeImage 键已入缓存');
}

/// 断言 [path] 的两个键都已被驱逐。
Future<void> expectBothCoverKeysEvicted(String path) async {
  expect(await fileImageCached(path), isFalse,
      reason: '覆盖写后裸 FileImage 键必须被驱逐');
  expect(await resizedImageCached(path), isFalse,
      reason: '覆盖写后 ResizeImage（降采样）键必须被驱逐——旧缺陷只清 FileImage 键');
}
