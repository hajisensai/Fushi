import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
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
      Cookie(
        name: name,
        value: value,
        domain: domain,
        isHttpOnly: isHttpOnly,
      );

  /// 挂起页面并返回 pop 结果（null = 还没 pop）。
  Future<bool?> pumpLogin(
    WidgetTester tester, {
    required MihonCookieJar store,
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
  Future<void> tapDone(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('mihon_login_done')));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

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

  testWidgets('子域 cookie 被重标到源站 host，否则永远发不出去', (WidgetTester tester) async {
    final MihonCookieJar store = jar();
    await pumpLogin(
      tester,
      store: store,
      cookieReader: (WebUri url) async => <Cookie>[
        // 登录域和内容域不同是日站常态；原样保留 member. 这个域，
        // cookieHeaderFor('https://bookwalker.jp') 就匹配不到它。
        browserCookie(
          'session',
          value: 'abc',
          domain: 'member.bookwalker.jp',
        ),
      ],
    );

    await tapDone(tester);

    expect(
      store.cookieHeaderFor(Uri.parse('https://bookwalker.jp/')),
      'session=abc',
    );
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

  testWidgets('一条都没拿到时不关页——直接 pop 会让用户以为登录成功了', (
    WidgetTester tester,
  ) async {
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
}
