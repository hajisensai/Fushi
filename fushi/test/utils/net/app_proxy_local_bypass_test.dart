/// BUG-1498：**本机 / 局域网目标不得被代理**——把 40+ 条链路接进统一装配点之后，
/// 这是唯一防止「接代理反而把功能改坏」的行为保险。
///
/// 危险是实测出来的，不是假想的。Dart 的 `HttpClient.findProxyFromEnvironment` **不做
/// 任何隐式 loopback bypass**（浏览器和 Windows 的 `ProxyOverride` 默认值 `<local>` 都做）：
/// ```text
/// environment = {http_proxy: 1.2.3.4:8080}
/// http://127.0.0.1:8765/      -> PROXY 1.2.3.4:8080
/// http://localhost:8765/      -> PROXY 1.2.3.4:8080
/// http://192.168.1.34:5000/   -> PROXY 1.2.3.4:8080
/// http://hibiki-pc.local:8080 -> PROXY 1.2.3.4:8080
/// ```
/// 而「用户手填代理」那条分支更极端——它无条件返回 `PROXY host:port`，连 `no_proxy` 都不过。
///
/// 于是只要 AnkiConnect（`127.0.0.1:8765`）、Yomitan 本地端口、Mihon sidecar、桌面 OAuth
/// 回环回调、互联局域网 peer、qBittorrent WebUI、自建 WebDAV 里任何一条被卷进代理层，
/// 功能就当场坏掉。`isDirectProxyTarget` 把这道闸门放在**解析层**，本文件钉死它。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_http.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

/// 本仓真实存在的本机 / 局域网出站目标（取自 BUG-1498 普查表的「禁止接代理清单」）。
const List<String> kLocalOnlyTargets = <String>[
  'http://127.0.0.1:8765/', // AnkiConnect
  'http://localhost:8765/localaudio/get/', // AnkiConnect local-audio 插件
  'http://localhost:5050/?term=x', // local-audio-yomichan
  'http://127.0.0.1:19315/api/lookup', // Yomitan API / 浏览器扩展服务端
  'http://127.0.0.1:9004/oauth-callback', // Dropbox 桌面 OAuth 回环回调
  'http://localhost:6677/', // texthooker WebSocket 宿主
  'http://127.0.0.1:4567/image/1', // Mihon 桌面 sidecar
  'http://127.0.0.1:8080/api/v2/torrents/info', // qBittorrent WebUI
  'https://192.168.1.34:38765/api/library', // 互联局域网 peer（fushi_sync_server）
  'https://10.0.0.5:38765/api/ping', // 互联 peer（10/8 私网）
  'https://172.16.3.9/webdav/', // 自建 WebDAV（172.16/12 私网）
  'http://hibiki-desktop.local:38765/', // mDNS 发现出来的 peer 名
  'http://169.254.10.2/', // link-local
  'http://[::1]:8765/', // IPv6 loopback
  'http://[fe80::1]:38765/', // IPv6 link-local
  'http://[fd12:3456::1]:38765/', // IPv6 ULA
];

/// 必须照常走代理的公网目标（接代理的全部意义所在）。
const List<String> kPublicTargets = <String>[
  'https://raw.githubusercontent.com/x/y.zip',
  'https://huggingface.co/mayocream/manga-ocr-onnx/resolve/main/encoder.onnx',
  'https://api.themoviedb.org/3/search/tv',
  'https://api.bgm.tv/v0/subjects/1',
  'https://graphql.anilist.co/',
  'https://api.dandanplay.net/api/v2/comment/1',
  'https://cdn.jsdelivr.net/gh/google/fonts/ofl/kleeone/KleeOne-Regular.ttf',
  'https://www.youtube.com/watch?v=x',
  'https://nyaa.si/?page=rss',
];

/// 捕获 `findProxy` 的假 [HttpClient]。
///
/// `HttpClient.findProxy` 在 `dart:io` 里**只有 setter、没有 getter**，所以「装配点到底
/// 装没装上出口」在真 client 上读不回来。用 `implements HttpClient` + `noSuchMethod`
/// 只截这一个成员，就能拿到被装进去的那个闭包本体来断言——比读源码字符串强，因为它验的是
/// 运行时真的发生了赋值。
class _CapturingHttpClient implements HttpClient {
  String Function(Uri)? captured;

  @override
  set findProxy(String Function(Uri url)? f) => captured = f;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  final String Function() savedReader = appUserProxyReader;

  setUp(() {
    appUserProxyReader = () => '';
    resetAppProxyCacheForTest();
  });

  tearDown(() {
    appUserProxyReader = savedReader;
    resetAppProxyCacheForTest();
  });

  group('isDirectProxyTarget：纯判据', () {
    test('本机 / 私网 / link-local / mDNS 名一律直连', () {
      for (final String url in kLocalOnlyTargets) {
        expect(isDirectProxyTarget(Uri.parse(url).host), isTrue,
            reason: '$url 必须直连');
      }
    });

    test('公网主机不受影响（否则代理等于白接）', () {
      for (final String url in kPublicTargets) {
        expect(isDirectProxyTarget(Uri.parse(url).host), isFalse,
            reason: '$url 必须能走代理');
      }
    });

    test('私网边界不越界：172.15 / 172.32 / 11.x 是公网', () {
      expect(isDirectProxyTarget('172.16.0.1'), isTrue);
      expect(isDirectProxyTarget('172.31.255.254'), isTrue);
      expect(isDirectProxyTarget('172.15.0.1'), isFalse);
      expect(isDirectProxyTarget('172.32.0.1'), isFalse);
      expect(isDirectProxyTarget('11.0.0.1'), isFalse);
      expect(isDirectProxyTarget('192.169.0.1'), isFalse);
      expect(isDirectProxyTarget('169.253.0.1'), isFalse);
    });

    test('名字里带 local 但不是本机的主机不被误判', () {
      expect(isDirectProxyTarget('localhost.example.com'), isFalse);
      expect(isDirectProxyTarget('mylocal.com'), isFalse);
      expect(isDirectProxyTarget('local.tmdb.org'), isFalse);
      // 反过来，真正的 mDNS / RFC 6761 后缀要认。
      expect(isDirectProxyTarget('nas.local'), isTrue);
      expect(isDirectProxyTarget('app.localhost'), isTrue);
    });

    test('大小写、方括号、IPv6 zone id 都归一', () {
      expect(isDirectProxyTarget('LOCALHOST'), isTrue);
      expect(isDirectProxyTarget('[::1]'), isTrue);
      expect(isDirectProxyTarget('fe80::1%eth0'), isTrue);
      expect(isDirectProxyTarget('::ffff:127.0.0.1'), isTrue);
      expect(isDirectProxyTarget(''), isFalse);
    });
  });

  group('resolveAppProxyDirective：闸门在解析层生效', () {
    test('用户手填代理下，本机 / 局域网仍直连，公网走代理', () {
      appUserProxyReader = () => '1.2.3.4:8080';
      for (final String url in kLocalOnlyTargets) {
        expect(resolveAppProxyDirective(Uri.parse(url)), 'DIRECT',
            reason: '$url 被塞进了用户手填代理');
      }
      for (final String url in kPublicTargets) {
        expect(resolveAppProxyDirective(Uri.parse(url)), 'PROXY 1.2.3.4:8080',
            reason: '$url 没走用户手填代理');
      }
    });

    test('GUI 系统代理（prime 缓存）下，本机 / 局域网仍直连', () {
      debugSetCachedSystemProxyEnv(const <String, String>{
        'http_proxy': '1.2.3.4:8080',
        'https_proxy': '1.2.3.4:8080',
      });
      for (final String url in kLocalOnlyTargets) {
        expect(resolveAppProxyDirective(Uri.parse(url)), 'DIRECT',
            reason: '$url 被系统代理吃掉了');
      }
    });

    test('没有任何代理配置时一律 DIRECT（与接线前逐字等价）', () {
      debugSetCachedSystemProxyEnv(const <String, String>{});
      // 本机环境可能真的 export 了 HTTPS_PROXY（本仓跑测试的规范就要求设），所以
      // 这条只在「本进程 env 确实没给代理」时才有判别力；给了就跳过，绝不假绿。
      final bool envHasProxy = Platform.environment.keys.any((String k) {
        final String lower = k.toLowerCase();
        return lower == 'http_proxy' || lower == 'https_proxy';
      });
      if (envHasProxy) {
        markTestSkipped('本进程 env 已设代理，无法在此断言 DIRECT 等价性');
        return;
      }
      for (final String url in <String>[
        ...kPublicTargets,
        ...kLocalOnlyTargets
      ]) {
        expect(resolveAppProxyDirective(Uri.parse(url)), 'DIRECT');
      }
    });
  });

  group('applyAppProxy（异步版）与同步版给出同一答案', () {
    test('手填代理分支：本机直连、公网走代理', () async {
      final _CapturingHttpClient client = _CapturingHttpClient();
      await applyAppProxy(client, userProxy: '1.2.3.4:8080');
      final String Function(Uri)? findProxy = client.captured;
      expect(findProxy, isNotNull);
      expect(findProxy!(Uri.parse('http://127.0.0.1:8765/')), 'DIRECT');
      expect(findProxy(Uri.parse('https://192.168.1.34:38765/')), 'DIRECT');
      expect(findProxy(Uri.parse('https://api.bgm.tv/v0/subjects/1')),
          'PROXY 1.2.3.4:8080');
    });

    test('系统代理分支：本机直连（异步与同步共用同一道闸门）', () async {
      final _CapturingHttpClient client = _CapturingHttpClient();
      await applyAppProxy(client);
      expect(client.captured, isNotNull);
      expect(client.captured!(Uri.parse('http://127.0.0.1:8765/')), 'DIRECT');
      expect(client.captured!(Uri.parse('https://10.0.0.5:38765/')), 'DIRECT');
    });
  });

  group('applyAppProxySync：装配点真的装上了出口', () {
    test('装上的闭包非空——裸 HttpClient 的 findProxy 恒为 null，那正是根因形态', () {
      final _CapturingHttpClient client = _CapturingHttpClient();
      expect(client.captured, isNull);
      applyAppProxySync(client);
      expect(client.captured, isNotNull,
          reason: 'BUG-1493/1498 的根因就是 findProxy 为 null——那时连 '
              'HTTPS_PROXY 都不读');
    });

    test('装上的就是共享判据：本机目标恒 DIRECT，公网走代理', () {
      appUserProxyReader = () => '1.2.3.4:8080';
      final _CapturingHttpClient client = _CapturingHttpClient();
      applyAppProxySync(client);
      expect(client.captured!(Uri.parse('http://127.0.0.1:8765/')), 'DIRECT');
      expect(client.captured!(Uri.parse('https://api.jikan.moe/v4/anime')),
          'PROXY 1.2.3.4:8080');
    });

    test('三个公开工厂都经 applyAppProxySync（源码守卫：漏一个就是一条暗路）', () {
      final String source =
          File('lib/src/utils/net/app_http.dart').readAsStringSync();
      expect(source, contains('applyAppProxySync(client)'));
      // createAppHttpIoClient / createAppDio 都必须复用 createAppHttpClient，
      // 而不是各自 new 一个裸的。
      expect(source, contains('IOClient(createAppHttpClient('));
      expect(source, contains('createAppHttpClient(connectionTimeout:'));
    });
  });

  group('createAppHttpClient / createAppDio：真实工厂可构造且不抛', () {
    test('三个工厂都能建出实例（构造函数初始化列表里同步可用）', () {
      final HttpClient c = createAppHttpClient();
      addTearDown(() => c.close(force: true));
      expect(c, isA<HttpClient>());
      expect(createAppHttpIoClient(), isNotNull);
      expect(createAppDio(), isNotNull);
    });
  });
}
