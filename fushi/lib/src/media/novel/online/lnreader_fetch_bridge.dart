import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 插件不许访问的主机：本机回环。
///
/// 插件是第三方仓库的任意 JS，而 app 自己在本机开着 HTTP 服务（浏览器扩展查词
/// 接口、互联 host 等）；不拦的话，一个恶意插件经宿主桥就能打到这些本机接口。
bool isLnReaderBlockedHost(String host) {
  final String value = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (value == 'localhost' || value.endsWith('.localhost')) return true;
  final InternetAddress? address = InternetAddress.tryParse(value);
  return address != null && (address.isLoopback || address.isLinkLocal);
}

/// LNReader 插件出站请求的宿主端执行者。
///
/// 插件的 `fetchApi` / `fetchText` 在 WebView 里被规整成
/// `{url, method, headers, body(base64)}` 送过来（见 `assets/lnreader/lnreader_host.js`），
/// 这里用 app 的 [HttpClient]（代理装配、系统信任根）真正发出去，回
/// `{status, statusText, url, headers, body(base64)}` 或 `{error}`。
///
/// 为什么不让 WebView 自己 fetch：跨域受 CORS 约束，Referer / Cookie /
/// User-Agent 是禁止头改不了，而且绕开了全应用代理出口。
class LnReaderFetchBridge {
  LnReaderFetchBridge({
    required HttpClient Function() clientFactory,
    this.timeout = const Duration(seconds: 60),
    this.maxBodyBytes = 32 * 1024 * 1024,
    this.isBlockedHost = isLnReaderBlockedHost,
  }) : _clientFactory = clientFactory;

  final HttpClient Function() _clientFactory;
  HttpClient? _client;

  /// 单次请求（连接 + 读完响应体）的时限。
  final Duration timeout;

  /// 响应体上限：插件只取 HTML / JSON / 小图，超过就是误用或攻击。
  final int maxBodyBytes;

  /// 主机拦截判据；生产恒为 [isLnReaderBlockedHost]，测试（本地回环服务器）注入。
  final bool Function(String host) isBlockedHost;

  /// 进程内 cookie：部分站点首个页面下发会话 cookie、后续请求要带回。只在本
  /// 运行时生命周期内有效，不落盘。键是 cookie 的 domain（去掉前导点）。
  final Map<String, Map<String, String>> _cookies =
      <String, Map<String, String>>{};

  /// LNReader app 默认带的桌面 Chrome UA；插件自己给了就用插件的。
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  /// 由 HttpClient 自己协商的头：插件显式写 `Accept-Encoding: br` 时 Dart 解
  /// 不开，交给 HttpClient（autoUncompress）；长度由 HttpClient 按真实体积写。
  static const Set<String> _managedRequestHeaders = <String>{
    'accept-encoding',
    'content-length',
    'host',
    'connection',
  };

  Future<Map<String, Object?>> perform(Object? rawRequest) async {
    try {
      return await _perform(rawRequest).timeout(timeout);
    } on TimeoutException {
      return <String, Object?>{'error': 'timeout'};
    } on Object catch (error) {
      return <String, Object?>{'error': '$error'};
    }
  }

  Future<Map<String, Object?>> _perform(Object? rawRequest) async {
    if (rawRequest is! Map) {
      return <String, Object?>{'error': 'malformed request'};
    }
    final Uri? uri = Uri.tryParse((rawRequest['url'] ?? '').toString());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return <String, Object?>{
        'error': 'unsupported url: ${rawRequest['url']}',
      };
    }
    if (isBlockedHost(uri.host)) {
      return <String, Object?>{'error': 'blocked host: ${uri.host}'};
    }
    final String method = (rawRequest['method'] ?? 'GET')
        .toString()
        .toUpperCase();
    final Map<String, String> headers = <String, String>{
      if (rawRequest['headers'] is Map)
        for (final MapEntry<Object?, Object?> entry
            in (rawRequest['headers'] as Map).entries)
          entry.key.toString().toLowerCase(): entry.value.toString(),
    };
    final Object? rawBody = rawRequest['body'];
    Uint8List? body = rawBody is String && rawBody.isNotEmpty
        ? base64Decode(rawBody)
        : null;
    headers.putIfAbsent('user-agent', () => defaultUserAgent);
    final bool pluginCookie = headers.containsKey('cookie');

    // 🔴 重定向手动跟：HttpClient 自动跟随时，一个指向 127.0.0.1 的 302 就能绕过
    // 上面的回环拦截。每一跳都重新过 [isLnReaderBlockedHost]。
    final HttpClient client = _client ??= _clientFactory();
    Uri current = uri;
    String currentMethod = method;
    late HttpClientResponse response;
    for (int hop = 0; ; hop++) {
      final HttpClientRequest request = await client.openUrl(
        currentMethod,
        current,
      );
      request.followRedirects = false;
      if (!pluginCookie) {
        final String? cookie = _cookieHeaderFor(current);
        if (cookie == null) {
          headers.remove('cookie');
        } else {
          headers['cookie'] = cookie;
        }
      }
      headers.forEach((String name, String value) {
        if (_managedRequestHeaders.contains(name)) return;
        request.headers.set(name, value, preserveHeaderCase: true);
      });
      if (body != null) request.add(body);
      response = await request.close();
      _rememberCookies(current, response);
      final String? location = response.headers.value(
        HttpHeaders.locationHeader,
      );
      if (!response.isRedirect || location == null) break;
      await response.drain<void>();
      if (hop >= _maxRedirects) {
        return <String, Object?>{'error': 'too many redirects'};
      }
      final Uri next = current.resolve(location);
      if ((next.scheme != 'http' && next.scheme != 'https') ||
          isBlockedHost(next.host)) {
        return <String, Object?>{'error': 'blocked redirect: $next'};
      }
      // 与浏览器一致：303 一律转 GET；301/302 下的 POST 也转 GET 并丢弃请求体。
      final int status = response.statusCode;
      if (status == HttpStatus.seeOther ||
          ((status == HttpStatus.movedPermanently ||
                  status == HttpStatus.found) &&
              currentMethod == 'POST')) {
        currentMethod = 'GET';
        body = null;
        headers.remove('content-type');
      }
      current = next;
    }
    final BytesBuilder buffer = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      buffer.add(chunk);
      if (buffer.length > maxBodyBytes) {
        return <String, Object?>{'error': 'response too large'};
      }
    }
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      // 响应体已由 HttpClient 解压，原来的编码 / 长度头不再成立。
      if (name == 'content-encoding' || name == 'content-length') return;
      responseHeaders[name] = values.join(', ');
    });
    return <String, Object?>{
      'status': response.statusCode,
      'statusText': response.reasonPhrase,
      'url': current.toString(),
      'headers': responseHeaders,
      'body': base64Encode(buffer.takeBytes()),
    };
  }

  static const int _maxRedirects = 10;

  void _rememberCookies(Uri uri, HttpClientResponse response) {
    for (final Cookie cookie in response.cookies) {
      final String domain = (cookie.domain ?? uri.host).replaceFirst(
        RegExp(r'^\.'),
        '',
      );
      final Map<String, String> jar = _cookies.putIfAbsent(
        domain.toLowerCase(),
        () => <String, String>{},
      );
      final DateTime? expires = cookie.expires;
      final bool expired =
          (cookie.maxAge != null && cookie.maxAge! <= 0) ||
          (expires != null && expires.isBefore(DateTime.now()));
      if (expired) {
        jar.remove(cookie.name);
      } else {
        jar[cookie.name] = cookie.value;
      }
    }
  }

  String? _cookieHeaderFor(Uri uri) {
    final String host = uri.host.toLowerCase();
    final Map<String, String> merged = <String, String>{};
    _cookies.forEach((String domain, Map<String, String> jar) {
      if (host == domain || host.endsWith('.$domain')) merged.addAll(jar);
    });
    if (merged.isEmpty) return null;
    return merged.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
  }

  void close() {
    _client?.close(force: true);
    _client = null;
    _cookies.clear();
  }
}
