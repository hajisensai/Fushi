import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// https://stackoverflow.com/questions/67963713/how-to-cache-memory-image-using-image-memory-or-memoryimage-flutter
class CacheImageProvider extends ImageProvider<CacheImageProvider> {
  /// Make an [ImageProvider] that caches [MemoryImage].
  CacheImageProvider(this.tag, this.img) : _imgHash = _hashBytes(img);

  /// The cache id use to get cache.
  final String tag;

  /// The bytes of image to cache.
  final Uint8List img;

  /// HBK-AUDIT-148: 内容指纹，参与缓存键。之前 ==/hashCode 只看 [tag]，
  /// 当同一 [tag] 对应的封面字节变化时，Flutter image cache 会把新 provider
  /// 判为与旧的相等，从而返回过期的解码图。这里在构造时一次性算出字节摘要，
  /// 避免每次缓存查找都做整段比较，又能让字节变化产生不同的键。
  final int _imgHash;

  /// 便宜但足够区分内容的字节摘要：混合长度与若干采样字节。
  static int _hashBytes(Uint8List bytes) {
    final int length = bytes.length;
    if (length == 0) return 0;
    // 最多采样 32 个均匀分布的字节，避免大封面逐字节哈希的开销。
    const int maxSamples = 32;
    final int step = length <= maxSamples ? 1 : length ~/ maxSamples;
    int hash = length;
    for (int i = 0; i < length; i += step) {
      hash = 0x1fffffff & (hash * 31 + bytes[i]);
    }
    return hash;
  }

  @override
  ImageStreamCompleter loadImage(
      CacheImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode),
      scale: 1,
      debugLabel: tag,
      informationCollector: () sync* {
        yield ErrorDescription('Tag: $tag');
      },
    );
  }

  Future<ui.Codec> _loadAsync(ImageDecoderCallback decode) async {
    final Uint8List bytes = img;

    if (bytes.lengthInBytes == 0) {
      PaintingBinding.instance.imageCache.evict(this);
      throw StateError('$tag is empty and cannot be loaded as an image.');
    }

    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  Future<CacheImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CacheImageProvider>(this);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    // HBK-AUDIT-148: 同时比较 tag 与内容摘要（含字节长度），字节变化即视为不同键。
    return other is CacheImageProvider &&
        other.tag == tag &&
        other._imgHash == _imgHash &&
        other.img.length == img.length;
  }

  @override
  int get hashCode => Object.hash(tag, _imgHash, img.length);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'CacheImageProvider')}("$tag")';
}
