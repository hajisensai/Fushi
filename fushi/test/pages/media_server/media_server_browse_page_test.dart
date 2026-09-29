import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_browse_page.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_media_server_browser.dart';

/// 分区页：服务器列表空态 / 单台直进首页（返回才见列表）/ 两台列出两张卡；
/// Escape 沿嵌套栈一层层退。
void main() {
  late FushiDatabase database;
  late int settingsOpened;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    settingsOpened = 0;
  });

  tearDown(() async {
    await database.close();
  });

  Widget harness(
    List<MediaServerEntry> servers, {
    bool systemBackActive = true,
    List<GamepadButton>? outerGamepad,
  }) {
    Widget page = MediaServerBrowsePage(
      navigation: const Text('nav-probe'),
      repo: VideoBookRepository(database),
      loadServers: () async => servers,
      onPlay: (BuildContext _, MediaServerPlayRequest __) {},
      onOpenSettings: () => settingsOpened++,
      systemBackActive: systemBackActive,
    );
    if (outerGamepad != null) {
      // 模拟 HomePage 那层 Actions（LT/RT 换 tab、Y 搜索都注册在那里）。
      page = Actions(
        actions: <Type, Action<Intent>>{
          GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
            onInvoke: (GamepadButtonIntent intent) {
              outerGamepad.add(intent.button);
              return true;
            },
          ),
        },
        child: page,
      );
    }
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          // 同一测试里换参数重新 pump 时强制重建 State（否则嵌套栈沿用上一次的）。
          body: KeyedSubtree(
            key: ValueKey<bool>(systemBackActive),
            child: page,
          ),
        ),
      ),
    );
  }

  FakeMediaServerBrowser fakeServer(String id, String name) {
    final FakeMediaServerBrowser b = FakeMediaServerBrowser(
      serverId: 'fake:$id',
      displayName: name,
      serverUrl: 'http://$id:8096',
    );
    b.libraries.add(
      MediaServerLibrary(
        id: '$id-lib',
        name: '$name 的库',
        kind: MediaServerLibraryKind.movies,
      ),
    );
    b.children['$id-lib'] = fakeMovies(1, prefix: '$id-movie');
    return b;
  }

  testWidgets('空态：提示 + 「去设置添加服务器」', (WidgetTester tester) async {
    await tester.pumpWidget(harness(const <MediaServerEntry>[]));
    await tester.pumpAndSettle();

    expect(find.text('nav-probe'), findsOneWidget, reason: '分区页签在页头');
    expect(find.text(t.media_server_servers_empty_hint), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-list-go-settings')),
    );
    await tester.pump();
    expect(settingsOpened, 1);
  });

  testWidgets('分区页签在嵌套栈之上：进首页、钻进网格都不被路由盖住', (
    WidgetTester tester,
  ) async {
    final FakeMediaServerBrowser only = fakeServer('nas', 'NAS');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[MediaServerEntry(browser: only)]),
    );
    await tester.pumpAndSettle();

    // 单台一进分区就自动 push 首页——此前页签只在栈底的列表页里，这一步就被整页
    // 盖掉，用户看到的是「点开媒体服务器就占满整个页面」。
    expect(find.byType(MediaServerHomeView), findsOneWidget);
    expect(
      find.text('nav-probe').hitTestable(),
      findsOneWidget,
      reason: '首页压在栈顶时分区页签仍可见可点',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-home-search')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('media-server-grid-search')),
      findsOneWidget,
    );
    expect(
      find.text('nav-probe').hitTestable(),
      findsOneWidget,
      reason: '再钻一层（网格）页签仍在最上方',
    );
    expect(find.text('nav-probe'), findsOneWidget, reason: '页签只画一份');
  });

  testWidgets('单台：直接进那台的首页；返回后才出现列表', (WidgetTester tester) async {
    final FakeMediaServerBrowser only = fakeServer('nas', 'NAS');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[
        MediaServerEntry(browser: only, accountName: 'alice'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MediaServerHomeView), findsOneWidget);
    expect(only.listLibrariesCalls, 1, reason: '首页真的开始拉库');
    expect(
      find.byKey(const ValueKey<String>('media-server-card-fake:nas')),
      findsNothing,
      reason: '单台时列表不该露出来',
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(MediaServerHomeView), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('media-server-card-fake:nas')),
      findsOneWidget,
      reason: '返回后列表才出现，且不再自动进首页',
    );
    expect(find.text('alice'), findsOneWidget, reason: '卡片带账号');
  });

  testWidgets('两台：列出两张卡，点一张进它的首页；Escape 退回列表', (WidgetTester tester) async {
    final FakeMediaServerBrowser a = fakeServer('a', 'Alpha');
    final FakeMediaServerBrowser b = fakeServer('b', 'Beta');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[
        MediaServerEntry(browser: a),
        MediaServerEntry(browser: b),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MediaServerHomeView), findsNothing, reason: '多台不自动进');
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('http://b:8096'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-card-fake:b')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsOneWidget);
    expect(b.listLibrariesCalls, 1);
    expect(a.listLibrariesCalls, 0, reason: '没点的那台一个请求都不发');
    expect(find.text('Beta 的库'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byType(MediaServerHomeView),
      findsNothing,
      reason: 'Escape 退一层嵌套栈',
    );
    expect(find.byType(MediaServerListView), findsOneWidget);
  });

  testWidgets('系统返回：可见时退一层嵌套栈；被 Offstage 保活（systemBackActive=false）时不动',
      (WidgetTester tester) async {
    final FakeMediaServerBrowser only = fakeServer('nas', 'NAS');
    await tester.pumpWidget(
      harness(<MediaServerEntry>[MediaServerEntry(browser: only)]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsNothing,
        reason: '可见时 Android 返回沿嵌套栈退一层');
    expect(find.byType(MediaServerListView), findsOneWidget);

    // 换成「看不见」：壳把分区切走 / HomePage 切到别的 tab 时传 false。
    final FakeMediaServerBrowser hidden = fakeServer('nas2', 'NAS2');
    await tester.pumpWidget(
      harness(
        <MediaServerEntry>[MediaServerEntry(browser: hidden)],
        systemBackActive: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsOneWidget,
        reason: '看不见的分区不得偷偷 pop 自己的嵌套栈');
  });

  testWidgets('手柄：B 退一层由本页消费，其余按钮转发给祖先 Actions（不吞 LT/RT/Y）',
      (WidgetTester tester) async {
    final List<GamepadButton> outer = <GamepadButton>[];
    final FakeMediaServerBrowser only = fakeServer('nas', 'NAS');
    await tester.pumpWidget(
      harness(
        <MediaServerEntry>[MediaServerEntry(browser: only)],
        outerGamepad: outer,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsOneWidget);

    final BuildContext inside = tester.element(find.byType(MediaServerHomeView));
    Actions.maybeInvoke<GamepadButtonIntent>(
      inside,
      const GamepadButtonIntent(GamepadButton.y),
    );
    Actions.maybeInvoke<GamepadButtonIntent>(
      inside,
      const GamepadButtonIntent(GamepadButton.lt),
    );
    await tester.pumpAndSettle();
    expect(outer, <GamepadButton>[GamepadButton.y, GamepadButton.lt],
        reason: '非返回键必须到达 HomePage 那层，否则换 tab / 搜索在分区内失灵');
    expect(find.byType(MediaServerHomeView), findsOneWidget);

    Actions.maybeInvoke<GamepadButtonIntent>(
      inside,
      const GamepadButtonIntent(GamepadButton.b),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaServerHomeView), findsNothing, reason: 'B 退一层');
    expect(outer.length, 2, reason: 'B 被本页消费，不再上溯');
  });

  testWidgets('多线路：卡片出「切换线路」菜单，选另一条 → 回调 + 列表重取；单线路无入口',
      (WidgetTester tester) async {
    final FakeMediaServerBrowser a = fakeServer('a', 'Alpha');
    final FakeMediaServerBrowser b = fakeServer('b', 'Beta');
    final List<String> switched = <String>[];
    int loads = 0;
    // 切换后 loadServers 重取：Beta 换成按新线路建的浏览器。
    final FakeMediaServerBrowser bWan = FakeMediaServerBrowser(
      serverId: 'fake:b',
      displayName: 'Beta',
      serverUrl: 'https://b.example.com',
    );
    final Widget page = MediaServerBrowsePage(
      navigation: const Text('nav-probe'),
      repo: VideoBookRepository(database),
      loadServers: () async {
        loads++;
        return <MediaServerEntry>[
          MediaServerEntry(browser: a),
          MediaServerEntry(
            browser: switched.isEmpty ? b : bWan,
            routeUrls: const <String>['http://b:8096', 'https://b.example.com'],
            onSwitchRoute: (String url) async => switched.add(url),
          ),
        ];
      },
      onPlay: (BuildContext _, MediaServerPlayRequest __) {},
      onOpenSettings: () => settingsOpened++,
      systemBackActive: true,
    );
    await tester.pumpWidget(
      TranslationProvider(child: MaterialApp(home: Scaffold(body: page))),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('media-server-route-switch-fake:a')),
      findsNothing,
      reason: '单线路不出切换入口',
    );
    final Finder switcher =
        find.byKey(const ValueKey<String>('media-server-route-switch-fake:b'));
    expect(switcher, findsOneWidget);

    await tester.tap(switcher);
    await tester.pumpAndSettle();
    expect(find.text('https://b.example.com'), findsOneWidget, reason: '菜单列出线路');
    await tester.tap(find.text('https://b.example.com').last);
    await tester.pumpAndSettle();

    expect(switched, <String>['https://b.example.com']);
    expect(loads, 2, reason: '切换后列表重取');
    expect(find.text('https://b.example.com'), findsOneWidget, reason: '卡片显示新线路');
    expect(find.text('http://b:8096'), findsNothing);
    expect(find.byType(MediaServerHomeView), findsNothing, reason: '切线路不进首页');
  });
}
