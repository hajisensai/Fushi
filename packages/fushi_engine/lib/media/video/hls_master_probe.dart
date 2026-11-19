/// HLS master playlist 的联网探测：取一次播放列表正文，是 master 就解析出各档画质。
///
/// 与 `m3u8_playlist.dart` 的纯解析分开放——那边不碰 IO；本文件由它 `export`，播放页
/// 沿用原有的一条 import 即可用到。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 探测整程（建连 + 取正文）的上限。画质菜单是起播后的可选增强，不值得久等。
const Duration kHlsMasterProbeTimeout = Duration(seconds: 8);

/// 探测请求拿到了非 200 应答。
class HlsMasterProbeStatusException implements Exception {
  const HlsMasterProbeStatusException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'HlsMasterProbeStatusException: HTTP $statusCode';
}

/// IO：GET [uri]，正文是 HLS master 时返回各档画质（高到低，
/// [sortedHlsVariantsByQualityDesc]）；是媒体播放列表（单码率）时返回空表。
///
/// 出站走应用代理出口（[createAppHttpIoClient]，BUG-4805）：此前用顶层 `http.get`，
/// 那是默认 `IOClient`，只认环境变量代理，不认 GUI 系统代理与用户手填的代理——播放
/// 内核经应用代理放得出来的流，这里却连不上，画质菜单静默消失。
///
/// 失败一律**抛出**（非 200 → [HlsMasterProbeStatusException]，超时 →
/// [TimeoutException]，连接失败 → `SocketException` 等），由调用方决定怎么降级并记
/// 日志；本函数不吞异常。[httpClient] 仅供测试注入（注入的 client 不由本函数关闭）。
Future<List<HlsVariant>> fetchHlsMasterVariants(
  Uri uri, {
  Map<String, String> headers = const <String, String>{},
  Duration timeout = kHlsMasterProbeTimeout,
  http.Client? httpClient,
}) async {
  final http.Client client = httpClient ?? createAppHttpIoClient();
  try {
    final http.Response response = await client
        .get(uri, headers: headers.isEmpty ? null : headers)
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw HlsMasterProbeStatusException(response.statusCode);
    }
    final String content = response.body;
    if (!isHlsMasterPlaylist(content)) return const <HlsVariant>[];
    return sortedHlsVariantsByQualityDesc(
      parseM3u8Master(content: content, baseUrl: uri.toString()),
    );
  } finally {
    // 超时后请求仍挂着：关掉自建的 client 才会真的取消它。
    if (httpClient == null) client.close();
  }
}
