import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/redirect_headers.dart';
import 'package:fushi/src/utils/net/transient_fetch_retry.dart';

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
  ) => MultiFrameImageStreamCompleter(
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
///
/// 元数据仓库（`repo`）默认交给 flutter_cache_manager 按**宿主平台**选：
/// Android / iOS / macOS 是 sqflite 的 `CacheObjectProvider`（与原默认缓存同一个
/// 库文件），其余平台是 `JsonCacheInfoRepository`。生产里必须保持这个默认，否则
/// 与 [DefaultCacheManager] 共享的命名空间会裂成两份索引。
///
/// 但 `flutter test` 跑在宿主 VM 上：macOS 宿主的 `Platform.isMacOS` 为真，库会
/// 去开 sqflite 平台插件，而测试进程里没有这个插件（「databaseFactory not
/// initialized」）。所以单例首次构造前可经 [debugRepositoryOverride] 注入仓库，
/// 由测试装配（`test/flutter_test_config.dart`）统一换成与宿主无关的实现。
class AppImageCacheManager extends CacheManager with ImageCacheManager {
  AppImageCacheManager._(CacheInfoRepository? repo)
    : super(
        // Config 的 repo 形参不可空（缺省才走平台默认），所以按有无注入分两种构造。
        repo == null
            ? Config(
                DefaultCacheManager.key,
                fileService: AppImageFileService(),
              )
            : Config(
                DefaultCacheManager.key,
                repo: repo,
                fileService: AppImageFileService(),
              ),
      );

  static AppImageCacheManager? _instance;

  /// 单例首次构造时用它造元数据仓库（入参为数据库名）；`null` = 库的平台默认。
  /// 只在测试装配里设置，且必须早于第一次 `AppImageCacheManager()`。
  @visibleForTesting
  static CacheInfoRepository Function(String databaseName)?
  debugRepositoryOverride;

  factory AppImageCacheManager() => _instance ??= AppImageCacheManager._(
    debugRepositoryOverride?.call(DefaultCacheManager.key),
  );
}

/// 磁盘缓存图片的首响应 / 正文空闲超时（BUG-2450）。
///
/// 出站客户端只有 20s 的 TCP connect 超时：连上之后服务端不吐响应头、或正文
/// 中途断流，请求会永远挂着——既到不了失败态、也轮不到退避重试。空闲超时按
/// 数据块重置，慢但仍在持续返回数据的大图不会被整包倒数切断。
const Duration kAppImageHeaderTimeout = Duration(seconds: 60);
const Duration kAppImageIdleTimeout = Duration(seconds: 60);

/// 每次缓存缺失/更新都重新装配客户端，代理与认证的设置变更立即生效。
///
/// 超时 / socket 错误 / 5xx 按 [retryBackoff] 自动退避重试（`retryTransient`）；
/// 4xx 与其它结构性错误照旧一次交给 CacheManager 落到 errorBuilder。
class AppImageFileService extends FileService {
  AppImageFileService({
    this.retryBackoff = kCoverFetchRetryBackoff,
    this.retryWait = retryWaitReal,
  });

  final List<Duration> retryBackoff;
  final RetryWait retryWait;

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) =>
      retryTransient<FileServiceResponse>(
        () => _getOnce(url, headers: headers),
        backoff: retryBackoff,
        wait: retryWait,
      );

  Future<FileServiceResponse> _getOnce(
    String url, {
    Map<String, String>? headers,
  }) async {
    final http.Client client = createAppHttpIoClient();
    try {
      // 重定向逐跳手动跟随：封面请求可能带私有目录的凭据头（OPDS 的
      // `X-API-Key`，BUG-3535 / BUG-3521），而 dart:io 自动跟随跨 origin 只剥
      // `Authorization` / `Cookie`，其它凭据头会被原样转发给 302 指向的 CDN。
      Uri current = Uri.parse(url);
      Map<String, String> currentHeaders = headers ?? const <String, String>{};
      http.Request request;
      http.StreamedResponse response;
      for (int hop = 0; ; hop++) {
        request = http.Request('GET', current)..followRedirects = false;
        request.headers.addAll(currentHeaders);
        response = await client.send(request).timeout(kAppImageHeaderTimeout);
        final String? location = response.headers['location'];
        if (!isFollowableRedirectStatus(response.statusCode) ||
            location == null ||
            location.trim().isEmpty ||
            hop >= kMaxManualRedirects) {
          break;
        }
        await response.stream.listen(null).cancel();
        final Uri next = current.resolve(location.trim());
        currentHeaders = headersForRedirectHop(
          currentHeaders,
          from: current,
          to: next,
        );
        current = next;
      }
      // CacheManager 仅消费 200/202 正文，304 与错误响应须主动释放连接。
      final bool hasImage =
          response.statusCode == 200 || response.statusCode == 202;
      if (!hasImage) {
        await response.stream.listen(null).cancel();
        client.close();
        if (response.statusCode >= 500) {
          // 5xx 是瞬时故障：抛给退避层重试。梯度耗尽后仍以 CacheManager 自己
          // 对非 2xx 响应抛的同一异常类型落到 errorBuilder，调用方语义不变。
          throw HttpExceptionWithStatus(
            response.statusCode,
            'Invalid statusCode: ${response.statusCode}',
            uri: request.url,
          );
        }
      }
      return HttpGetResponse(
        http.StreamedResponse(
          hasImage
              ? _closeAfter(
                  response.stream.timeout(kAppImageIdleTimeout),
                  client,
                )
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
