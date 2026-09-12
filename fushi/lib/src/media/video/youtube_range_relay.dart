import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 本地有界分块中继：把 googlevideo 「只接受有界 `Range`」的直链翻成普通可 seek 的
/// HTTP 流交给 libmpv / ffmpeg（BUG-2491）。
///
/// ## 为什么必须有它
///
/// youtube_explode 现在能签出流的只剩 `android` client（androidVr / tv 被 YouTube 判
/// unplayable、ios 首流 403），而 `android` 签发的 googlevideo 直链（query 带 `rqh=1`）
/// **只接受有界区间** `Range: bytes=a-b`：无 `Range` 与开放区间 `bytes=0-` 一律 403
/// （真机探针：同一 URL 同一 UA，`bytes=0-65535` → 206，`bytes=0-` → 403）。libmpv 的
/// curl 后端与 ffmpeg 的 http 首请求都是无 Range / 开放区间，于是 `[curl] HTTP error 403`
/// → 「Failed to open」→ 用户看到的「YouTube 视频打不开」。youtube_explode 自己的下载器
/// 也是按 `bytes=from-to` 分块下的（`youtube_http_client.dart` `getStream`），它早就知道
/// 这条规则，只是播放内核不知道。
///
/// 解析器的 HEAD 探测能过（HEAD 不受此限），所以解析阶段看不出任何异常；
/// [YoutubeStreamCache] 的 liveness 用 `bytes=0-1` 有界探测，同样看不出。
///
/// ## 它做什么
///
/// [register] 把上游 URL + 回放 header 登记成 `http://127.0.0.1:<port>/yt/<token>`；
/// 播放内核对该地址发的任意请求（无 Range / `bytes=X-` / `bytes=a-b`）都被翻成对上游的
/// **[chunkBytes] 有界分块顺序拉取**，拼成一个带 `Content-Length` / `Content-Range` /
/// `Accept-Ranges` 的响应。seek 天然支持：内核发 `bytes=X-` 就从 X 起分块。上游任何
/// 非 206（URL 过期 403 / 410 等）在首块时原样透传状态码，让内核快速失败而不是黑屏。
///
/// 中继只在交给播放器 / ffmpeg 的边上套（[UrlStreamVideoClient.remoteVideoStreamUrls]、
/// 画质切换、批量制卡）；[YoutubeStreamCache] 与 liveness 探测继续持有原始 URL——本地
/// 端口随进程变，登记表也只活在进程内。
class YoutubeRangeRelay {
  YoutubeRangeRelay._(this._server);

  /// 每次对上游的有界分块大小。googlevideo 对单个区间还有**上限**：真机探针同一 URL
  /// `bytes=0-4194303`（4 MiB）→ 206、`bytes=0-5242879`（5 MiB）起一律 403。取 2 MiB 留
  /// 余量（YouTube 网页播放器自身的分段也是这个量级），4K 码率下约每秒一块，连接
  /// keep-alive 复用，开销可忽略。
  static const int chunkBytes = 2 * 1024 * 1024;

  static Future<YoutubeRangeRelay>? _shared;

  /// 进程内单例。监听 socket 死了（移动端挂起后被系统回收）就另起一个：与
  /// `AppNativeProxy` 的 `_liveProxy` 同一口径，绝不把失败的 Future 缓存成终身答案。
  static Future<YoutubeRangeRelay> instance() async {
    final Future<YoutubeRangeRelay>? cached = _shared;
    if (cached != null) {
      try {
        final YoutubeRangeRelay relay = await cached;
        if (relay.isRunning) return relay;
      } on Object catch (error) {
        debugPrint('[youtube-relay] restarting after $error');
      }
    }
    final Future<YoutubeRangeRelay> started = start();
    _shared = started;
    return started;
  }

  /// 起一个绑定 loopback 随机端口的中继（测试直接调；生产走 [instance]）。
  static Future<YoutubeRangeRelay> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final YoutubeRangeRelay relay = YoutubeRangeRelay._(server);
    server.listen(
      (HttpRequest request) => unawaited(relay._serve(request)),
      onDone: () => relay._closed = true,
      onError: (Object error) {
        relay._closed = true;
        debugPrint('[youtube-relay] listener failed: $error');
      },
    );
    return relay;
  }

  final HttpServer _server;
  final Map<String, _RelayEntry> _entries = <String, _RelayEntry>{};
  final Random _random = Random.secure();
  final HttpClient _upstream = createAppHttpClient()..autoUncompress = false;
  bool _closed = false;

  bool get isRunning => !_closed;

  int get port => _server.port;

  /// 登记一条上游流，返回交给播放内核的本地地址。同一 URL 重复登记复用同一 token。
  Uri register(String upstreamUrl, Map<String, String> headers) {
    for (final MapEntry<String, _RelayEntry> e in _entries.entries) {
      if (e.value.upstream.toString() == upstreamUrl) {
        return _localUri(e.key);
      }
    }
    final String token = base64Url
        .encode(List<int>.generate(18, (int _) => _random.nextInt(256)));
    _entries[token] = _RelayEntry(
      upstream: Uri.parse(upstreamUrl),
      headers: Map<String, String>.unmodifiable(headers),
    );
    return _localUri(token);
  }

  Uri _localUri(String token) => Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _server.port,
        path: '/yt/$token',
      );

  Future<void> close() async {
    _closed = true;
    _upstream.close(force: true);
    await _server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      final List<String> segments = request.uri.pathSegments;
      final _RelayEntry? entry = segments.length == 2 && segments.first == 'yt'
          ? _entries[segments.last]
          : null;
      if (entry == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final ({int start, int? end})? range =
          parseRelayRange(request.headers.value(HttpHeaders.rangeHeader));
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      await _stream(request, entry, range);
    } on Object catch (error) {
      debugPrint('[youtube-relay] ${request.method} failed: $error');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } on Object {
        // 头已发出 / 连接已断：没有响应可写了。
      }
    }
  }

  /// 首块决定响应头（状态、总长、类型），后续块顺序追加。首块非 206 时原样透传状态码。
  Future<void> _stream(
    HttpRequest request,
    _RelayEntry entry,
    ({int start, int? end}) range,
  ) async {
    final HttpResponse response = request.response;
    final bool ranged = request.headers.value(HttpHeaders.rangeHeader) != null;
    int cursor = range.start;
    int? end = range.end;
    int? total;
    bool headersSent = false;
    while (true) {
      final int chunkEnd = min(cursor + chunkBytes - 1, end ?? (1 << 62));
      final HttpClientRequest upstreamRequest =
          await _upstream.getUrl(entry.upstream);
      entry.headers.forEach(upstreamRequest.headers.set);
      upstreamRequest.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$cursor-$chunkEnd',
      );
      final HttpClientResponse upstreamResponse = await upstreamRequest.close();
      if (upstreamResponse.statusCode != HttpStatus.partialContent) {
        // 首块失败：把上游状态码交给内核（403/410 = URL 过期，让它立刻报错而非黑屏）。
        // 中途失败：头已发出，只能断连。
        await upstreamResponse.drain<void>();
        if (headersSent) {
          // 首块能拿、中途被拒（同一 URL 前 N 秒 206、之后一律 403）是 YouTube 对无
          // PO token 客户端的服务端限制（出口 IP 被判「Sign in to confirm you're not
          // a bot」时尤甚），不是本地网络错。落 error_log 让用户/开发者能区分。
          ErrorLogService.instance.log(
            'youtube_relay',
            'upstream ${upstreamResponse.statusCode} mid-stream at byte $cursor '
                '(${entry.upstream.host}): YouTube 拒绝了窗口之外的区间——通常是该网络'
                '出口被 YouTube 要求验证 / 需要 PO token，播放会在此处中断',
          );
          throw HttpException(
            'upstream ${upstreamResponse.statusCode} mid-stream at $cursor',
          );
        }
        response.statusCode = upstreamResponse.statusCode;
        await response.close();
        return;
      }
      final ({int start, int end, int? total})? contentRange =
          parseContentRange(
        upstreamResponse.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (!headersSent) {
        total = contentRange?.total;
        if (total != null) {
          end ??= total - 1;
          end = min(end, total - 1);
        }
        response.statusCode =
            ranged ? HttpStatus.partialContent : HttpStatus.ok;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        final String? type =
            upstreamResponse.headers.value(HttpHeaders.contentTypeHeader);
        if (type != null) {
          response.headers.set(HttpHeaders.contentTypeHeader, type);
        }
        if (end != null) {
          response.headers.contentLength = end - cursor + 1;
          if (ranged) {
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $cursor-$end/${total ?? '*'}',
            );
          }
        }
        headersSent = true;
        if (request.method == 'HEAD') {
          await upstreamResponse.drain<void>();
          await response.close();
          return;
        }
      }
      final int requested = chunkEnd - cursor + 1;
      final int received = await _pipe(upstreamResponse, response);
      cursor += received;
      if (received == 0 || (end != null && cursor > end)) break;
      // 总长未知（上游没给 Content-Range 的 total）时，上游给得比要的少就是到 EOF 了；
      // 总长已知时少给只当是上游截断，按已收位置继续要。
      if (received < requested && end == null) break;
    }
    await response.close();
  }

  /// 把上游一块的字节写给内核，返回实际写出的字节数。内核断连时抛，外层断循环。
  Future<int> _pipe(HttpClientResponse from, HttpResponse to) async {
    int n = 0;
    await for (final List<int> chunk in from) {
      to.add(chunk);
      n += chunk.length;
    }
    await to.flush();
    return n;
  }
}

class _RelayEntry {
  const _RelayEntry({required this.upstream, required this.headers});

  final Uri upstream;
  final Map<String, String> headers;
}

/// 纯函数：解析内核发来的 `Range` 头。null/空 → 从 0 起到末尾；`bytes=a-` → a 起到末尾；
/// `bytes=a-b` → 闭区间；后缀区间 `bytes=-N` 与多区间不支持 → null（416）。
({int start, int? end})? parseRelayRange(String? header) {
  if (header == null || header.isEmpty) return (start: 0, end: null);
  final RegExpMatch? m =
      RegExp(r'^\s*bytes\s*=\s*(\d+)\s*-\s*(\d*)\s*$').firstMatch(header);
  if (m == null) return null;
  final int start = int.parse(m.group(1)!);
  final String endText = m.group(2)!;
  if (endText.isEmpty) return (start: start, end: null);
  final int end = int.parse(endText);
  if (end < start) return null;
  return (start: start, end: end);
}

/// 纯函数：解析上游 `Content-Range: bytes a-b/total`（total 可为 `*`）。
({int start, int end, int? total})? parseContentRange(String? header) {
  if (header == null) return null;
  final RegExpMatch? m =
      RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$').firstMatch(header);
  if (m == null) return null;
  final String totalText = m.group(3)!;
  return (
    start: int.parse(m.group(1)!),
    end: int.parse(m.group(2)!),
    total: totalText == '*' ? null : int.parse(totalText),
  );
}

/// 「原始流 URL + 回放 header → 交给播放内核的 URL」签名。生产 [relayYoutubeStreamUrl]，
/// 测试注入假件。
typedef YoutubeStreamRelay = Future<String> Function(
  String url,
  Map<String, String> headers,
);

/// 把 YouTube 直链换成本地中继地址（BUG-2491）。非 googlevideo 直链原样返回。
///
/// 只认 host 以 `googlevideo.com` 结尾的 URL：YouTube 的 timedtext / 缩略图等不经此，
/// 也不会把用户粘贴的普通直链 / HLS 无谓地绕进本地中继。
Future<String> relayYoutubeStreamUrl(
  String url,
  Map<String, String> headers,
) async {
  if (!isYoutubeMediaStreamUrl(url)) return url;
  final YoutubeRangeRelay relay = await YoutubeRangeRelay.instance();
  return relay.register(url, headers).toString();
}

/// 纯函数：是否 googlevideo 媒体直链（需经 [YoutubeRangeRelay]）。
bool isYoutubeMediaStreamUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  final String host = uri.host.toLowerCase();
  return host == 'googlevideo.com' || host.endsWith('.googlevideo.com');
}
