import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/cover_provider_epoch.dart';

/// 「继续」封面取色并列卡（[FushiContinueCardRow]）：配色来自封面种子色、墨水屏 /
/// Apple 退回中性卡面、State 跟条目走、系统字号放大不溢出、网格模式占格。
void main() {
  const int red = 0xFFE53935;
  const int blue = 0xFF1E88E5;
  ImageProvider img(String name) => AssetImage('continue_row_test/$name.png');

  FushiContinueEntry entry(
    String id, {
    ImageProvider? color,
    List<String> meta = const <String>[],
    IconData? metaIcon,
    Widget? badge,
    String? progressLabel,
  }) => FushiContinueEntry(
    key: ValueKey<String>('card-$id'),
    title: 'Book $id',
    cover: const ColoredBox(color: Color(0xFF808080)),
    colorSource: color,
    metaLines: meta,
    metaIcon: metaIcon,
    badge: badge,
    progress: 0.27,
    progressLabel: progressLabel,
    onOpen: () {},
  );

  Widget harness(
    List<FushiContinueEntry> entries, {
    bool eink = false,
    bool glass = false,
    double textScale = 1,
    double width = 900,
  }) => MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        FushiEinkTheme(eink),
        FushiGlassTheme(FushiGlassMaterial.off, glassDesign: glass),
      ],
    ),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(1200, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: FushiContinueCardRow.grid(
              entries: entries,
              cellWidth: 180,
              cellInset: 8,
              columns: 5,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> pump(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Color? cardColor(WidgetTester tester, String id) =>
      tester.widget<FushiCard>(find.byKey(ValueKey<String>('card-$id'))).color;

  setUp(() {
    coverColorSchemeCache
      ..debugStoreSeed(img('red'), red)
      ..debugStoreSeed(img('blue'), blue)
      ..debugStoreSeed(img('blank'), null);
  });

  testWidgets('卡面是封面种子色经 buildFushiColorScheme 出的 secondaryContainer', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      harness(<FushiContinueEntry>[entry('a', color: img('red'))]),
    );
    expect(
      cardColor(tester, 'a'),
      buildFushiColorScheme(
        seedColor: const Color(red),
        brightness: Brightness.light,
      ).secondaryContainer,
    );
  });

  testWidgets('无可用像素的封面退回中性卡面（不是谷歌蓝）', (WidgetTester tester) async {
    await pump(
      tester,
      harness(<FushiContinueEntry>[entry('a', color: img('blank'))]),
    );
    final ColorScheme cs = Theme.of(
      tester.element(find.byKey(const ValueKey<String>('card-a'))),
    ).colorScheme;
    expect(cardColor(tester, 'a'), fushiHeroBlockColor(cs));
  });

  for (final (String name, bool eink, bool glass) mode
      in <(String, bool, bool)>[
        ('eink', true, false),
        ('apple', false, true),
      ]) {
    testWidgets('${mode.$1} 下不取色，用中性卡面', (WidgetTester tester) async {
      await pump(
        tester,
        harness(
          <FushiContinueEntry>[entry('a', color: img('red'))],
          eink: mode.$2,
          glass: mode.$3,
        ),
      );
      final BuildContext ctx = tester.element(
        find.byKey(const ValueKey<String>('card-a')),
      );
      expect(cardColor(tester, 'a'), FushiDesignTokens.of(ctx).surfaces.group);
    });
  }

  testWidgets('条目重排后配色跟着条目走，不留在原下标', (WidgetTester tester) async {
    await pump(
      tester,
      harness(<FushiContinueEntry>[
        entry('a', color: img('red')),
        entry('b', color: img('blank')),
      ]),
    );
    final Color? redCard = cardColor(tester, 'a');
    await tester.pumpWidget(
      harness(<FushiContinueEntry>[
        entry('b', color: img('blank')),
        entry('a', color: img('red')),
      ]),
    );
    // 不等动画：重排那一帧第 0 格（b）就不能是 a 的红。
    await tester.pump();
    expect(cardColor(tester, 'b'), isNot(redCard));
    expect(cardColor(tester, 'a'), redCard);
  });

  testWidgets('进度文字：给了 progressLabel 用它，否则本地化百分比；远端云图标与角标都画', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      harness(<FushiContinueEntry>[
        entry('a', progressLabel: 'Read 27%'),
        entry(
          'b',
          meta: <String>['Ep 3'],
          metaIcon: Icons.cloud_outlined,
          badge: const Text('Playing'),
        ),
      ]),
    );
    expect(find.text('Read 27%'), findsOneWidget);
    expect(find.text('27%'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.text('Playing'), findsOneWidget);
  });

  testWidgets('系统字号放大：卡片长高、元信息放不下的整行不画，不溢出', (WidgetTester tester) async {
    final List<String> meta = <String>[
      for (int i = 0; i < 8; i++) 'meta line $i',
    ];
    await pump(
      tester,
      harness(<FushiContinueEntry>[entry('a', meta: meta)], textScale: 1.6),
    );
    expect(tester.takeException(), isNull);
    final double height = tester
        .getSize(find.byKey(const ValueKey<String>('card-a')))
        .height;
    expect(height, greaterThan(FushiContinueCardRow.coverHeight));
    // 8 行元信息不可能全放下：后面的整行不画。
    // 不画也不参与命中（元素仍在树里，只是没排进可见区）。
    expect(find.text('meta line 0').hitTestable(), findsOneWidget);
    expect(find.text('meta line 7').hitTestable(), findsNothing);
  });

  for (final (String name, double? fit, double bleed)
      in <(String, double?, double)>[
        ('fill + fitHeight（视频首页大卡旁，多行）', 420, 0),
        ('fill 单行（窄屏挂在大卡下）', null, 16),
      ]) {
    testWidgets('$name：悬停放大后的卡整张留在视口内，不被裁', (WidgetTester tester) async {
      await pump(
        tester,
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: SizedBox(
                  width: 700,
                  child: FushiContinueCardRow.fill(
                    entries: <FushiContinueEntry>[entry('a'), entry('b')],
                    gap: 12,
                    fitHeight: fit,
                    bleed: bleed,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final Finder card = find.byKey(const ValueKey<String>('card-a'));
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(card));
      await tester.pumpAndSettle();
      final Rect lifted = tester.getRect(card);
      final Rect viewport = tester.getRect(find.byType(Scrollable).first);
      // 确实放大了（否则下面的包含关系不说明问题）。
      expect(lifted.width, greaterThan(tester.getSize(card).width));
      expect(lifted.left, greaterThanOrEqualTo(viewport.left - 0.01));
      expect(lifted.right, lessThanOrEqualTo(viewport.right + 0.01));
      expect(lifted.top, greaterThanOrEqualTo(viewport.top - 0.01));
      expect(lifted.bottom, lessThanOrEqualTo(viewport.bottom + 0.01));
    });
  }

  group('FushiContinueCardRow.spanFor', () {
    test('至少两格；放不下最小卡宽就扩到整行（三列也不例外）', () {
      expect(
        FushiContinueCardRow.spanFor(
          cellWidth: 122,
          columns: 3,
          gap: 16,
          minCardWidth: 330,
        ),
        3,
      );
      expect(
        FushiContinueCardRow.spanFor(
          cellWidth: 200,
          columns: 6,
          gap: 16,
          minCardWidth: 330,
        ),
        2,
      );
      expect(
        FushiContinueCardRow.spanFor(
          cellWidth: 300,
          columns: 1,
          gap: 16,
          minCardWidth: 330,
        ),
        1,
      );
    });
  });

  // 用户 2026-11-05 反馈「视频ui优化」（平板横屏）：视频首页大卡旁只排得下一张
  // 取色卡时卡窄而高，16:9 剧照按卡高撑到 168，信息列只剩几十像素、标题被截成
  // 三个字。卡放不下「封面 | 信息列」时改成上图下文。
  group('取色卡封面与信息列自适应', () {
    FushiContinueEntry still(String id) => FushiContinueEntry(
      key: ValueKey<String>('card-$id'),
      title: 'Still $id',
      cover: ColoredBox(
        key: ValueKey<String>('cover-$id'),
        color: const Color(0xFF808080),
      ),
      coverAspectRatio: 16 / 9,
      progress: 0.5,
      onOpen: () {},
    );

    Future<void> pumpFill(
      WidgetTester tester, {
      required double width,
      double? fitHeight,
    }) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: FushiContinueCardRow.fill(
                  entries: <FushiContinueEntry>[still('a')],
                  gap: 12,
                  fitHeight: fitHeight,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('窄而高（大卡旁只放得下一张）：封面在上、标题在下且不被挤窄', (WidgetTester tester) async {
      // 高度只够排一行（平板横屏大卡约 275 高）：两行时每张卡太矮，按设计走
      // 「缩封面、左右排」。
      await pumpFill(tester, width: 360, fitHeight: 280);
      final Rect cover = tester.getRect(
        find.byKey(const ValueKey<String>('cover-a')),
      );
      final Rect title = tester.getRect(find.text('Still a'));
      expect(title.top, greaterThanOrEqualTo(cover.bottom));
      expect(cover.width / cover.height, closeTo(16 / 9, 0.01));
      expect(
        tester.getRect(find.byKey(const ValueKey<String>('card-a'))).width -
            cover.width,
        lessThan(80),
        reason: '封面铺满卡宽',
      );
    });

    testWidgets('宽卡仍是「封面 | 信息列」，信息列不窄于下限', (WidgetTester tester) async {
      await pumpFill(tester, width: 900, fitHeight: 320);
      final Rect cover = tester.getRect(
        find.byKey(const ValueKey<String>('cover-a')),
      );
      final Rect title = tester.getRect(find.text('Still a'));
      expect(title.left, greaterThan(cover.right));
    });

    testWidgets('窄而矮（手机单行）：左右排，封面缩到信息列放得下', (WidgetTester tester) async {
      await pumpFill(tester, width: 340);
      final Rect cover = tester.getRect(
        find.byKey(const ValueKey<String>('cover-a')),
      );
      final Rect card = tester.getRect(
        find.byKey(const ValueKey<String>('card-a')),
      );
      expect(
        card.right - cover.right,
        greaterThanOrEqualTo(FushiContinueCardRow.minInfoWidth),
      );
      expect(cover.width / cover.height, closeTo(16 / 9, 0.01));
    });
  });

  // 视频首页「继续观看」的取图链末端会回落到竖版海报（在线源只有竖图），方向
  // 交给解码后的实测宽高比：解码前按可能的 16:9 留宽，探测过就按实测。
  group('layoutAspectRatio', () {
    FushiContinueEntry probed(ImageProvider image) => FushiContinueEntry(
      key: const ValueKey<String>('p'),
      title: 'p',
      cover: const SizedBox(),
      orientationImage: image,
      onOpen: () {},
    );

    test('方向未探测时按 16:9 留宽', () {
      expect(
        probed(img('unprobed-layout')).layoutAspectRatio,
        closeTo(16 / 9, 1e-9),
      );
    });

    test('探测为竖图时按竖封面比例留宽', () {
      final ImageProvider image = img('portrait-layout');
      CoverProbeMemo.rememberAspect(
        image,
        0.7,
        epoch: CoverProviderEpoch.of(image),
      );
      addTearDown(() => CoverProbeMemo.evict(image));
      expect(probed(image).layoutAspectRatio, closeTo(2 / 3, 1e-9));
    });

    test('没有探测图的条目就是自己的 coverAspectRatio', () {
      expect(entry('x').layoutAspectRatio, closeTo(2 / 3, 1e-9));
    });
  });
}
