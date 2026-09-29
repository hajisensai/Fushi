import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';

/// 插件不许访问的主机：本机回环。
///
/// 插件是第三方仓库的任意 JS，而 app 自己在本机开着 HTTP 服务（浏览器扩展查词
/// 接口、互联 host 等）；不拦的话，一个恶意插件经宿主桥就能打到这些本机接口。
///
/// 这只是**名字层**的快速拒绝（给出可读错误、不发 DNS）。它挡不住 `localhost.`、
/// A 记录指向 127.0.0.1 的外部域名、DNS rebinding——真正的边界是
/// [guardLnReaderConnections] 在建连接那一刻按解析后的地址判。
bool isLnReaderBlockedHost(String host) {
  final String value = host
      .toLowerCase()
      .replaceAll(RegExp(r'^\[|\]$'), '')
      .replaceAll(RegExp(r'\.+$'), '');
  if (value == 'localhost' || value.endsWith('.localhost')) return true;
  final InternetAddress? address = InternetAddress.tryParse(value);
  return address != null && isLnReaderBlockedAddress(address);
}

/// 解析后的地址是否落在本机：回环、链路本地、未指定（`0.0.0.0` / `::`，在多数
/// 平台上连它就是连本机），以及 IPv4 映射的 IPv6（`::ffff:127.0.0.1`）。
bool isLnReaderBlockedAddress(InternetAddress address) {
  InternetAddress value = address;
  final List<int> raw = value.rawAddress;
  if (value.type == InternetAddressType.IPv6 &&
      raw.length == 16 &&
      raw.sublist(0, 10).every((int b) => b == 0) &&
      raw[10] == 0xff &&
      raw[11] == 0xff) {
    value = InternetAddress.fromRawAddress(Uint8List.fromList(raw.sublist(12)));
  }
  if (value.isLoopback || value.isLinkLocal) return true;
  return value.rawAddress.every((int b) => b == 0);
}

/// 让 [client] 在**建立连接那一刻**按解析后的地址拦截本机（BUG 审查 B1）。
///
/// 名字判据是字符串比较，`http://localhost.:8765/`、`*.nip.io`、攻击者自己把 A 记录
/// 指到 127.0.0.1 的域名都能绕过，恶意插件就能打到 AnkiConnect 等本机服务。这里
/// 自己解析目标主机、剔除本机地址，直连时只连剩下这些**已判过**的地址（TLS 的
/// SNI / 证书校验仍按原主机名，`InternetAddress.lookup` 的结果带着它），所以解析与
/// 连接之间没有 rebinding 的窗口。
///
/// 经代理时连接对象是代理、目标由代理解析：只能事先按本机解析结果判一次，代理侧
/// 解析到本机的 rebinding 是已知残留面（与用户自己配置代理的信任边界一致）。
void guardLnReaderConnections(
  HttpClient client, {
  bool Function(InternetAddress address) isBlockedAddress =
      isLnReaderBlockedAddress,
}) {
  client.connectionFactory =
      (Uri uri, String? proxyHost, int? proxyPort) async {
        final List<InternetAddress> resolved = await InternetAddress.lookup(
          uri.host,
        );
        final List<InternetAddress> allowed = <InternetAddress>[
          for (final InternetAddress address in resolved)
            if (!isBlockedAddress(address)) address,
        ];
        if (allowed.isEmpty) {
          throw SocketException('blocked host: ${uri.host}');
        }
        if (proxyHost != null && proxyPort != null) {
          return Socket.startConnect(proxyHost, proxyPort);
        }
        // 按解析顺序逐个试（与 HttpClient 默认的直连行为一致）：只连第一个时，
        // IPv6 排前而本机只通 IPv4 的站点会直接连不上。
        Future<Socket> connectFirstReachable() async {
          late SocketException lastError;
          for (final InternetAddress address in allowed) {
            try {
              return uri.scheme == 'https'
                  ? await SecureSocket.connect(address, uri.port)
                  : await Socket.connect(address, uri.port);
            } on SocketException catch (error) {
              lastError = error;
            }
          }
          throw lastError;
        }

        return ConnectionTask.fromSocket(connectFirstReachable(), () {});
      };
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
    this.isBlockedAddress = isLnReaderBlockedAddress,
    this.cloudflare,
  }) : _clientFactory = clientFactory;

  /// Cloudflare 放行 cookie 与待解挑战；null 时不带持久 cookie、不记挑战
  /// （单测 / 无 UI 场景）。见 [LnReaderCloudflare]。
  final LnReaderCloudflare? cloudflare;

  final HttpClient Function() _clientFactory;
  HttpClient? _client;

  /// 连接层（解析后地址）的拦截判据；生产恒为 [isLnReaderBlockedAddress]，测试
  /// （本地回环服务器）注入。见 [guardLnReaderConnections]。
  final bool Function(InternetAddress address) isBlockedAddress;

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

  /// LNReader app `fetchApi` 给每个请求补的默认头（`makeInit`，插件显式给的
  /// 优先）。只带 UA 的请求会被部分站点当脚本拒掉（2026-09 对 69shu 同一时刻
  /// A/B：只带 UA 回 403，补上这组回 200）。`Connection` / `Accept-Encoding`
  /// 交给 HttpClient 自己协商。
  static const Map<String, String> defaultHeaders = <String, String>{
    'user-agent': defaultUserAgent,
    'accept': '*/*',
    'accept-language': '*',
    'sec-fetch-mode': 'cors',
    'cache-control': 'max-age=0',
  };

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
    defaultHeaders.forEach(
      (String name, String value) => headers.putIfAbsent(name, () => value),
    );
    final bool pluginCookie = headers.containsKey('cookie');
    // 宿主脚本给每个请求标上发起的插件（挑战按插件记，页面才知道该给谁弹验证）。
    final String? pluginId = rawRequest['plugin']?.toString();
    final LnReaderCloudflare? cloudflare = this.cloudflare;
    await cloudflare?.jar.ensureLoadedBestEffort();

    // 🔴 重定向手动跟：HttpClient 自动跟随时，一个指向 127.0.0.1 的 302 就能绕过
    // 上面的回环拦截。每一跳都重新过 [isLnReaderBlockedHost]。
    final HttpClient client = _client ??= _guardedClient();
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
    final Uint8List bytes = buffer.takeBytes();
    if (cloudflare != null && pluginId != null) {
      if (isLnReaderCloudflareChallenge(
        statusCode: response.statusCode,
        headers: response.headers,
        body: bytes,
      )) {
        cloudflare.record(
          pluginId,
          LnReaderCloudflareChallenge(
            url: current,
            userAgent: headers['user-agent']!,
          ),
        );
      } else {
        cloudflare.clear(pluginId, current.host);
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
      'body': base64Encode(bytes),
    };
  }

  static const int _maxRedirects = 10;

  HttpClient _guardedClient() {
    final HttpClient client = _clientFactory();
    guardLnReaderConnections(client, isBlockedAddress: isBlockedAddress);
    return client;
  }

  /// 按浏览器的宽松口径记下 `Set-Cookie`。
  ///
  /// 不用 `response.cookies`：Dart 的 [Cookie] 严格按 RFC 6265 校验，值里有空格 /
  /// 逗号 / 引号的一条 cookie 就让它整体抛 FormatException，整个请求变成
  /// `{error}`——而浏览器和 LNReader app（OkHttp）都照收。这里逐条解析，只丢
  /// 真的解析不出名字的那条。
  void _rememberCookies(Uri uri, HttpClientResponse response) {
    for (final String raw
        in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      final List<String> parts = raw.split(';');
      final int eq = parts.first.indexOf('=');
      if (eq <= 0) continue;
      final String name = parts.first.substring(0, eq).trim();
      final String value = parts.first.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      String domain = uri.host;
      int? maxAge;
      DateTime? expires;
      for (final String attribute in parts.skip(1)) {
        final int split = attribute.indexOf('=');
        final String key =
            (split < 0 ? attribute : attribute.substring(0, split))
                .trim()
                .toLowerCase();
        final String argument = split < 0
            ? ''
            : attribute.substring(split + 1).trim();
        switch (key) {
          case 'domain' when argument.isNotEmpty:
            domain = argument.replaceFirst(RegExp(r'^\.'), '');
          case 'max-age':
            maxAge = int.tryParse(argument) ?? maxAge;
          case 'expires':
            try {
              expires = HttpDate.parse(argument);
            } on Exception {
              // 日期写坏了就当会话 cookie（浏览器同样忽略坏掉的 Expires）。
            }
        }
      }
      // RFC 6265 §5.3：两者都在时 Max-Age 优先。
      final bool expired = maxAge != null
          ? maxAge <= 0
          : expires != null && expires.isBefore(DateTime.now());
      final Map<String, String> jar = _cookies.putIfAbsent(
        domain.toLowerCase(),
        () => <String, String>{},
      );
      if (expired) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
  }

  /// 持久 jar（Cloudflare 放行等）打底，本次运行站点下发的会话 cookie 覆盖同名项。
  String? _cookieHeaderFor(Uri uri) {
    final String host = uri.host.toLowerCase();
    final Map<String, String> merged = <String, String>{
      for (final MangaCookie cookie
          in cloudflare?.jar.cookiesFor(uri) ?? const <MangaCookie>[])
        cookie.name: cookie.value,
    };
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

/// 封面 / 插图请求头：与插件页面请求同一套默认头打底（桌面 Chrome UA、
/// Referer = 站点），插件 `imageRequestInit.headers`（[pluginHeaders]）按名字不
/// 分大小写覆盖，Cloudflare 放行 cookie（[cloudflare]）按图片地址补上。
///
/// 只带插件头时出去的是 Dart 默认 UA（`Dart/x (dart:io)`）且没有 Referer，防盗链
/// / 查 UA 的图床一律 403，列表整页占位图；`cf_clearance` 又绑定解题时的 UA，所以
/// UA 必须与宿主桥（[LnReaderFetchBridge.defaultUserAgent]）逐字节一致。
Map<String, String> lnReaderImageHeaders({
  required Uri uri,
  String? referer,
  Map<String, String> pluginHeaders = const <String, String>{},
  LnReaderCloudflare? cloudflare,
}) {
  final Map<String, String> headers = <String, String>{
    'User-Agent': LnReaderFetchBridge.defaultUserAgent,
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    if (referer != null && referer.isNotEmpty) 'Referer': referer,
  };
  pluginHeaders.forEach((String name, String value) {
    headers.removeWhere(
      (String key, String _) => key.toLowerCase() == name.toLowerCase(),
    );
    headers[name] = value;
  });
  final bool hasCookie = headers.keys.any(
    (String key) => key.toLowerCase() == 'cookie',
  );
  if (!hasCookie) {
    final List<MangaCookie> cookies =
        cloudflare?.jar.cookiesFor(uri) ?? const <MangaCookie>[];
    if (cookies.isNotEmpty) {
      headers['Cookie'] = cookies
          .map((MangaCookie cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    }
  }
  return headers;
}
