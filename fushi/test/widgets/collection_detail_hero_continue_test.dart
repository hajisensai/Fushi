import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_detail_hero.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

// 合集详情 hero 的续播（2026-10-28）：「继续」按钮砍掉后用户实报「无法继续观看」，
// 拍板「不要按钮，但是要用户知道点击可以继续观看」——整块点按 = 继续，标题下
// 「▶ 继续 · 成员名」一行示意。窄屏信息（进度 / 标签）排在封面旁边，不再掉到
// 封面下方把右侧空出一大块。
void main() {
  const String longTitle = '[23卷] 無職転生 ~異世界行ったら本気だす~ 23 長い長いサブタイトルの続き';

  ThemeData theme(Brightness brightness) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    ),
    textTheme: brightness == Brightness.dark
        ? Typography.material2021().white
        : Typography.material2021().black,
  );

  Future<void> pumpHero(
    WidgetTester tester, {
    double width = 390,
    Brightness brightness = Brightness.light,
    VoidCallback? onContinue,
    VoidCallback? onEditTags,
    String? continueLabel = longTitle,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = Size(width * 3, 900 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(brightness),
        home: FushiGlassScope(
          child: Scaffold(
            body: SingleChildScrollView(
              // 与 media_collection_grid_detail_page 窄屏的 hPad 一致。
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: CollectionDetailHeroCard(
                name: '無職転生',
                memberCount: 5,
                finished: 1,
                progress: 0.4,
                covers: const <Widget>[
                  ColoredBox(
                    key: ValueKey<String>('cover-0'),
                    color: Color(0xFF336699),
                  ),
                ],
                continueLabel: continueLabel,
                onContinue: onContinue,
                onEditTags: onEditTags ?? () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final Finder continueLine = find.byKey(
    const ValueKey<String>('collection_detail_hero_continue'),
  );
  final Finder card = find.byKey(
    const ValueKey<String>('collection_detail_hero_card'),
  );

  for (final double width in <double>[390, 360]) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('整块点按继续，长成员名不溢出、没有按钮 '
          '(${width.toInt()}dp, ${brightness.name})', (
        WidgetTester tester,
      ) async {
        int continued = 0;
        await pumpHero(
          tester,
          width: width,
          brightness: brightness,
          onContinue: () => continued++,
        );
        expect(tester.takeException(), isNull);
        expect(continueLine, findsOneWidget);
        // 继续行在 hero 内收得住（省略号收尾）。
        final Rect hero = tester.getRect(card);
        final Rect line = tester.getRect(continueLine);
        expect(line.right, lessThanOrEqualTo(hero.right + 0.5));

        await tester.tap(find.text('無職転生'));
        await tester.pumpAndSettle();
        expect(continued, 1);

        expect(find.byType(FilledButton), findsNothing);
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('collection_detail_continue')),
          findsNothing,
        );
      });
    }
  }

  testWidgets('点「编辑标签」只编辑标签，不误触继续', (WidgetTester tester) async {
    int continued = 0;
    int edited = 0;
    await pumpHero(
      tester,
      onContinue: () => continued++,
      onEditTags: () => edited++,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('collection_detail_edit_tags')),
    );
    await tester.pumpAndSettle();
    expect(edited, 1);
    expect(continued, 0);
  });

  testWidgets('没有可续播的成员：不出继续行，整块也不可点', (WidgetTester tester) async {
    await pumpHero(tester, onContinue: null);
    expect(tester.takeException(), isNull);
    expect(continueLine, findsNothing);
    expect(card, findsNothing);
  });

  testWidgets('窄屏：进度排在封面旁边，不掉到封面下方', (WidgetTester tester) async {
    await pumpHero(tester, onContinue: () {});
    final Rect cover = tester.getRect(
      find.byKey(const ValueKey<String>('cover-0')),
    );
    final Rect percent = tester.getRect(
      find.byKey(const ValueKey<String>('collection_detail_hero_percent')),
    );
    expect(percent.left, greaterThan(cover.right));
    expect(percent.top, lessThan(cover.bottom));
  });
}
