import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/utils/net/app_http.dart';

/// 走应用代理出口的网络图片 provider（BUG-1715）。
///
/// `NetworkImage` 用的是 Flutter 内部的 `HttpClient`，结构上接不进
/// `app_proxy.dart` 的出站代理层（该文件头注「结构上注入不了代理的」名单里
/// 点名的就是它）。于是同一页面上会出现「索引拉得到、图片拉不到」的割裂：
/// 扩展仓库索引经 `createAppHttpIoClient()` 能走代理拉到，逐条扩展的图标却由
/// `Image.network` 直连 raw.githubusercontent.com——直连不通的桌面机器上整个
/// 列表全是占位图标，而 Android 上全局 VPN 盖住了所有流量所以看不出来。
///
/// 本 provider 与商店索引共用同一条出口策略（`env > GUI 系统代理 > DIRECT`，
/// 用户手填优先，本机/局域网恒直连）；解码后的图片照常进 Flutter 全局
/// ImageCache（keyed by url+scale），滚动往返不重复请求。
@immutable
class AppHttpImage extends ImageProvider<AppHttpImage> {
  const AppHttpImage(this.url, {this.scale = 1.0});

  /// 图片地址（http/https）。
  final String url;

  final double scale;

  @override
  Future<AppHttpImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AppHttpImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AppHttpImage key,
    ImageDecoderCallback decode,
  ) =>
      MultiFrameImageStreamCompleter(
        codec: _loadCodec(key, decode),
        scale: key.scale,
        debugLabel: key.url,
        informationCollector: () => <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<String>('URL', key.url),
        ],
      );

  Future<ui.Codec> _loadCodec(
    AppHttpImage key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final http.Client client = createAppHttpIoClient();
      try {
        final Uri uri = Uri.parse(key.url);
        final http.Response response = await client.get(uri);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw NetworkImageLoadException(
            statusCode: response.statusCode,
            uri: uri,
          );
        }
        final Uint8List bytes = response.bodyBytes;
        if (bytes.isEmpty) {
          throw NetworkImageLoadException(
            statusCode: response.statusCode,
            uri: uri,
          );
        }
        return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      } finally {
        client.close();
      }
    } catch (_) {
      // 与 NetworkImage 同款语义：失败的加载不能留在全局 ImageCache 里，
      // 否则一次瞬时网络错误会把这张图钉死成永久破图。
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AppHttpImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'AppHttpImage')}("$url", scale: $scale)';
}
