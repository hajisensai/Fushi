import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/utils/net/app_http.dart';

/// 走应用代理出口的网络图片 provider（BUG-1715）。
///
/// `NetworkImage` 用的是 Flutter 内部的 `HttpClient`，结构上接不进
/// 应用的出站代理层。于是同一页面上会出现「索引拉得到、图片拉不到」的割裂：
/// 扩展仓库索引经 `createAppHttpIoClient()` 能走代理拉到，逐条扩展的图标却由
/// `Image.network` 直连 raw.githubusercontent.com——直连不通的桌面机器上整个
/// 列表全是占位图标，而 Android 上全局 VPN 盖住了所有流量所以看不出来。
///
/// 本 provider 与商店索引共用同一条出口策略（`env > GUI 系统代理 > DIRECT`，
/// 用户手填优先，本机/局域网恒直连）；解码后的图片照常进 Flutter 全局
/// ImageCache（keyed by url+scale+headers），滚动往返不重复请求。
@immutable
class AppHttpImage extends ImageProvider<AppHttpImage> {
  const AppHttpImage(this.url, {this.scale = 1.0, this.headers});

  /// 图片地址（http/https）。
  final String url;

  final double scale;

  /// 源站所需的 User-Agent / Referer；传入后不得修改。
  final Map<String, String>? headers;

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
        final http.Response response = await client.get(
          uri,
          headers: key.headers,
        );
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
      other is AppHttpImage &&
      other.url == url &&
      other.scale == scale &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
        url,
        scale,
        headers == null
            ? null
            : Object.hashAllUnordered(
                headers!.entries.map(
                  (MapEntry<String, String> entry) =>
                      Object.hash(entry.key, entry.value),
                ),
              ),
      );

  @override
  String toString() =>
      '${objectRuntimeType(this, 'AppHttpImage')}("$url", scale: $scale)';
}

/// 磁盘缓存图片只替换 HTTP 装配，保留原 provider 的 key、缩放及错误语义。
class AppCachedHttpImage extends CachedNetworkImageProvider {
  AppCachedHttpImage(
    super.url, {
    super.scale,
    super.headers,
    super.cacheKey,
    super.maxWidth,
    super.maxHeight,
    super.errorListener,
  }) : super(cacheManager: AppImageCacheManager());
}

/// 与原默认缓存共享磁盘命名空间，已有封面无需重新下载。
class AppImageCacheManager extends CacheManager with ImageCacheManager {
  AppImageCacheManager._()
      : super(
          Config(DefaultCacheManager.key, fileService: AppImageFileService()),
        );

  static final AppImageCacheManager _instance = AppImageCacheManager._();

  factory AppImageCacheManager() => _instance;
}

/// 每次缓存缺失/更新都重新装配客户端，代理与认证的设置变更立即生效。
class AppImageFileService extends FileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final http.Client client = createAppHttpIoClient();
    try {
      final http.Request request = http.Request('GET', Uri.parse(url));
      if (headers != null) request.headers.addAll(headers);
      final http.StreamedResponse response = await client.send(request);
      // CacheManager 仅消费 200/202 正文，304 与错误响应须主动释放连接。
      final bool hasImage =
          response.statusCode == 200 || response.statusCode == 202;
      if (!hasImage) {
        await response.stream.listen(null).cancel();
        client.close();
      }
      return HttpGetResponse(
        http.StreamedResponse(
          hasImage
              ? _closeAfter(response.stream, client)
              : const Stream<List<int>>.empty(),
          response.statusCode,
          headers: response.headers,
          contentLength: response.contentLength,
          request: response.request,
          reasonPhrase: response.reasonPhrase,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
        ),
      );
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  Stream<List<int>> _closeAfter(
    Stream<List<int>> bytes,
    http.Client client,
  ) async* {
    try {
      yield* bytes;
    } finally {
      client.close();
    }
  }
}
