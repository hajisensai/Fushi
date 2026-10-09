import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3075：书架 / 漫画 / 游戏使用的真实网格合集页是普通 Scaffold。
/// 滚动使栏下沿遮罩淡入后，返回圆落在栏外的投影仍应可见。
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
            theme: ThemeData(
              useMaterial3: true,
              scaffoldBackgroundColor: Colors.white,
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

    final ({ByteData bytes, int width}) pixels = (await tester.runAsync(
      () async {
        final RenderRepaintBoundary boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final ui.Image image = await boundary.toImage();
        final ByteData bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final int width = image.width;
        image.dispose();
        return (bytes: bytes, width: width);
      },
    ))!;
    int luminanceAt(Offset point) {
      final int offset =
          (point.dy.round() * pixels.width + point.dx.round()) * 4;
      return pixels.bytes.getUint8(offset) +
          pixels.bytes.getUint8(offset + 1) +
          pixels.bytes.getUint8(offset + 2);
    }

    // 栏外 2 px：遮罩几乎不透明，旧顺序会把两处都盖成白色；正确顺序
    // 应保留返回圆的投影，而远离胶囊的对照点仍为页面底色。
    final double y = bar.bottom + 2;
    final int underCircle = luminanceAt(Offset(circle.center.dx, y));
    final int awayFromChrome = luminanceAt(Offset(bar.right * 0.75, y));
    expect(awayFromChrome, greaterThanOrEqualTo(3 * 250));
    expect(
      underCircle,
      lessThan(awayFromChrome - 6),
      reason: '真实合集页返回圆在栏下沿外仍有投影，不能被渐隐遮罩截平',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
