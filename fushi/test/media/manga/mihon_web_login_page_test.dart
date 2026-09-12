import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';

/// BUG-2425：桌面端在真实浏览器里登录源站，把会话交给宿主的 jar。
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mihon-login-');
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  MihonCookieJar jar() =>
      MihonCookieJar(File('${directory.path}/cookies.json'));

  Cookie browserCookie(
    String name, {
    String value = 'v',
    String? domain,
    bool isHttpOnly = false,
  }) =>
      Cookie(name: name, value: value, domain: domain, isHttpOnly: isHttpOnly);

  /// 挂起页面并返回 pop 结果（null = 还没 pop）。
  Future<bool?> pumpLogin(
    WidgetTester tester, {
    required MihonCookieJar? store,
    required Future<List<Cookie>> Function(WebUri url) cookieReader,
    Uri? baseUrl,
  }) async {
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => MihonWebLoginPage(
                    sourceName: 'BookWalker Japan',
                    baseUrl: baseUrl ?? Uri.parse('https://bookwalker.jp'),
                    jar: store,
                    cookieReader: cookieReader,
                    environmentFactory: () async => null,
                    webViewBuilder: (_) =>
                        const SizedBox(key: ValueKey<String>('stub-webview')),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  /// 点「完成」并等真实文件 IO 落地。
  ///
  /// 必须包在 [WidgetTester.runAsync] 里：widget 测试默认跑在 fake-async 时区，
  /// `dart:io` 的完成事件送不进去，`pumpAndSettle` 会在导出还没落盘时就返回，
  /// 断言随即读到一个空 jar——那是测试机制的假红，不是功能坏了。
  /// 点「完成」并**等 `_finish()` 真的跑完**。
  ///
  /// 它是异步的（读 cookie → 写 jar → pop 或弹 SnackBar）。原先这里等的是固定
  /// 50ms 墙钟：本机够用，Linux CI runner 一忙就来不及，于是「点了完成、页还在」
  /// 变成一条与代码无关的红。改成等可观测的真实信号——
  /// `_saving` 期间「完成」按钮 onPressed 为 null，所以
  ///   ① 按钮重新可点（失败/空结果那支，页留着）或
  ///   ② 整页已经 pop 掉（成功那支）
  /// 任一成立即为跑完。上界只用来防死循环，正常路径远早于它退出。
  Future<void> tapDone(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('mihon_login_done')));
    await tester.pump();

    final Finder done = find.byKey(const ValueKey<String>('mihon_login_done'));
    bool settled() {
      final Iterable<Element> hits = done.evaluate();
      if (hits.isEmpty) return true; // 页已经 pop
      final Widget widget = hits.first.widget;
      return widget is TextButton && widget.onPressed != null;
    }

    final Stopwatch clock = Stopwatch()..start();
    while (!settled() && clock.elapsed < const Duration(seconds: 10)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(settled(), isTrue, reason: '_finish() 10 秒还没跑完，不是时序问题了');
    await tester.pumpAndSettle();
  }

  group('登录入口的能力判据', () {
    test('宿主持有 cookie 且源报得出 host 才给入口', () {
      expect(
        mihonLoginTarget(
          runtime: _HostCookieRuntime(),
          baseUrl: 'https://bookwalker.jp',
        ),
        Uri.parse('https://bookwalker.jp'),
      );
    });

    test('运行时既不持有也不共享浏览器 cookie → 无入口', () {
      expect(
        mihonLoginTarget(runtime: Object(), baseUrl: 'https://bookwalker.jp'),
        isNull,
      );
      expect(
        mihonLoginTarget(runtime: null, baseUrl: 'https://bookwalker.jp'),
        isNull,
      );
    });

    test('浏览器持有 cookie 的运行时（Android）同样给入口（BUG-2479）', () {
      expect(
        mihonLoginTarget(
          runtime: _BrowserCookieRuntime(),
          baseUrl: 'https://bookwalker.jp',
        ),
        Uri.parse('https://bookwalker.jp'),
      );
    });

    test('baseUrl 解析不出 host → 无入口（既开不了页也定不了域）', () {
      for (final String baseUrl in <String>[
        '',
        '   ',
        '/relative',
        'not a url',
      ]) {
        expect(
          mihonLoginTarget(runtime: _HostCookieRuntime(), baseUrl: baseUrl),
          isNull,
          reason: 'baseUrl=$baseUrl 不该给出登录入口',
        );
      }
    });
  });

  testWidgets('点「完成」把整站 cookie 导出到 jar 并关页', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async => <Cookie>[
        browserCookie('session', value: 'abc', isHttpOnly: true),
      ],
    );

    await tapDone(tester);

    expect(
      store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')),
      'session=abc',
    );
    expect(find.byKey(const ValueKey<String>('stub-webview')), findsNothing);
  });

  testWidgets('子域 cookie 保留真实域，并随整站一起交给运行时', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async => <Cookie>[
        // 登录域和内容域不同是日站常态。第一版把它重标到 bookwalker.jp，
        // 那会把作用域平白放宽到父域及其全部子域；现在原样保留，由对端的
        // okhttp jar 按每个实际请求 URL 匹配。
        browserCookie('session', value: 'abc', domain: 'member.bookwalker.jp'),
      ],
    );

    await tapDone(tester);

    final List<MangaCookie> site = store.cookiesForSite('bookwalker.jp');
    expect(site.single.name, 'session');
    expect(site.single.domain, 'member.bookwalker.jp');
    // 它对父域**不**生效，正是它应有的作用域。
    expect(store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')), isNull);
    expect(
      store.cookieHeaderFor(Uri.parse('https://member.bookwalker.jp/')),
      'session=abc',
    );
  });

  testWidgets('同名 cookie 跨子域各自保留，不再按 name 互相挤掉', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async => <Cookie>[
        // 回归：曾经只按 name 去重，胜出者取决于 origin 遍历顺序，而那顺序
        // 又不是访问先后（Set.add 命中已有元素不会挪到末尾）——等于随机挑一个，
        // 挑错就是「显示已登录但还是锁着」。
        browserCookie('session', value: 'content', domain: 'bookwalker.jp'),
        browserCookie(
          'session',
          value: 'login',
          domain: 'member.bookwalker.jp',
        ),
      ],
    );

    await tapDone(tester);

    expect(
      store
          .cookiesForSite('bookwalker.jp')
          .map((MangaCookie c) => '${c.domain}=${c.value}')
          .toSet(),
      <String>{'bookwalker.jp=content', 'member.bookwalker.jp=login'},
    );
  });

  testWidgets('未报 domain 的 cookie 存成 host-only（浏览器语义）', (
    WidgetTester tester,
  ) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async => <Cookie>[
        browserCookie('session', value: 'abc'),
      ],
    );

    await tapDone(tester);

    final MangaCookie saved = store.cookiesForSite('bookwalker.jp').single;
    expect(saved.hostOnly, isTrue);
    expect(saved.domain, 'bookwalker.jp');
  });

  testWidgets('第三方域的 cookie 不进 jar', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async => <Cookie>[
        browserCookie('session', value: 'abc'),
        browserCookie('_ga', value: 'track', domain: 'google-analytics.com'),
      ],
    );

    await tapDone(tester);

    final String header = store.cookieHeaderFor(
      Uri.parse('https://bookwalker.jp/'),
    )!;
    expect(header, contains('session=abc'));
    expect(header, isNot(contains('_ga')));
  });

  testWidgets('一条都没拿到时不关页——直接 pop 会让用户以为登录成功了', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async => const <Cookie>[],
    );

    await tapDone(tester);

    // 页面还在（stub webview 仍在树上），jar 也没被写脏。
    expect(find.byKey(const ValueKey<String>('stub-webview')), findsOneWidget);
    expect(store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')), isNull);
  });

  testWidgets('导出失败同样不关页', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async =>
          throw const FileSystemException('nope'),
    );

    await tapDone(tester);

    expect(find.byKey(const ValueKey<String>('stub-webview')), findsOneWidget);
  });

  testWidgets('关闭按钮不导出、pop false', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    bool read = false;
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async {
        read = true;
        return <Cookie>[browserCookie('session')];
      },
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(read, isFalse);
    expect(store.cookies, isEmpty);
  });

  testWidgets('浏览器持有 cookie（jar 为 null）：点「完成」不读 cookie、直接 pop true', (
    WidgetTester tester,
  ) async {
    bool read = false;
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => MihonWebLoginPage(
                    sourceName: 'BookWalker Japan',
                    baseUrl: Uri.parse('https://bookwalker.jp'),
                    jar: null,
                    cookieReader: (WebUri url) async {
                      read = true;
                      return const <Cookie>[];
                    },
                    environmentFactory: () async => null,
                    webViewBuilder: (_) =>
                        const SizedBox(key: ValueKey<String>('stub-webview')),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('mihon_login_done')));
    await tester.pumpAndSettle();

    expect(read, isFalse, reason: '没有 jar 就没有东西要导出');
    expect(popped, isTrue);
    expect(find.byKey(const ValueKey<String>('stub-webview')), findsNothing);
  });

  testWidgets('导航条：后退 / 前进 / 刷新三个按钮在树上，WebView 未就绪时禁用', (
    WidgetTester tester,
  ) async {
    await pumpLogin(
      tester,
      store: jar(),
      cookieReader: (WebUri url) async => const <Cookie>[],
    );
    for (final String key in <String>[
      'mihon_login_back',
      'mihon_login_forward',
      'mihon_login_reload',
    ]) {
      final Finder finder = find.byKey(ValueKey<String>(key));
      expect(finder, findsOneWidget, reason: key);
      expect(tester.widget<IconButton>(finder).onPressed, isNull, reason: key);
    }
    // 地址栏显示当前地址。
    expect(find.text('https://bookwalker.jp'), findsOneWidget);
  });
}

/// 只为判据测试存在：实现「浏览器持有 cookie」这个能力即可。
class _BrowserCookieRuntime implements BrowserCookieMihonRuntime {}

/// 只为判据测试存在：实现「宿主持有 cookie」这个能力即可，不需要真的是运行时。
class _HostCookieRuntime implements HostCookieMihonRuntime {
  @override
  MangaCookieJar get cookieJar =>
      throw UnimplementedError('判据只看类型，不会碰这个 getter');
}
