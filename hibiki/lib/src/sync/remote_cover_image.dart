import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:hibiki/src/sync/remote_cover_fetcher.dart';

export 'package:hibiki/src/sync/remote_cover_fetcher.dart';

/// 对「互联」远端封面 URL 复用钉扎客户端拉取的 [ImageProvider]（TODO-1235）。
///
/// 缓存键只取 [coverUrl]（[fetcher] 是 app 单例 backend，不入键），故同一封面在多次
/// rebuild / 多张卡片间经 Flutter [ImageCache] 天然去重、不重复拉取（满足「按 id
/// 缓存避免重复拉」）。https 钉扎与 http 明文分流全在 [fetcher] 内部按 URL scheme +
/// 指纹是否存在决定，UI 不做平台/scheme 分支（好品味：消除特殊情况）。
@immutable
class RemoteCoverImage extends ImageProvider<RemoteCoverImage> {
  const RemoteCoverImage(this.coverUrl, this.fetcher, {this.scale = 1.0});

  final String coverUrl;
  final RemoteCoverFetcher fetcher;
  final double scale;

  @override
  Future<RemoteCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<RemoteCoverImage>(this);

  @override
  ImageStreamCompleter loadImage(
    RemoteCoverImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.coverUrl,
    );
  }

  Future<ui.Codec> _loadAsync(
    RemoteCoverImage key,
    ImageDecoderCallback decode,
  ) async {
    final Uint8List bytes = await key.fetcher.fetchRemoteCover(key.coverUrl);
    if (bytes.isEmpty) {
      throw StateError('Remote cover ${key.coverUrl} returned no bytes');
    }
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteCoverImage &&
      other.coverUrl == coverUrl &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(coverUrl, scale);
}
