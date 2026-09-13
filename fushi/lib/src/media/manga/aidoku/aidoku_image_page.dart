/// Aidoku 页表解析与单页取图（纯函数，无阅读会话）。
///
/// 在线漫画改成「先下载再读」后（设计稿 2026-09-12 §3），Aidoku 这边只剩两件事：
/// 把 `AidokuRuntime.getPages` 的原始返回解析成页表，以及按页表取一页字节。取图
/// 逻辑（UA / Referer / cookie jar / 100 MiB 上限）原样从旧 `_AidokuMangaReaderSession`
/// 迁出，只是不再落自己的页缓存——落盘由下载服务统一做。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';

const int _maximumAidokuImageBytes = 100 * 1024 * 1024;

class AidokuImagePage {
  const AidokuImagePage({
    required this.url,
    required this.headers,
    required this.context,
  });

  factory AidokuImagePage.fromJson(Map<String, Object?> json) {
    final Object? content = json['content'];
    if (content is! Map<Object?, Object?>) {
      throw const AidokuRuntimeException(
        'UNSUPPORTED_PAGE',
        'Aidoku returned a page without image content',
      );
    }
    final Object? urlValue = content['Url'];
    if (urlValue is! List<Object?> || urlValue.isEmpty) {
      throw const AidokuRuntimeException(
        'UNSUPPORTED_PAGE',
        'This Aidoku page type is not supported by the manga reader',
      );
    }
    final String originalUrl = urlValue.first?.toString().trim() ?? '';
    final String resolvedUrl = json['request_url']?.toString().trim() ?? '';
    final String url = resolvedUrl.isNotEmpty ? resolvedUrl : originalUrl;
    if (Uri.tryParse(url)?.isScheme('https') != true) {
      throw const AidokuRuntimeException(
        'INVALID_PAGE_URL',
        'Aidoku image pages must use HTTPS',
      );
    }
    final Object? context = urlValue.length > 1 ? urlValue[1] : null;
    final Object? requestHeaders = json['request_headers'];
    return AidokuImagePage(
      url: url,
      headers: requestHeaders is Map<Object?, Object?>
          ? requestHeaders.map(
              (Object? key, Object? value) =>
                  MapEntry<String, String>(key.toString(), value.toString()),
            )
          : const <String, String>{},
      context: context is Map<Object?, Object?>
          ? context.map(
              (Object? key, Object? value) =>
                  MapEntry<String, String>(key.toString(), value.toString()),
            )
          : const <String, String>{},
    );
  }

  final String url;
  final Map<String, String> headers;
  final Map<String, String> context;

  Map<String, String> requestHeaders({String? referer}) {
    final Map<String, String> resolved = <String, String>{
      'User-Agent': kAidokuUserAgent,
      if (referer != null) 'Referer': referer,
      ...headers,
    };
    return resolved.map(
      (String name, String value) => MapEntry<String, String>(
        name,
        _normalizeAidokuRequestHeader(name, value),
      ),
    );
  }

  String get identity {
    final List<String> keys = headers.keys.toList()..sort();
    final Map<String, String> stableHeaders = <String, String>{
      for (final String key in keys) key: headers[key]!,
    };
    return sha256
        .convert(utf8.encode('$url\u001f${jsonEncode(stableHeaders)}'))
        .toString();
  }
}

String _normalizeAidokuRequestHeader(String name, String value) {
  switch (name.toLowerCase()) {
    case 'referer':
    case 'origin':
      final Uri? uri = Uri.tryParse(value);
      if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
        // dart:io rejects non-Latin-1 header values before sending a request.
        // Uri.toString percent-encodes Unicode path/query components while
        // preserving an already valid HTTP URL.
        return uri.toString();
      }
  }
  return value;
}

/// 把 `AidokuRuntime.getPages` 的原始返回解析成可读页表。
///
/// 源浏览页和书架条目走同一份解析，否则两条路径对「哪些 page 形状算可读」的
/// 判断会各自漂移。
List<AidokuImagePage> aidokuImagePagesFrom(List<Object?> raw) {
  final List<AidokuImagePage> pages = raw
      .whereType<Map<Object?, Object?>>()
      .map((Map<Object?, Object?> value) =>
          AidokuImagePage.fromJson(value.cast<String, Object?>()))
      .toList(growable: false);
  if (pages.isEmpty) {
    throw const AidokuRuntimeException(
      'EMPTY_CHAPTER',
      'Aidoku returned no readable image pages for this chapter',
    );
  }
  return pages;
}

/// 取一页字节。
///
/// [client] 由调用方给（必须经 `createAppHttpIoClient()`，公网请求要跟随应用统一
/// 代理出口）；[jar] 非空时补上对该 host 生效的 cookie，让 Cloudflare 放行 cookie
/// 跟到图片 CDN 上——源自己给的 Cookie 头优先（它可能带会话 token）。
Future<Uint8List> fetchAidokuImagePage(
  AidokuImagePage page, {
  required http.Client client,
  String? referer,
  AidokuCookieJar? jar,
}) async {
  final Uri url = Uri.parse(page.url);
  final http.Request request = http.Request('GET', url);
  request.headers.addAll(page.requestHeaders(referer: referer));
  final String? cookie = jar?.cookieHeaderFor(url);
  if (cookie != null &&
      !request.headers.keys
          .any((String name) => name.toLowerCase() == 'cookie')) {
    request.headers[HttpHeaders.cookieHeader] = cookie;
  }
  final http.StreamedResponse response = await client.send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw AidokuRuntimeException(
      'IMAGE_HTTP_${response.statusCode}',
      'Aidoku image request returned HTTP ${response.statusCode}',
    );
  }
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int length = 0;
  await for (final List<int> chunk in response.stream) {
    length += chunk.length;
    if (length > _maximumAidokuImageBytes) {
      throw const AidokuRuntimeException(
        'IMAGE_TOO_LARGE',
        'Aidoku image exceeded the 100 MiB limit',
      );
    }
    bytes.add(chunk);
  }
  if (length == 0) {
    throw const AidokuRuntimeException(
      'IMAGE_EMPTY',
      'Aidoku image response was empty',
    );
  }
  return bytes.takeBytes();
}
