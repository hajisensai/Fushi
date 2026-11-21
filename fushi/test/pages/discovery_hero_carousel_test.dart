import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart'
    show
        RenderClipPath,
        RenderClipRect,
        RenderClipRRect,
        RenderRepaintBoundary,
        RenderViewportBase;
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

  heroShadowBleedTests();

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

/// 设计稿 11-20 #14：漫画发现页大卡外面一圈「框」= 首块投影被轮播 PageView 的视口
/// 按自身矩形裁成直角。视口要给投影留出余量：首块色块到轮播之间每一层会裁切的
/// 祖先（滚动视口 / ClipRect…）都得把「块 + 投影范围」整个装下；像素上卡片下沿
/// 外 8px 处仍在投影里（比远处背景暗、且比 30px 处更暗 = 渐变，而不是硬台阶）。
void heroShadowBleedTests() {
  Rect shadowBounds(Rect block, List<BoxShadow> shadows) {
    Rect out = block;
    for (final BoxShadow s in shadows) {
      out = out.expandToInclude(
        block.shift(s.offset).inflate(s.blurRadius + s.spreadRadius),
      );
    }
    return out;
  }

  testWidgets('首块投影不被轮播视口裁切：裁切祖先都装得下块 + 投影，下沿外有渐变', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GlobalKey boundary = GlobalKey();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.white,
            body: RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SizedBox(height: 60),
                    DiscoveryHeroCarousel(
                      itemCount: 2,
                      autoAdvanceInterval: null,
                      itemBuilder: (BuildContext context, int index) =>
                          DiscoveryHeroBanner(
                            title: 'Title $index',
                            actionKey: ValueKey<String>('open-$index'),
                            onOpen: () {},
                          ),
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final RenderObject carousel = tester.renderObject(
      find.byType(DiscoveryHeroCarousel),
    );
    // 首块色块那层带投影的 DecoratedBox。
    final Finder shadowed = find.descendant(
      of: find.byKey(const ValueKey<String>('open-0')),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is ShapeDecoration &&
            ((w.decoration as ShapeDecoration).shadows?.isNotEmpty ?? false),
      ),
    );
    // 色块本身（最大的那层；竖封面也带一层小投影）。
    expect(shadowed, findsWidgets);
    final Element blockElement = shadowed.evaluate().reduce(
      (Element a, Element b) =>
          (a.size!.width * a.size!.height) >= (b.size!.width * b.size!.height)
          ? a
          : b,
    );
    final DecoratedBox box = blockElement.widget as DecoratedBox;
    final RenderBox blockBox = blockElement.renderObject! as RenderBox;
    final Rect block = blockBox.localToGlobal(Offset.zero) & blockBox.size;
    final Rect need = shadowBounds(
      block,
      (box.decoration as ShapeDecoration).shadows!,
    );
    RenderObject? node = blockBox.parent;
    int clips = 0;
    while (node != null && !identical(node, carousel.parent)) {
      // Material(transparency) 恒插一层 RenderClipPath，clipBehavior 为
      // none 时不裁，只算真正会裁的那几层。
      final bool clipping =
          (node is RenderViewportBase && node.clipBehavior != Clip.none) ||
          (node is RenderClipRect && node.clipBehavior != Clip.none) ||
          (node is RenderClipRRect && node.clipBehavior != Clip.none) ||
          (node is RenderClipPath && node.clipBehavior != Clip.none);
      if (clipping) {
        clips++;
        final RenderBox clipBox = node as RenderBox;
        final Rect clip = clipBox.localToGlobal(Offset.zero) & clipBox.size;
        expect(
          clip.left <= need.left + 0.5 &&
              clip.top <= need.top + 0.5 &&
              clip.right >= need.right - 0.5 &&
              clip.bottom >= need.bottom - 0.5,
          isTrue,
          reason: '${node.runtimeType} $clip 裁掉了投影 $need（块 $block）',
        );
      }
      node = node.parent;
    }
    expect(clips, greaterThan(0), reason: 'PageView 视口本身就是一层裁切');

    // 像素：下沿外 8px 在投影里、30px 更淡、远处是背景白。
    final ui.Image image =
        await tester.runAsync(
              () =>
                  (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(),
            )
            as ui.Image;
    final ByteData data = (await tester.runAsync<ByteData?>(
      () => image.toByteData(),
    ))!;
    int luma(Offset p) {
      final int i = (p.dy.round() * image.width + p.dx.round()) * 4;
      return data.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2);
    }

    final Offset origin = tester.getTopLeft(find.byKey(boundary));
    final double x = block.center.dx - origin.dx;
    final int near = luma(Offset(x, block.bottom - origin.dy + 8));
    final int mid = luma(Offset(x, block.bottom - origin.dy + 30));
    final int far = luma(Offset(x, block.bottom - origin.dy + 120));
    expect(far, 255 * 3, reason: '远处是背景白');
    expect(near, lessThan(mid), reason: '8px 处比 30px 处更暗（渐变）');
    expect(mid, lessThanOrEqualTo(far));
    expect(near, lessThan(far - 6), reason: '8px 处在投影里，不是被裁掉的背景');
    final String? shotDir = Platform.environment['FUSHI_PREVIEW_DIR'];
    if (shotDir != null) {
      final ByteData? png = await tester.runAsync<ByteData?>(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      await tester.runAsync(() async {
        final File out = File('$shotDir/discovery_hero_shadow.png');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(png!.buffer.asUint8List());
      });
    }
    image.dispose();
  });
}
