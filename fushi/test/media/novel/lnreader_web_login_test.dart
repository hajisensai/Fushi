import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_installed_sources_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_web_login.dart';

import 'fake_lnreader_runtime.dart';

/// 小说源 app 内登录：登录页写的是小说源自己的 jar（出站桥读的那份），登完通知桥
/// 丢掉登录前的会话；入口出现在源列表菜单与加载失败的错误区。
void main() {
  late Directory root;
  late FakeLnReaderRuntime runtime;
  late LnReaderCloudflare cloudflare;
  late LnReaderManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('lnreader_login_test');
    runtime = FakeLnReaderRuntime();
    await File('${root.path}/state.json').writeAsString(
      '{"stores":[],"installed":[{"id":"syosetu","name":"Syosetu",'
      '"site":"https://syosetu.example/","lang":"日本語","version":"1.0.0",'
      '"url":"","iconUrl":"","storeUrl":"","enabled":true,'
      '"pinned":false,"sortOrder":0,"installedAt":0}]}',
    );
    cloudflare = LnReaderCloudflare(
      MangaCookieJar(File('${root.path}/cookies.json')),
    );
    manager = LnReaderManager(
      rootDirectory: root,
      runtime: runtime,
      httpClientFactory: HttpClient.new,
      cloudflare: cloudflare,
    );
    await manager.initialise();
    await manager.pluginFile('syosetu').create(recursive: true);
  });

  tearDown(() async {
    manager.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: child,
        ),
      ),
    );
    await tester.pump();
  }

  group('登录入口的能力判据', () {
    test('有 jar 且 site 解析得出 http(s) host 才给入口', () {
      expect(
        lnReaderLoginTarget(
          cloudflare: cloudflare,
          site: ' https://syosetu.example/ ',
        ),
        Uri.parse('https://syosetu.example/'),
      );
    });

    test('没有 jar（单测 / 无 UI 构造的 manager）→ 无入口', () {
      expect(
        lnReaderLoginTarget(cloudflare: null, site: 'https://syosetu.example/'),
        isNull,
      );
    });

    test('site 解析不出 host 或不是网页地址 → 无入口', () {
      for (final String site in <String>[
        '',
        '   ',
        '/relative',
        'not a url',
        'ftp://syosetu.example/',
      ]) {
        expect(
          lnReaderLoginTarget(cloudflare: cloudflare, site: site),
          isNull,
          reason: 'site=$site 不该给出登录入口',
        );
      }
    });
  });

  /// 用 [openLnReaderWebLogin] 推一页替身登录页，替身记下收到的目标与 jar，
  /// 点 [result] 对应按钮 pop。
  Future<bool?> runLogin(WidgetTester tester, {required bool result}) async {
    Uri? openedTarget;
    MangaCookieJar? openedJar;
    bool? outcome;
    await pump(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async {
            outcome = await openLnReaderWebLogin(
              context,
              manager: manager,
              plugin: manager.installed.single,
              pageBuilder: (Uri target, MangaCookieJar jar) {
                openedTarget = target;
                openedJar = jar;
                return Builder(
                  builder: (BuildContext page) => TextButton(
                    onPressed: () => Navigator.of(page).pop(result),
                    child: const Text('finish'),
                  ),
                );
              },
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(openedTarget, Uri.parse('https://syosetu.example/'));
    expect(
      identical(openedJar, cloudflare.jar),
      isTrue,
      reason: '登录页必须写出站桥读的那份 jar，否则登了也不生效',
    );
    await tester.tap(find.text('finish'));
    await tester.pumpAndSettle();
    return outcome;
  }

  testWidgets('登录完成：返回 true 并通知桥丢掉该站登录前的会话', (WidgetTester tester) async {
    final List<String> replaced = <String>[];
    cloudflare.addSiteSessionListener(replaced.add);
    expect(await runLogin(tester, result: true), isTrue);
    expect(replaced, <String>['syosetu.example']);
  });

  testWidgets('关页取消：返回 false，不动桥的会话', (WidgetTester tester) async {
    final List<String> replaced = <String>[];
    cloudflare.addSiteSessionListener(replaced.add);
    expect(await runLogin(tester, result: false), isFalse);
    expect(replaced, isEmpty);
  });

  testWidgets('源列表「⋯」菜单有「登录」', (WidgetTester tester) async {
    await pump(
      tester,
      Scaffold(
        body: CustomScrollView(
          slivers: <Widget>[
            LnReaderInstalledSourcesSection(
              manager: manager,
              onOpenSource: (LnReaderInstalledPlugin _) {},
            ),
          ],
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('novel_source_menu_syosetu')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.mihon_source_login), findsOneWidget);
  });

  /// 等浏览页把 [call] 交给假运行时、结果回来后的 setState 出帧。
  Future<void> untilCalled(WidgetTester tester, String call) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!runtime.calls.contains(call)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('runtime never received $call (got ${runtime.calls})');
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump();
    await tester.pump();
  }

  const ValueKey<String> loginKey = ValueKey<String>(
    'novel_source_login_syosetu',
  );

  testWidgets('浏览页加载失败时错误旁给「登录」，正常空结果不给', (WidgetTester tester) async {
    runtime.popularError = Exception('HTTP 401');
    await pump(
      tester,
      LnReaderSourceBrowsePage(
        manager: manager,
        plugin: manager.installed.single,
      ),
    );
    await untilCalled(tester, 'popular:1:false');
    expect(find.byKey(loginKey), findsOneWidget);
  });

  testWidgets('浏览页正常回空列表：不提示登录', (WidgetTester tester) async {
    await pump(
      tester,
      LnReaderSourceBrowsePage(
        manager: manager,
        plugin: manager.installed.single,
      ),
    );
    await untilCalled(tester, 'popular:1:false');
    expect(find.text(t.novel_source_no_results), findsOneWidget);
    expect(find.byKey(loginKey), findsNothing);
  });
}
