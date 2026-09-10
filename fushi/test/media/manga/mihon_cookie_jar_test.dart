import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// BUG-2425：桌面 Mihon 的登录态由宿主持有，sidecar 的 jar 只是易失缓存。
void main() {
  late Directory directory;
  int now = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mihon-cookies-');
    now = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  File file() => File('${directory.path}/cookies.json');
  MihonCookieJar jar() => MihonCookieJar(file(), clock: () => now);

  MangaCookie cookie(
    String name, {
    String value = 'v',
    String domain = 'bookwalker.jp',
    int? expiresAt,
  }) =>
      MangaCookie(
        name: name,
        value: value,
        domain: domain,
        expiresAt: expiresAt,
      );

  group('持久化与域匹配', () {
    test('写入后另一个实例读得回来（进程重启不掉登录）', () async {
      await jar().replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'abc'),
      ]);

      final MihonCookieJar reopened = jar();
      await reopened.ensureLoaded();
      expect(
        reopened.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')),
        'session=abc',
      );
    });

    test('父域 cookie 对子域生效，无关站点不串味', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'abc'),
      ]);
      await store.replaceForHost('cmoa.jp', <MangaCookie>[
        cookie('other', value: 'zzz', domain: 'cmoa.jp'),
      ]);

      expect(
        store.cookieHeaderFor(Uri.parse('https://member.bookwalker.jp/api')),
        'session=abc',
      );
      expect(
        store.cookieHeaderFor(Uri.parse('https://cmoa.jp/')),
        'other=zzz',
      );
    });

    test('过期条目不再发出', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'abc', expiresAt: now + 1000),
      ]);

      now += 5000;
      expect(
          store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')), isNull);
    });

    test('坏文件当作没有 cookie，而不是把整次源调用炸掉', () async {
      file().writeAsStringSync('{not json');
      final MihonCookieJar store = jar();
      await store.ensureLoadedBestEffort();
      expect(store.cookies, isEmpty);
    });

    test('clearForHost 只清该站，其它站保留', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session'),
      ]);
      await store.replaceForHost('cmoa.jp', <MangaCookie>[
        cookie('other', domain: 'cmoa.jp'),
      ]);

      expect(await store.clearForHost('bookwalker.jp'), isTrue);
      expect(
          store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')), isNull);
      expect(store.cookieHeaderFor(Uri.parse('https://cmoa.jp/')), 'other=v');
    });
  });

  group('mergeFromRuntime 的语义与 replaceForHost 刻意不同', () {
    test('逐条覆盖同名条目，不动同站其它条目', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'old'),
        cookie('remember', value: 'keep'),
      ]);

      final bool changed = await store.mergeFromRuntime(<MangaCookie>[
        cookie('session', value: 'rotated'),
      ]);

      expect(changed, isTrue);
      final String header = store.cookieHeaderFor(
        Uri.parse('https://bookwalker.jp/'),
      )!;
      // 关键回归：整站替换会把 remember 一起抹掉，等于每发一次请求就登出一半。
      expect(header, contains('session=rotated'));
      expect(header, contains('remember=keep'));
    });

    test('值没变就不落盘（每个请求都写一次文件是不可接受的）', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'same'),
      ]);
      final DateTime before = file().lastModifiedSync();

      final bool changed = await store.mergeFromRuntime(<MangaCookie>[
        cookie('session', value: 'same'),
      ]);

      expect(changed, isFalse);
      expect(file().lastModifiedSync(), before);
    });

    test('空回传是 no-op', () async {
      final MihonCookieJar store = jar();
      expect(await store.mergeFromRuntime(const <MangaCookie>[]), isFalse);
    });
  });

  group('X-Fushi-Set-Cookie 线格式', () {
    test('往返保真，含非 ASCII 与分号（裸放 JSON 头会静默损坏的那些）', () {
      final List<MangaCookie> original = <MangaCookie>[
        cookie('session', value: 'あ;b,c=d'),
        cookie('remember', value: 'x', expiresAt: now + 1000),
      ];

      final List<MangaCookie> roundTripped = decodeMihonSetCookieHeader(
        encodeMihonSetCookieHeader(original),
      );

      expect(roundTripped.map((MangaCookie c) => c.value), <String>[
        'あ;b,c=d',
        'x',
      ]);
      expect(roundTripped[1].expiresAt, now + 1000);
    });

    test('坏载荷降级成空表，不抛', () {
      expect(decodeMihonSetCookieHeader('not-base64!!'), isEmpty);
      expect(
          decodeMihonSetCookieHeader(base64Encode(utf8.encode('{}'))), isEmpty);
    });

    test('无名条目被丢掉', () {
      final String payload = base64Encode(
        utf8.encode(jsonEncode(<Object>[
          <String, Object?>{'name': '', 'value': 'x', 'domain': 'a.test'},
        ])),
      );
      expect(decodeMihonSetCookieHeader(payload), isEmpty);
    });
  });

  group('DesktopMihonRuntime 的注入与吸收', () {
    const MihonSource source = MihonSource(
      extensionPackage: 'ja.bookwalkerjp',
      id: '1',
      name: 'BookWalker Japan',
      language: 'ja',
      baseUrl: 'https://bookwalker.jp',
    );

    DesktopMihonRuntime runtimeWith(MihonCookieJar store) =>
        DesktopMihonRuntime(
          dataDirectory: directory,
          resourceDirectory: directory,
          cookieJar: store,
        );

    test('有 cookie 时按源 baseUrl 的 host 注入 Cookie 头', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'abc'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(source);

      expect(headers['Cookie'], 'session=abc');
    });

    test('没有该站 cookie 时不发 Cookie 头', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('cmoa.jp', <MangaCookie>[
        cookie('other', domain: 'cmoa.jp'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(source);

      expect(headers.containsKey('Cookie'), isFalse);
    });

    test('刻意不发 User-Agent（会全局改写源自设 UA）', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(source);

      // 先钉住「这条路真的跑起来了」，否则下面那句否定断言在功能整个缺失时
      // 也照样为真，是个空壳。
      expect(headers['Cookie'], 'session=v');
      expect(headers.containsKey('User-Agent'), isFalse);
    });

    test('baseUrl 解析不出 host 的源不注入，也不炸', () async {
      const MihonSource hostless = MihonSource(
        extensionPackage: 'x',
        id: '2',
        name: 'no base url',
        language: 'ja',
        baseUrl: '',
      );
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(hostless);

      expect(headers.containsKey('Cookie'), isFalse);
    });

    test('响应回传的 cookie 被并回宿主 jar（会话轮转不掉登录）', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'old'),
      ]);

      await runtimeWith(store).debugAbsorbResponseCookies(
        source,
        <String, String>{
          kMihonSetCookieHeader: encodeMihonSetCookieHeader(<MangaCookie>[
            cookie('session', value: 'rotated'),
          ]),
        },
      );

      expect(
        store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')),
        'session=rotated',
      );
      // 真值必须落盘，否则下次启动又回到旧值。
      expect(file().readAsStringSync(), contains('rotated'));
    });

    test('没有回传头时不动 jar', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'old'),
      ]);

      await runtimeWith(
        store,
      ).debugAbsorbResponseCookies(source, const <String, String>{});

      expect(
        store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')),
        'session=old',
      );
    });
  });
}
