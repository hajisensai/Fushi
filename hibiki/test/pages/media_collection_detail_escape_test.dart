import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 复现：合集详情页按 Esc 应退出层级（与真实 app 同构接线——
/// MaterialApp.builder 内包 [wrapWithGlobalNavigation]，registry 装默认绑定）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
    ]) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');
  });

  tearDown(() => db.close());

  Future<List<VideoBookRow>> loadMembers() async {
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    final List<VideoBookRow> all = await db.allVideoBooks();
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow r in all) r.bookUid: r,
    };
    return <VideoBookRow>[
      for (final MediaCollectionItemRow it in items)
        if (byUid[it.entryKey] case final VideoBookRow row) row,
    ];
  }

  testWidgets('详情页按 Esc 退出层级（全局导航接线下 maybePop 回上一页）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        navigatorKey: navKey,
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(
          navigatorKey: navKey,
          focusNavigationEnabled: false,
          registry: registry,
          child: child!,
        ),
        home: const Scaffold(body: Center(child: Text('library-home'))),
      ),
    ));
    await tester.pumpAndSettle();

    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          id: collectionId,
          name: 'Show',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadMembers: loadMembers,
        onOpenEpisode: (VideoBookRow _) {},
        onChanged: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('library-home'), findsNothing, reason: '详情页已压上');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(MediaCollectionDetailPage), findsNothing,
        reason: 'Esc 必须退出详情页层级');
    expect(find.text('library-home'), findsOneWidget);
  });

  testWidgets('焦点导航开启：详情页（无受管焦点目标）按 Esc 仍退出层级', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    // 与 main.dart 同构：HibikiFocusRoot（挂 fallbackNode，位于 Navigator 之上）
    // 包住全局导航层。详情页默认态没有任何受管焦点目标（轨道卡非受管、管理列表
    // 折叠），controller.activeContext 回落到 Navigator 之上的兜底 context——
    // 修复前 _handleGlobalEscape 解析不出路由，Esc 静默失效。
    await tester.pumpWidget(TranslationProvider(
      child: HibikiFocusRoot(
        enabled: true,
        child: MaterialApp(
          navigatorKey: navKey,
          builder: (BuildContext context, Widget? child) =>
              wrapWithGlobalNavigation(
            navigatorKey: navKey,
            focusNavigationEnabled: true,
            registry: registry,
            child: child!,
          ),
          home: const Scaffold(body: Center(child: Text('library-home'))),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          id: collectionId,
          name: 'Show',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadMembers: loadMembers,
        onOpenEpisode: (VideoBookRow _) {},
        onChanged: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCollectionDetailPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(MediaCollectionDetailPage), findsNothing,
        reason: '焦点导航开启且页面无受管目标时，Esc 也必须能退出详情页（BUG：'
            'activeContext 回落到 Navigator 之上的兜底节点，路由解析为 null 被吞）');
    expect(find.text('library-home'), findsOneWidget);
  });
}
