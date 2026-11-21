import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/build_info.dart';
import 'package:fushi/src/updates/notice_feed.dart';
import 'package:fushi/src/updates/notice_layer.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// [NoticeLayer] 挂在 MaterialApp.builder 里（navigator 之上）：对话框经 navigatorKey
/// 弹进 navigator，全屏层盖住压栈出去的页面。
void main() {
  Future<PreferencesRepository> makePrefs() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository repo = PreferencesRepository(db);
    await repo.loadFromDb();
    return repo;
  }

  NoticeFeed makeFeed(PreferencesRepository prefs, String reply) => NoticeFeed(
    prefs: prefs,
    post: (Map<String, Object?> body) async => reply,
    version: () => '1',
    channel: () => 'stable',
    locale: () => 'en',
    buildInfo: () async => const BuildInfo(),
    usageStats: () => false,
    operatingSystem: 'linux',
  );

  String reply(List<Map<String, Object?>> notices) =>
      jsonEncode(<String, Object?>{'notices': notices, 'ttl': 600});

  Future<GlobalKey<NavigatorState>> pumpApp(
    WidgetTester tester,
    NoticeFeed feed, {
    Future<RemoteNotice?> Function()? localDialog,
  }) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
          builder: (BuildContext context, Widget? child) => NoticeLayer(
            feed: feed,
            navigatorKey: navigatorKey,
            localDialog: localDialog,
            child: child!,
          ),
        ),
      ),
    );
    return navigatorKey;
  }

  testWidgets('local dialog shows once above the navigator', (
    WidgetTester tester,
  ) async {
    final PreferencesRepository prefs = (await tester.runAsync(makePrefs))!;
    final NoticeFeed feed = makeFeed(
      prefs,
      reply(const <Map<String, Object?>>[]),
    );
    addTearDown(feed.dispose);
    int calls = 0;
    await pumpApp(
      tester,
      feed,
      localDialog: () async {
        calls++;
        return RemoteNotice(
          id: 'L',
          level: RemoteNoticeLevel.dialog,
          title: 'local title',
          body: 'local body',
          url: Uri.parse('https://example.com'),
        );
      },
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('local title'), findsOneWidget);
    expect(find.text('local body'), findsOneWidget);
    await tester.tap(find.text(t.notice_close));
    await tester.pumpAndSettle();
    expect(find.text('local title'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    // 弹过即记进「已弹过」：同一组签名下次冷启动不再弹。
    expect(feed.seenDialogIds, contains('L'));
  });

  testWidgets(
    'local dialog already seen for this signature does not show again',
    (WidgetTester tester) async {
      final PreferencesRepository prefs = (await tester.runAsync(makePrefs))!;
      final NoticeFeed feed = makeFeed(
        prefs,
        reply(const <Map<String, Object?>>[]),
      );
      addTearDown(feed.dispose);
      await tester.runAsync(() => feed.markDialogSeen('_local:seen'));
      await pumpApp(
        tester,
        feed,
        localDialog: () async => const RemoteNotice(
          id: '_local:seen',
          level: RemoteNoticeLevel.dialog,
          title: 'seen title',
          body: '',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('seen title'), findsNothing);
    },
  );

  testWidgets('block covers pushed routes', (WidgetTester tester) async {
    final PreferencesRepository prefs = (await tester.runAsync(makePrefs))!;
    final NoticeFeed feed = makeFeed(
      prefs,
      reply(<Map<String, Object?>>[
        <String, Object?>{
          'id': 'b',
          'level': 'block',
          'title': 'block title',
          'body': 'block body',
        },
      ]),
    );
    addTearDown(feed.dispose);
    final GlobalKey<NavigatorState> navigatorKey = await pumpApp(tester, feed);
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('pushed page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('pushed page'), findsOneWidget);
    await tester.runAsync(() async {
      feed.start();
      await feed.refresh();
    });
    await tester.pumpAndSettle();
    expect(find.text('block title'), findsOneWidget);
    // 全屏层盖在 navigator 之上：压栈出去的页面点不到。
    expect(find.text('pushed page').hitTestable(), findsNothing);
  });
}
