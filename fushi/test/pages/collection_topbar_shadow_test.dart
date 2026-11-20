import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiEinkTheme;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3075：书架 / 漫画 / 游戏使用的真实网格合集页（墨水屏分支）是普通
/// Scaffold。滚动使栏下沿遮罩淡入后，遮罩必须画在栏之下、不截返回圆投影。
void main() {
  testWidgets('BUG-3075 网格合集滚动后遮罩不截断返回圆投影', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    tester.view.physicalSize = const Size(392, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int collectionId = await db.createMediaCollection('测试合集');
    for (int i = 0; i < 12; i++) {
      await db.addToCollection(collectionId, MediaKind.epub, 'book-$i');
    }
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      collectionId,
    ))!;

    final GlobalKey boundaryKey = GlobalKey();
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            debugShowCheckedModeBanner: false,
            // 重设计外壳（海报面板 + 裸图标页头）不挂 AppBar；带 AppBar 与返回圆
            // 的普通 Scaffold 分支只剩墨水屏在走，按墨水屏主题覆盖它。
            theme: ThemeData(
              useMaterial3: true,
              scaffoldBackgroundColor: Colors.white,
              extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(true)],
            ),
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      ),
    );
    // 真正 push 二级页面，让生产 FushiAppBar 自动提供返回圆。
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => MediaCollectionGridDetailPage(
          database: db,
          collection: collection,
          memberCardBuilder:
              (
                String mediaType,
                String entryKey, {
                VoidCallback? onRemoveFromCollection,
              }) => const ColoredBox(color: Color(0xFFE8EAF0)),
          onChanged: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder page = find.byType(MediaCollectionGridDetailPage);
    expect(
      tester
          .widget<Scaffold>(
            find.descendant(of: page, matching: find.byType(Scaffold)),
          )
          .extendBodyBehindAppBar,
      isFalse,
      reason: '必须覆盖真实网格合集的普通 Scaffold 分支',
    );

    final Finder scrollView = find.descendant(
      of: page,
      matching: find.byType(CustomScrollView),
    );
    await tester.drag(scrollView, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 2026-11-15 起墨水屏下 FushiAppBar 画静态 AppBar（不走悬浮页头行）：
    // 栏下沿没有渐隐遮罩，BUG-3075「遮罩截断返回键投影」的前提随之消失；
    // 滚动后也不能冒出遮罩，返回键须整体落在栏内。
    expect(
      find.descendant(of: page, matching: find.byType(FushiTopFadeScrim)),
      findsNothing,
      reason: '墨水屏不画滚动渐隐遮罩',
    );
    final Rect bar = tester.getRect(
      find.descendant(of: page, matching: find.byType(AppBar)),
    );
    final Finder backFinder = find.descendant(
      of: page,
      matching: find.byType(BackButton),
    );
    expect(backFinder, findsOneWidget, reason: '二级路由必须显示自动返回键');
    final Rect back = tester.getRect(backFinder);
    expect(back.top, greaterThanOrEqualTo(bar.top));
    expect(back.bottom, lessThanOrEqualTo(bar.bottom));

    // 栏外投影的像素断言不在这里做：有投影的 M3E 悬浮栏由
    // test/widgets/floating_app_bar_scrim_shadow_test.dart 覆盖。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
