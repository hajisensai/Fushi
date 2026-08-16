import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:fushi/src/sync/remote_cover_cache.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';

export 'package:fushi/src/sync/remote_cover_fetcher.dart';

/// 对「互联」远端封面 URL 复用钉扎客户端拉取的 [ImageProvider]（TODO-1235）。
///
/// 缓存分两层（BUG-847）：
///  1. **进程内 [ImageCache]**：键取 [cacheKey]（稳定 id，非易变 [coverUrl]），故换 IP /
///     http↔https 让 URL 变化也不会在内存里重复占位；[cacheKey] 为空时退回按 [coverUrl] 键控。
///  2. **磁盘读盘缓存 [RemoteCoverCache]**：[cacheKey] 非空时 [_loadAsync] 先查
///     `<temp>/remote_cover_cache/`，命中直接读盘（跨重启存活），未命中才走 [fetcher] 拉网并落盘。
///
/// https 钉扎与 http 明文分流全在 [fetcher] 内部按 URL scheme + 指纹是否存在决定，UI 不做
/// 平台/scheme 分支（好品味：消除特殊情况）。字节必须经 [fetcher]（钉扎）拉，不能用
/// `NetworkToFileImage`——后者走 Flutter 内部 `HttpClient` 无 `badCertificateCallback`，
/// 自签 https 握手必失败（BUG-569 当初弃用它的原因）。
@immutable
class RemoteCoverImage extends ImageProvider<RemoteCoverImage> {
  const RemoteCoverImage(
    this.coverUrl,
    this.fetcher, {
    this.scale = 1.0,
    this.cacheKey,
  });

  final String coverUrl;
  final RemoteCoverFetcher fetcher;
  final double scale;

  /// 稳定缓存键（video.id / book identifier）。非空 → 启用磁盘读盘缓存并作为内存去重键；
  /// 空 → 退回按 [coverUrl] 键控、仅内存缓存（旧行为）。
  final String? cacheKey;

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
    // 磁盘键带上来源命名空间（BUG-1693 批审计：跨对端串味）：两台对端的同名
    // 条目不再共用同一个缓存文件；重新配对（token 换）后旧对端的封面不再顶包。
    final String? ck = key.cacheKey == null
        ? null
        : '${key.fetcher.coverCacheNamespace}|${key.cacheKey}';
    // 1) 读盘缓存命中：直接解码，不发网络。
    if (ck != null) {
      final Uint8List? cached = await RemoteCoverCache.read(ck);
      if (cached != null) {
        final ui.ImmutableBuffer buffer =
            await ui.ImmutableBuffer.fromUint8List(cached);
        return decode(buffer);
      }
    }
    // 2) 未命中：钉扎拉网，成功后落盘（尽力而为，写失败已内部吞）。
    final Uint8List bytes = await key.fetcher.fetchRemoteCover(key.coverUrl);
    if (bytes.isEmpty) {
      throw StateError('Remote cover ${key.coverUrl} returned no bytes');
    }
    if (ck != null) {
      await RemoteCoverCache.write(ck, bytes);
    }
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteCoverImage &&
      other.scale == scale &&
      // 内存去重键同样按来源命名空间隔离（换对端后同名 id 不复用旧位图）。
      other.fetcher.coverCacheNamespace == fetcher.coverCacheNamespace &&
      (cacheKey != null
          ? other.cacheKey == cacheKey
          : other.cacheKey == null && other.coverUrl == coverUrl);

  @override
  int get hashCode =>
      Object.hash(fetcher.coverCacheNamespace, cacheKey ?? coverUrl, scale);
}
