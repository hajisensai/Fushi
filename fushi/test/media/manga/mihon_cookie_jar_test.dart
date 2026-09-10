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

  group('站点级选取与替换（登录导出用的那套）', () {
    test('cookiesForSite 双向都收：父域条目与子域条目一起交出去', () async {
      final MihonCookieJar store = jar();
      await store.replaceForSite('bookwalker.jp', <MangaCookie>[
        cookie('parent', domain: 'bookwalker.jp'),
        cookie('child', domain: 'member.bookwalker.jp'),
      ]);
      await store.replaceForSite('cmoa.jp', <MangaCookie>[
        cookie('other', domain: 'cmoa.jp'),
      ]);

      expect(
        store
            .cookiesForSite('bookwalker.jp')
            .map((MangaCookie c) => c.name)
            .toSet(),
        <String>{'parent', 'child'},
      );
      // 无关站点不串味。
      expect(store.cookiesForSite('cmoa.jp').single.name, 'other');
    });

    test('host-only 条目只发给那一个 host，不发给子域', () async {
      final MihonCookieJar store = jar();
      await store.replaceForSite('bookwalker.jp', <MangaCookie>[
        const MangaCookie(
          name: 'session',
          value: 'abc',
          domain: 'bookwalker.jp',
          hostOnly: true,
        ),
      ]);

      expect(
        store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')),
        'session=abc',
      );
      expect(
        store.cookieHeaderFor(Uri.parse('https://member.bookwalker.jp/')),
        isNull,
      );
    });

    test('replaceForSite 整站替换，不动别的站', () async {
      final MihonCookieJar store = jar();
      await store.replaceForSite('bookwalker.jp', <MangaCookie>[
        cookie('old', domain: 'member.bookwalker.jp'),
      ]);
      await store.replaceForSite('cmoa.jp', <MangaCookie>[
        cookie('keep', domain: 'cmoa.jp'),
      ]);

      await store.replaceForSite('bookwalker.jp', <MangaCookie>[
        cookie('fresh', domain: 'bookwalker.jp'),
      ]);

      expect(
        store.cookiesForSite('bookwalker.jp').map((MangaCookie c) => c.name),
        <String>['fresh'],
      );
      expect(store.cookiesForSite('cmoa.jp').single.name, 'keep');
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

      final List<MangaCookie> roundTripped = decodeMihonCookieWire(
        encodeMihonCookieWire(original),
      );

      expect(roundTripped.map((MangaCookie c) => c.value), <String>[
        'あ;b,c=d',
        'x',
      ]);
      expect(roundTripped[1].expiresAt, now + 1000);
    });

    test('解得开 Kotlin 侧编码器产出的那一份（跨语言契约）', () {
      // 这个字面量与 sidecar 的
      // `overlay/.../controller/SourceCookieInjectionTest.kt` 逐字节相同。
      // 两侧各有自己的编解码实现，只改一边而保持该边自洽的改动，在各自的
      // 测试里照样全绿——只有把同一份载荷钉在两边，漂移才会红。
      const String fromKotlin =
          'W3sibmFtZSI6InNlc3Npb24iLCJ2YWx1ZSI6ImFiYyIsImRvbWFpbiI6Im1lbWJlci5ib29rd2Fsa2VyLmpwIiwicGF0aCI6'
          'Ii8iLCJzZWN1cmUiOnRydWUsImhvc3RPbmx5Ijp0cnVlLCJleHBpcmVzQXQiOjE3ODkwMDAwMDAwMDB9LHsibmFtZSI6ImNz'
          'cmYiLCJ2YWx1ZSI6Ing7eSx6IiwiZG9tYWluIjoiYm9va3dhbGtlci5qcCIsInBhdGgiOiIvIiwic2VjdXJlIjpmYWxzZX1d';

      final List<MangaCookie> decoded = decodeMihonCookieWire(fromKotlin);

      expect(
          decoded.map((MangaCookie c) => c.name), <String>['session', 'csrf']);
      expect(decoded[0].value, 'abc');
      // 域原样保留（不再重标到源站 host），且 secure/hostOnly 都过得来——
      // 这三样正是扁平 `Cookie:` 头会丢掉、进而让注入条目与站点自己那条并存的。
      expect(decoded[0].domain, 'member.bookwalker.jp');
      expect(decoded[0].secure, isTrue);
      expect(decoded[0].hostOnly, isTrue);
      expect(decoded[0].expiresAt, 1789000000000);
      // 分号/逗号原样穿过——正是套 base64 要防的那类损坏。
      expect(decoded[1].value, 'x;y,z');
      expect(decoded[1].hostOnly, isFalse);
      // 会话 cookie 不带过期时刻。
      expect(decoded[1].expiresAt, isNull);
    });

    test('坏载荷降级成空表，不抛', () {
      expect(decodeMihonCookieWire('not-base64!!'), isEmpty);
      expect(decodeMihonCookieWire(base64Encode(utf8.encode('{}'))), isEmpty);
    });

    test('无名条目被丢掉', () {
      final String payload = base64Encode(
        utf8.encode(jsonEncode(<Object>[
          <String, Object?>{'name': '', 'value': 'x', 'domain': 'a.test'},
        ])),
      );
      expect(decodeMihonCookieWire(payload), isEmpty);
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

    test('把整站 cookie 以结构化头交出去（含子域，域原样保留）', () async {
      final MihonCookieJar store = jar();
      await store.replaceForSite('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'abc', domain: 'member.bookwalker.jp'),
        cookie('pref', value: 'p'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(source);

      // 回归：曾经按「对 baseUrl 生效」筛选，只作用在登录子域上的会话 cookie
      // 一条都发不出去——表现正是「登录了但还是锁着」。
      final List<MangaCookie> sent = decodeMihonCookieWire(
        headers[kMihonCookieHeader]!,
      );
      expect(
        sent.map((MangaCookie c) => '${c.name}@${c.domain}').toSet(),
        <String>{'session@member.bookwalker.jp', 'pref@bookwalker.jp'},
      );
      // 回归：不再借用标准 `Cookie:` 头（它是有损的，且与传输层 UA 同处一组）。
      expect(headers.containsKey('Cookie'), isFalse);
    });

    test('没有该站 cookie 时不发 cookie 头', () async {
      final MihonCookieJar store = jar();
      await store.replaceForSite('cmoa.jp', <MangaCookie>[
        cookie('other', domain: 'cmoa.jp'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(source);

      expect(headers.containsKey(kMihonCookieHeader), isFalse);
    });

    test('不设源 UA：既不发专用头，也不借用传输层的 User-Agent', () async {
      final MihonCookieJar store = jar();
      await store.replaceForSite('bookwalker.jp', <MangaCookie>[
        cookie('session'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(source);

      // 先钉住「这条路真的跑起来了」，否则下面的否定断言在功能整个缺失时
      // 也照样为真，是个空壳。
      expect(headers.containsKey(kMihonCookieHeader), isTrue);
      // 回归：sidecar 曾经把**收到的任何 UA** 当成「设这个源的 UA」，而
      // `dart:io` 的 HttpClient 无条件带 `User-Agent: Dart/x.y (dart:io)`
      // （宿主这里根本控制不到），于是每次调用都把源的 UA 改写成 Dart。
      // 现在源 UA 只走这个专用头，宿主不发即不改写。
      expect(headers.containsKey('X-Fushi-Source-User-Agent'), isFalse);
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
      await store.replaceForSite('bookwalker.jp', <MangaCookie>[
        cookie('session'),
      ]);

      final Map<String, String> headers = await runtimeWith(
        store,
      ).debugRequestHeaders(hostless);

      expect(headers.containsKey(kMihonCookieHeader), isFalse);
    });

    test('响应回传的 cookie 被并回宿主 jar（会话轮转不掉登录）', () async {
      final MihonCookieJar store = jar();
      await store.replaceForHost('bookwalker.jp', <MangaCookie>[
        cookie('session', value: 'old'),
      ]);

      await runtimeWith(store).debugAbsorbResponseCookies(
        source,
        <String, String>{
          kMihonSetCookieHeader: encodeMihonCookieWire(<MangaCookie>[
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
