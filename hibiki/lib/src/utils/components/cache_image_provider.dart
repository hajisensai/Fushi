import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// https://stackoverflow.com/questions/67963713/how-to-cache-memory-image-using-image-memory-or-memoryimage-flutter
class CacheImageProvider extends ImageProvider<CacheImageProvider> {
  /// Make an [ImageProvider] that caches [MemoryImage].
  CacheImageProvider(this.tag, this.img);

  /// The cache id use to get cache.
  final String tag;

  /// The bytes of image to cache.
  final Uint8List img;

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
    bool res = other is CacheImageProvider && other.tag == tag;
    return res;
  }

  @override
  int get hashCode => tag.hashCode;

  @override
  String toString() =>
      '${objectRuntimeType(this, 'CacheImageProvider')}("$tag")';
}
