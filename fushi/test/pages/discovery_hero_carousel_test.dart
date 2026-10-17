import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';

/// 发现页 Hero 轮播（`discovery/discovery_hero_carousel.dart`）：漫画 / 视频
/// 发现页共用这一件，切页能力（箭头 / 指示器 / 方向键 / 拖动 / 自动轮播）在这里
/// 一处钉死。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pumpCarousel(
    WidgetTester tester, {
    int count = 4,
    Duration? interval,
    List<int>? changes,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                DiscoveryHeroCarousel(
                  itemCount: count,
                  autoAdvanceInterval: interval,
                  onPageChanged: changes?.add,
                  itemBuilder: (BuildContext context, int index) =>
                      DiscoveryHeroBanner(
                        title: 'Title $index',
                        actionLabel: 'Open $index',
                        actionKey: ValueKey<String>('open-$index'),
                        onOpen: () {},
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectPage(int index) {
    expect(find.text('Title $index'), findsOneWidget);
  }

  Future<TestGesture> hover(WidgetTester tester) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(DiscoveryHeroCarousel)));
    await tester.pumpAndSettle();
    return mouse;
  }

  testWidgets('悬停浮出左右箭头，点击切页且首尾回绕', (WidgetTester tester) async {
    final List<int> changes = <int>[];
    await pumpCarousel(tester, changes: changes);
    expectPage(0);

    await hover(tester);
    await tester.tap(find.byKey(const ValueKey<String>('discovery-hero-next')));
    await tester.pumpAndSettle();
    expectPage(1);
    expect(find.text('Title 0'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('discovery-hero-previous')),
    );
    await tester.pumpAndSettle();
    expectPage(0);

    // 首页再「上一个」回绕到末页。
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery-hero-previous')),
    );
    await tester.pumpAndSettle();
    expectPage(3);
    expect(changes, <int>[1, 0, 3]);
  });

  testWidgets('没有悬停时箭头不可点（触屏靠横滑）', (WidgetTester tester) async {
    await pumpCarousel(tester);
    final Finder next = find.byKey(
      const ValueKey<String>('discovery-hero-next'),
    );
    expect(next, findsOneWidget);
    expect(
      find.ancestor(
        of: next,
        matching: find.byWidgetPredicate(
          (Widget widget) => widget is IgnorePointer && widget.ignoring,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('点页码指示器直接跳到那一页', (WidgetTester tester) async {
    await pumpCarousel(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery-hero-dot-2')),
    );
    await tester.pumpAndSettle();
    expectPage(2);
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery-hero-dot-0')),
    );
    await tester.pumpAndSettle();
    expectPage(0);
  });

  testWidgets('焦点在 Hero 里时左右方向键切页，焦点跟到新页；到头不认领', (WidgetTester tester) async {
    await pumpCarousel(tester, count: 3);
    final Finder open0 = find.byKey(const ValueKey<String>('open-0'));
    Focus.of(
      tester.element(
        find.descendant(of: open0, matching: find.byType(Text)).first,
      ),
    ).requestFocus();
    await tester.pump();
    expect(_primaryFocusInside(tester, open0), isTrue);

    // 首页按 ←：不认领（交回全局方向导航），停在第 0 页。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expectPage(0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expectPage(1);
    expect(
      _primaryFocusInside(tester, find.byKey(const ValueKey<String>('open-1'))),
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expectPage(2);
    // 末页按 →：不认领。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expectPage(2);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expectPage(1);
  });

  testWidgets('鼠标按住横拖也能翻页', (WidgetTester tester) async {
    await pumpCarousel(tester);
    final TestGesture mouse = await tester.startGesture(
      tester.getCenter(find.byType(DiscoveryHeroCarousel)),
      kind: PointerDeviceKind.mouse,
    );
    // 拖过半个视口（1200 宽）：松手后落到下一页（不依赖甩动速度）。
    for (int i = 0; i < 16; i++) {
      await mouse.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expectPage(1);
  });

  testWidgets('自动轮播：到点前进；手动翻页重新计时；悬停暂停', (WidgetTester tester) async {
    await pumpCarousel(tester, interval: const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expectPage(1);

    // 6 秒时手动跳页：计时从这一刻重来，再过 6 秒不该自动前进。
    await tester.pump(const Duration(seconds: 6));
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery-hero-dot-3')),
    );
    await tester.pumpAndSettle();
    expectPage(3);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expectPage(3);
    // 满 8 秒前进（末页回绕到首页）。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expectPage(0);

    // 悬停期间不动。
    await hover(tester);
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expectPage(0);
  });

  testWidgets('只有一页时不画任何切页控件', (WidgetTester tester) async {
    await pumpCarousel(tester, count: 1);
    expectPage(0);
    expect(
      find.byKey(const ValueKey<String>('discovery-hero-next')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('discovery-hero-dot-0')),
      findsNothing,
    );
  });
}

bool _primaryFocusInside(WidgetTester tester, Finder finder) {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final Element target = tester.element(finder);
  bool inside = identical(focused, target);
  (focused as Element).visitAncestorElements((Element ancestor) {
    if (identical(ancestor, target)) inside = true;
    return !inside;
  });
  return inside;
}
