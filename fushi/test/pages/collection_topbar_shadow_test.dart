import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiEinkTheme;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
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
    final Finder scrim = find.descendant(
      of: page,
      matching: find.byType(FushiTopFadeScrim),
    );
    expect(scrim, findsOneWidget);
    final Finder scrimOpacity = find
        .ancestor(of: scrim, matching: find.byType(AnimatedOpacity))
        .first;
    expect(tester.widget<AnimatedOpacity>(scrimOpacity).opacity, 0);
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
    expect(
      tester.widget<AnimatedOpacity>(scrimOpacity).opacity,
      1,
      reason: '先确认正文已滚动并让遮罩淡入，避免只验证透明遮罩的首屏',
    );
    expect(tester.takeException(), isNull);

    final Rect bar = tester.getRect(
      find.descendant(of: page, matching: find.byType(AppBar)),
    );
    final Finder circleFinder = find.descendant(
      of: page,
      matching: find.byType(FushiPageChromeCircle),
    );
    expect(circleFinder, findsOneWidget, reason: '二级路由必须显示自动返回圆');
    final Rect circle = tester.getRect(circleFinder);
    expect(circle.bottom, lessThanOrEqualTo(bar.bottom));

    // 遮罩必须画在栏之下：Material 下返回圆整体按胶囊比例缩（56 → 48）后居中
    // 在 56 高的栏里、离栏下沿还有 4，测试渲染器的投影（≈3 px 就截止）够不到
    // 栏下沿，像素对比在栏外已经看不出遮罩盖没盖住投影——叠放顺序直接钉在真实
    // 页面的结构上。
    final Element stackElement = tester.element(
      find
          .ancestor(
            of: find.descendant(of: page, matching: find.byType(AppBar)),
            matching: find.byType(Stack),
          )
          .first,
    );
    final List<Element> stackChildren = <Element>[];
    stackElement.visitChildren(stackChildren.add);
    final int barIndex = stackChildren.indexWhere(
      (Element child) => child.widget is AppBar,
    );
    final int scrimIndex = stackChildren.indexWhere(
      (Element child) => find
          .descendant(
            of: find.byElementPredicate((Element e) => e == child),
            matching: find.byType(FushiTopFadeScrim),
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(barIndex, isNonNegative);
    expect(scrimIndex, isNonNegative, reason: '栏下沿应有共享渐隐遮罩');
    expect(
      scrimIndex,
      lessThan(barIndex),
      reason: '遮罩必须先画、胶囊后画，否则返回圆投影在栏下沿被盖成一条直线',
    );

    // 栏外投影的像素断言不在这里做：墨水屏不画投影（像素上本就看不出），
    // 有投影的 M3E 悬浮栏的像素对比由
    // test/widgets/floating_app_bar_scrim_shadow_test.dart 覆盖。本页在非墨水屏
    // 已改走海报面板的裸图标页头（不挂 AppBar、没有返回圆），这里只钉住仍带
    // AppBar 的墨水屏分支的叠放顺序。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
