/// 统一流票的上游中继（design-imusic-q4：host 上 SFTP / WebDAV / AList 来源的曲目经 host 给已配对设备）。
///
/// host 用自己的来源凭据取上游字节，client 只拿 host 的票地址：凭据不出 host。播放器的 Range（seek）
/// 原样透传给上游，上游的 200 / 206 / 416 与 `Content-Range` / `Content-Length` 原样回给 client，
/// 不在 host 落盘。上游地址由 host 的来源解析器给出（WebDAV 带 Basic 头；SFTP / AList 是解析器换好的
/// http(s) 直链或本机回环地址）。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 透传给上游的请求头（其余一律不带：client 的凭据 / Cookie 与上游无关）。
const List<String> _kForwardRequestHeaders = <String>[
  'range',
  'if-range',
  'accept',
];

/// 透传回 client 的上游响应头。
const List<String> _kForwardResponseHeaders = <String>[
  'content-type',
  'content-length',
  'content-range',
  'accept-ranges',
  'etag',
  'last-modified',
];

/// 测试注入：替换建上游连接用的 [HttpClient]。
@visibleForTesting
HttpClient Function()? libraryMediaRelayClientForTesting;

HttpClient _newClient() {
  final HttpClient Function()? factory = libraryMediaRelayClientForTesting;
  if (factory != null) return factory();
  // 上游是用户自己配置的来源（自建 NAS / WebDAV 常见自签证书）：与本机播放器直连这些来源时
  // 一致（mpv 默认 tls-verify=no），不校验证书；凭据只发往用户配置的那个地址。
  return HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
}

/// 把 [upstream] 中继给 [request]（GET / HEAD）。上游连不上回 502。
Future<shelf.Response> relayLibraryMediaUpstream(
  LibraryMediaUpstream upstream,
  shelf.Request request,
) async {
  final HttpClient client = _newClient();
  final bool head = request.method.toUpperCase() == 'HEAD';
  try {
    final HttpClientRequest out = await client.openUrl(
      head ? 'HEAD' : 'GET',
      upstream.url,
    );
    out.followRedirects = true;
    upstream.headers.forEach(out.headers.set);
    for (final String h in _kForwardRequestHeaders) {
      final String? v = request.headers[h];
      if (v != null) out.headers.set(h, v);
    }
    final HttpClientResponse res = await out.close();
    final Map<String, String> headers = <String, String>{};
    for (final String h in _kForwardResponseHeaders) {
      final String? v = res.headers.value(h);
      if (v != null) headers[h] = v;
    }
    if (res.statusCode >= 400 && res.statusCode != 416) {
      await res.drain<void>();
      client.close(force: true);
      return shelf.Response(502, body: 'Upstream ${res.statusCode}');
    }
    // 客户端断开 / 读完都要关掉上游连接（不然 host 上挂着半截下载）。
    final StreamController<List<int>> body = StreamController<List<int>>(
      onCancel: () => client.close(force: true),
    );
    if (head) {
      await res.drain<void>();
      client.close();
      return shelf.Response(res.statusCode, headers: headers);
    }
    unawaited(
      body
          .addStream(res)
          .then((_) => body.close(), onError: (Object _) => body.close())
          .whenComplete(() => client.close()),
    );
    return shelf.Response(res.statusCode, body: body.stream, headers: headers);
  } on Object catch (e) {
    client.close(force: true);
    return shelf.Response(502, body: 'Upstream unreachable: $e');
  }
}
