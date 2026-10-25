import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// 取一张遥控封面的字节（电脑 `episodeCover` 操作）；没有封面返回 null。
typedef VideoRemoteCoverLoader = Future<Uint8List?> Function();

/// 电脑经遥控操作（而不是互联库的封面端点）给出的封面：按 [cacheKey] 进全局
/// 图片缓存，同一张封面滚出又滚回、重开弹层都不再问电脑。[cacheKey] 由调用方
/// 拼上电脑身份与条目身份（换电脑 / 换集不串图）；[load] 不参与相等判断。
///
/// 选集的封面可能来自媒体服务器（不在电脑的视频库里），没有互联库封面端点可用，
/// 所以走遥控通道、只进内存缓存。
@immutable
class VideoRemoteCoverImage extends ImageProvider<VideoRemoteCoverImage> {
  const VideoRemoteCoverImage({required this.cacheKey, required this.load});

  final String cacheKey;
  final VideoRemoteCoverLoader load;

  @override
  Future<VideoRemoteCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<VideoRemoteCoverImage>(this);

  @override
  ImageStreamCompleter loadImage(
    VideoRemoteCoverImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _decode(key, decode),
    scale: 1,
    debugLabel: 'VideoRemoteCoverImage(${key.cacheKey})',
  );

  static Future<ui.Codec> _decode(
    VideoRemoteCoverImage key,
    ImageDecoderCallback decode,
  ) async {
    final Uint8List? bytes = await key.load();
    if (bytes == null || bytes.isEmpty) {
      // 失败不进缓存（ImageCache 只留成功的帧），下次进入视野会重新问。
      throw StateError('video remote cover missing: ${key.cacheKey}');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is VideoRemoteCoverImage && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;

  @override
  String toString() => 'VideoRemoteCoverImage($cacheKey)';
}
