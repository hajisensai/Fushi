import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';

/// 字幕调整底部抽屉（PR-C）：贴底、默认占屏高约 42%、拖拽条可改高度、可收起成一条、
/// 关闭交给 onClose。视频（抽屉上方）始终可见。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget drawer) {
    LocaleSettings.setLocale(AppLocale.zhCn);
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const ColoredBox(
                key: ValueKey<String>('video'),
                color: Colors.black,
              ),
              drawer,
            ],
          ),
        ),
      ),
    );
  }

  const Key handle = ValueKey<String>('video-subtitle-drawer-handle');
  const Key drawerKey = ValueKey<String>('video-subtitle-drawer');
  const Key content = ValueKey<String>('drawer-content');

  testWidgets('贴底、占屏高约 42%，视频上半区完全露出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      wrap(
        const VideoTranslucentBottomDrawer(
          title: 'Subtitles',
          child: SizedBox.expand(key: content),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect drawer = tester.getRect(find.byKey(drawerKey));
    expect(drawer.bottom, closeTo(800 - 10, 1));
    expect(drawer.height, closeTo(800 * 0.42, 2));
    expect(drawer.top, greaterThan(400));
    expect(find.byKey(content), findsOneWidget);
  });

  testWidgets('拖拽条向上拖 → 抽屉变高；向下拖 → 变矮，夹在 20%..90%', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      wrap(
        const VideoTranslucentBottomDrawer(
          title: 'Subtitles',
          child: SizedBox.expand(key: content),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final double before = tester.getRect(find.byKey(drawerKey)).height;
    // 手势竞技场吃掉 kDragSlopDefault（20px）死区后才开始报 delta，抽屉长高的量 =
    // 位移 − 死区；两端夹紧的断言不受此影响（位移远超范围）。
    await tester.drag(find.byKey(handle), const Offset(0, -160));
    await tester.pumpAndSettle();
    final double taller = tester.getRect(find.byKey(drawerKey)).height;
    expect(taller, closeTo(before + 160 - kDragSlopDefault, 2));
    await tester.drag(find.byKey(handle), const Offset(0, 2000));
    await tester.pumpAndSettle();
    final double shortest = tester.getRect(find.byKey(drawerKey)).height;
    expect(shortest, closeTo(800 * 0.2, 2));
    await tester.drag(find.byKey(handle), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(drawerKey)).height, closeTo(800 * 0.9, 2));
  });

  testWidgets('收起只剩头部一条（内容卸载），再点展开回到原高度', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      wrap(
        const VideoTranslucentBottomDrawer(
          title: 'Subtitles',
          child: SizedBox.expand(key: content),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-drawer-collapse')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(content), findsNothing);
    expect(tester.getRect(find.byKey(drawerKey)).height, lessThan(80));
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-drawer-collapse')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(content), findsOneWidget);
    expect(
      tester.getRect(find.byKey(drawerKey)).height,
      closeTo(800 * 0.42, 2),
    );
  });

  testWidgets('关闭按钮调 onClose', (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(
      wrap(
        VideoTranslucentBottomDrawer(
          title: 'Subtitles',
          onClose: () => closed++,
          child: const SizedBox.expand(key: content),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-drawer-close')),
    );
    expect(closed, 1);
  });
}
