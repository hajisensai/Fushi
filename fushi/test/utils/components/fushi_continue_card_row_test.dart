import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

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
}
