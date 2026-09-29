import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';

/// 宿主桥是插件全部网络的唯一出口：这里用本机真实 HTTP 服务器验证它把插件的
/// 头 / 体原样送出、会话 cookie 回带、重定向逐跳过拦截。
void main() {
  late HttpServer server;
  late String base;
  final List<HttpHeaders> seenHeaders = <HttpHeaders>[];
  final List<String> seenBodies = <String>[];

  setUp(() async {
    seenHeaders.clear();
    seenBodies.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      seenHeaders.add(request.headers);
      seenBodies.add(await utf8.decoder.bind(request).join());
      final HttpResponse response = request.response;
      switch (request.uri.path) {
        case '/login':
          response.cookies.add(Cookie('session', 'abc'));
          response.write('ok');
        case '/redirect-local':
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            'http://localhost:${server.port}/secret',
          );
        case '/redirect-ok':
          response.statusCode = HttpStatus.seeOther;
          response.headers.set(HttpHeaders.locationHeader, '/final');
        case '/final':
          response.write('landed ${request.method}');
        case '/messy-cookies':
          // 浏览器照收、Dart 的 Cookie 会整体抛错的写法：值里带空格 / 引号，
          // 外加一条没有名字的坏条目和一条已过期的。
          response.headers
            ..add(HttpHeaders.setCookieHeader, 'pref=dark mode; Path=/')
            ..add(HttpHeaders.setCookieHeader, 'quoted="a,b"; Max-Age=60')
            ..add(HttpHeaders.setCookieHeader, '=novalue')
            ..add(
              HttpHeaders.setCookieHeader,
              'gone=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
            );
          response.write('ok');
        case '/cf':
          // 现行 Cloudflare 挑战：标准头 cf-mitigated。
          response.statusCode = HttpStatus.forbidden;
          response.headers.set('cf-mitigated', 'challenge');
          response.write('<html>challenge</html>');
        case '/cf-legacy':
          // 老式 JS 挑战：没有 cf-mitigated，只能认服务器 + 挑战页标记。
          response.statusCode = HttpStatus.serviceUnavailable;
          response.headers.set(HttpHeaders.serverHeader, 'cloudflare');
          response.write(
            '<title>Just a moment...</title>'
            '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate"></script>',
          );
        case '/cf-forbidden':
          // 站点自己的 403（地区限制 / 需登录），只是恰好挂在 Cloudflare 后面。
          response.statusCode = HttpStatus.forbidden;
          response.headers.set(HttpHeaders.serverHeader, 'cloudflare');
          response.write('<h1>403 Forbidden</h1>');
        case '/gbk':
          // 「日本」的 GBK 字节：桥只搬字节，解码归插件（fetchText 的 encoding）。
          response.headers.contentType = ContentType('text', 'html');
          response.add(<int>[0xC8, 0xD5, 0xB1, 0xBE]);
        default:
          response.write('echo ${request.method}');
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  LnReaderFetchBridge bridge() => LnReaderFetchBridge(
    clientFactory: HttpClient.new,
    // 测试服务器本身在回环上：放行 127.0.0.1，只拦 localhost（模拟「打到本机」）；
    // 连接层（解析后地址）同样放行，由下面的专门用例钉。
    isBlockedHost: (String host) => host == 'localhost',
    isBlockedAddress: (InternetAddress _) => false,
  );

  LnReaderFetchBridge cloudflareBridge(LnReaderCloudflare cloudflare) =>
      LnReaderFetchBridge(
        clientFactory: HttpClient.new,
        isBlockedHost: (String host) => host == 'localhost',
        isBlockedAddress: (InternetAddress _) => false,
        cloudflare: cloudflare,
      );

  Future<LnReaderCloudflare> newCloudflare() async {
    final Directory dir = await Directory.systemTemp.createTemp('lnreader_cf');
    addTearDown(() => dir.delete(recursive: true));
    return LnReaderCloudflare(
      MangaCookieJar(File('${dir.path}${Platform.pathSeparator}cookies.json')),
    );
  }

  test('缺省补齐 LNReader app 的默认请求头，插件显式给的优先', () async {
    await bridge().perform(<String, Object?>{
      'url': '$base/echo',
      'method': 'GET',
      'headers': <String, Object?>{'Accept': 'application/json'},
    });
    final HttpHeaders headers = seenHeaders.single;
    expect(headers.value('accept'), 'application/json');
    expect(headers.value('accept-language'), '*');
    expect(headers.value('sec-fetch-mode'), 'cors');
    expect(headers.value('cache-control'), 'max-age=0');
    expect(headers.value('user-agent'), LnReaderFetchBridge.defaultUserAgent);
  });

  test('Cloudflare 挑战按插件记下（带实际 UA），同站再通过即清除', () async {
    final LnReaderCloudflare cloudflare = await newCloudflare();
    final LnReaderFetchBridge fetch = cloudflareBridge(cloudflare);
    final Map<String, Object?> blocked = await fetch.perform(<String, Object?>{
      'url': '$base/cf',
      'method': 'GET',
      'headers': <String, Object?>{'User-Agent': 'PluginUA/1'},
      'plugin': 'novel.site',
    });
    // 响应照常交还插件：插件自己的错误文案（"open in webview"）仍然显示。
    expect(blocked['status'], HttpStatus.forbidden);
    final LnReaderCloudflareChallenge? challenge = cloudflare.challengeFor(
      'novel.site',
    );
    expect(challenge?.url.toString(), '$base/cf');
    expect(challenge?.userAgent, 'PluginUA/1');
    expect(cloudflare.challengeFor('other.plugin'), isNull);

    await fetch.perform(<String, Object?>{
      'url': '$base/echo',
      'method': 'GET',
      'plugin': 'novel.site',
    });
    expect(cloudflare.challengeFor('novel.site'), isNull);
  });

  test('老式 JS 挑战也认；站点自己的 403 不当成挑战', () async {
    final LnReaderCloudflare cloudflare = await newCloudflare();
    final LnReaderFetchBridge fetch = cloudflareBridge(cloudflare);
    await fetch.perform(<String, Object?>{
      'url': '$base/cf-forbidden',
      'method': 'GET',
      'plugin': 'a',
    });
    expect(cloudflare.challengeFor('a'), isNull);
    await fetch.perform(<String, Object?>{
      'url': '$base/cf-legacy',
      'method': 'GET',
      'plugin': 'a',
    });
    expect(cloudflare.challengeFor('a')?.url.path, '/cf-legacy');
  });

  test('验证拿到的放行 cookie 随请求发出，会话 cookie 同名覆盖', () async {
    final LnReaderCloudflare cloudflare = await newCloudflare();
    await cloudflare.jar.replaceForHost('127.0.0.1', const <MangaCookie>[
      MangaCookie(name: 'cf_clearance', value: 'solved', domain: '127.0.0.1'),
      MangaCookie(name: 'session', value: 'stale', domain: '127.0.0.1'),
    ]);
    final LnReaderFetchBridge fetch = cloudflareBridge(cloudflare);
    await fetch.perform(<String, Object?>{
      'url': '$base/echo',
      'method': 'GET',
    });
    expect(seenHeaders.last.value('cookie'), contains('cf_clearance=solved'));
    await fetch.perform(<String, Object?>{
      'url': '$base/login',
      'method': 'GET',
    });
    await fetch.perform(<String, Object?>{
      'url': '$base/echo',
      'method': 'GET',
    });
    final String cookie = seenHeaders.last.value('cookie')!;
    expect(cookie, contains('cf_clearance=solved'));
    expect(cookie, contains('session=abc'));
    expect(cookie, isNot(contains('stale')));
  });

  test('不合 RFC 的 Set-Cookie 不拖垮请求，能解析的照样回带', () async {
    final LnReaderFetchBridge fetch = bridge();
    final Map<String, Object?> result = await fetch.perform(<String, Object?>{
      'url': '$base/messy-cookies',
      'method': 'GET',
    });
    expect(result['status'], 200);
    await fetch.perform(<String, Object?>{
      'url': '$base/echo',
      'method': 'GET',
    });
    final String cookie = seenHeaders.last.value('cookie')!;
    expect(cookie, contains('pref=dark mode'));
    expect(cookie, contains('quoted="a,b"'));
    expect(cookie, isNot(contains('gone')));
  });

  test('插件的请求头与请求体原样送出，缺省补 UA', () async {
    final Map<String, Object?> result = await bridge().perform(
      <String, Object?>{
        'url': '$base/echo',
        'method': 'POST',
        'headers': <String, Object?>{
          'Referer': 'https://example.com/',
          'content-type': 'application/x-www-form-urlencoded',
        },
        'body': base64Encode(utf8.encode('a=1&b=2')),
      },
    );
    expect(result['status'], 200);
    expect(utf8.decode(base64Decode(result['body']! as String)), 'echo POST');
    expect(seenHeaders.single.value('referer'), 'https://example.com/');
    expect(seenHeaders.single.value('user-agent'), contains('Chrome'));
    expect(seenBodies.single, 'a=1&b=2');
  });

  test('响应体按字节原样回传（非 UTF-8 站点靠插件自己解码）', () async {
    final Map<String, Object?> result = await bridge().perform(
      <String, Object?>{'url': '$base/gbk', 'method': 'GET'},
    );
    expect(base64Decode(result['body']! as String), <int>[
      0xC8,
      0xD5,
      0xB1,
      0xBE,
    ]);
  });

  test('会话 cookie 在同一桥内回带', () async {
    final LnReaderFetchBridge b = bridge();
    await b.perform(<String, Object?>{'url': '$base/login'});
    await b.perform(<String, Object?>{'url': '$base/next'});
    expect(seenHeaders.last.value('cookie'), 'session=abc');
    b.close();
  });

  test('303 重定向转 GET 并跟到底，回报最终地址', () async {
    final Map<String, Object?> result = await bridge()
        .perform(<String, Object?>{
          'url': '$base/redirect-ok',
          'method': 'POST',
          'body': base64Encode(utf8.encode('x')),
        });
    expect(result['url'], '$base/final');
    expect(utf8.decode(base64Decode(result['body']! as String)), 'landed GET');
  });

  test('重定向到被拦主机时不跟随', () async {
    final Map<String, Object?> result = await bridge().perform(
      <String, Object?>{'url': '$base/redirect-local'},
    );
    expect(result['error'], startsWith('blocked redirect'));
    expect(seenHeaders.length, 1, reason: '拦截必须发生在请求发出之前，被拦主机一次都不能被打到。');
  });

  test('非 http(s) 与被拦主机直接拒绝', () async {
    expect(
      (await bridge().perform(<String, Object?>{
        'url': 'file:///etc/passwd',
      }))['error'],
      startsWith('unsupported url'),
    );
    expect(
      (await bridge().perform(<String, Object?>{
        'url': 'http://localhost:${server.port}/',
      }))['error'],
      startsWith('blocked host'),
    );
    expect(seenHeaders, isEmpty);
  });

  test('生产拦截判据：回环 / localhost / 链路本地被拦，公网放行', () {
    expect(isLnReaderBlockedHost('localhost'), isTrue);
    expect(isLnReaderBlockedHost('api.localhost'), isTrue);
    expect(isLnReaderBlockedHost('127.0.0.1'), isTrue);
    expect(isLnReaderBlockedHost('127.8.9.1'), isTrue);
    expect(isLnReaderBlockedHost('[::1]'), isTrue);
    expect(isLnReaderBlockedHost('169.254.169.254'), isTrue);
    expect(isLnReaderBlockedHost('ncode.syosetu.com'), isFalse);
    expect(isLnReaderBlockedHost('93.184.216.34'), isFalse);
    // 末尾带点是同一个主机（FQDN 写法）。
    expect(isLnReaderBlockedHost('localhost.'), isTrue);
    expect(isLnReaderBlockedHost('[::ffff:127.0.0.1]'), isTrue);
    expect(isLnReaderBlockedHost('0.0.0.0'), isTrue);
  });

  test('生产地址判据：回环 / 链路本地 / 未指定 / IPv4 映射回环被拦', () {
    for (final String raw in <String>[
      '127.0.0.1',
      '127.8.9.1',
      '::1',
      '169.254.169.254',
      'fe80::1',
      '0.0.0.0',
      '::',
      '::ffff:127.0.0.1',
    ]) {
      expect(
        isLnReaderBlockedAddress(InternetAddress(raw)),
        isTrue,
        reason: raw,
      );
    }
    expect(isLnReaderBlockedAddress(InternetAddress('93.184.216.34')), isFalse);
    expect(
      isLnReaderBlockedAddress(InternetAddress('::ffff:93.184.216.34')),
      isFalse,
    );
  });

  // 连接层自己建 socket：解析出多个地址时必须逐个试。`localhost` 常先解析出
  // `::1`，而测试服务器只听 IPv4——只连第一个地址就连不上（生产上等于 IPv6 排前、
  // 本机只通 IPv4 的站点全部失败）。
  test('连接层逐个尝试解析出的地址（IPv6 不通回落 IPv4）', () async {
    final LnReaderFetchBridge open = LnReaderFetchBridge(
      clientFactory: HttpClient.new,
      isBlockedHost: (String _) => false,
      isBlockedAddress: (InternetAddress _) => false,
    );
    final Map<String, Object?> result = await open.perform(<String, Object?>{
      'url': 'http://localhost:${server.port}/echo',
    });
    expect(result['status'], 200, reason: '$result');
    open.close();
  });

  // 审查 B1：名字判据是字符串比较，`localhost.`、A 记录指向 127.0.0.1 的外部域名、
  // DNS rebinding 都能绕过。真正的边界在连接层按解析后地址判——这里把名字判据
  // 整个放开，只靠连接层，证明本机服务一次都打不到。
  test('连接层按解析后地址拦截：名字判据放开时本机也打不到', () async {
    final LnReaderFetchBridge guarded = LnReaderFetchBridge(
      clientFactory: HttpClient.new,
      isBlockedHost: (String _) => false,
    );
    for (final String url in <String>[
      '$base/secret',
      'http://localhost.:${server.port}/secret',
      'http://localhost:${server.port}/secret',
    ]) {
      final Map<String, Object?> result = await guarded.perform(
        <String, Object?>{'url': url},
      );
      expect(result['error'], contains('blocked host'), reason: url);
    }
    expect(seenHeaders, isEmpty, reason: '拦截必须发生在连接之前，本机服务一次都不能被打到。');
    guarded.close();
  });
}
