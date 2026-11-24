// 查词页「查词历史」的 Cupertino 版（用户 2026-11-24「查词的组件这块也换 cupertino」）：
// Apple 下历史行坐在 inset grouped 分组里（与「最近搜索」同一种外壳），颜色标签是行首
// 小圆点（不是 M3E 的满高色条），命中词典数是 secondaryLabel 纯文字（不是 tonal 胶囊），
// 标题最多两行省略；「⋯」/ 右键 / 长按弹同一张 Apple 菜单（收藏 / 移出历史）；焦点 +
// Enter 打开条目、方向键在行间移动。M3E 色条行不变。

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/lookup/apple/apple_lookup_history_row.dart';
import 'package:fushi/src/pages/implementations/lookup_history_row.dart';
import 'package:fushi/src/utils/components/fushi_apple_glyph_button.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme({required bool glass}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  textTheme: Typography.material2021().black,
  glassDesign: glass,
).copyWith(platform: TargetPlatform.iOS);

class _Log {
  final List<String> events = <String>[];
}

LookupHistoryRowData _data(String term, _Log log, {int count = 3}) =>
    LookupHistoryRowData(
      term: term,
      subtitleParts: const <String>['知識', 'ちしき'],
      dictionaryCount: count,
      selected: false,
      onOpen: () => log.events.add('open:$term'),
      onFavorite: () => log.events.add('favorite:$term'),
      onRemove: () => log.events.add('remove:$term'),
    );

Future<void> _pumpApple(
  WidgetTester tester,
  _Log log, {
  List<String> terms = const <String>['win today', '比賽', '妖怪'],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: _theme(glass: true),
        home: FushiGlassScope(
          child: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < terms.length; i++)
                  AppleLookupHistoryRow(
                    key: ValueKey<String>('row_$i'),
                    data: _data(terms[i], log),
                    index: i,
                    count: terms.length,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('Apple 行：分组外壳 + 小色点，无满高色条、无 tonal 胶囊', (
    WidgetTester tester,
  ) async {
    final _Log log = _Log();
    await _pumpApple(
      tester,
      log,
      terms: <String>[
        'Considering our peoples\' lifespans, I\'ll probably outlive you '
            'and everyone else in this room for a very long time',
        '比賽',
      ],
    );

    // 每行都是 inset grouped 分组里的一格（与「最近搜索」同一种外壳）。
    expect(find.byType(FushiGroupedListItem), findsNWidgets(2));
    expect(find.byType(FushiAppleGroupSurface), findsNWidgets(2));

    // 颜色标签 = 10×10 圆点。
    final Finder dots = find.byKey(
      const ValueKey<String>('lookup_history_apple_tag_dot'),
    );
    expect(dots, findsNWidgets(2));
    for (final Element dot in dots.evaluate()) {
      expect(
        (dot.renderObject! as RenderBox).size,
        const Size.square(kAppleLookupHistoryTagDot),
      );
      final BoxDecoration deco =
          (dot.widget as DecoratedBox).decoration as BoxDecoration;
      expect(deco.shape, BoxShape.circle);
    }
    // 没有 M3E 的 8×28 满高色条。
    final Iterable<Size> boxSizes = find
        .byType(DecoratedBox)
        .evaluate()
        .map((Element e) => (e.renderObject! as RenderBox).size);
    expect(boxSizes, isNot(contains(const Size(8, 28))));

    // 计数是纯文字：不是 FushiTag，祖先里也没有胶囊底。
    expect(find.byType(FushiTag), findsNothing);
    final Finder count = find
        .byKey(const ValueKey<String>('lookup_history_apple_count'))
        .first;
    expect(
      find.descendant(of: count, matching: find.text('3')),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: count,
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is ShapeDecoration &&
              (w.decoration! as ShapeDecoration).shape is StadiumBorder,
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: count,
        matching: find.byWidgetPredicate(
          (Widget w) => w is DecoratedBox || w is Container,
        ),
      ),
      findsNothing,
    );

    // 标题：label 色正文字号，最多两行省略（不是 M3E 的大粗体不限行）。
    final Text title = tester.widget<Text>(
      find.byKey(const ValueKey<String>('lookup_history_row_term')).first,
    );
    expect(title.maxLines, 2);
    expect(title.overflow, TextOverflow.ellipsis);
    final BuildContext ctx = tester.element(find.byType(Scaffold));
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(ctx);
    expect(title.style?.fontSize, metrics.titleSize);
    expect(title.style?.fontWeight, FontWeight.w400);
    final Text subtitle = tester.widget<Text>(
      find.byKey(const ValueKey<String>('lookup_history_row_subtitle')).first,
    );
    expect(subtitle.data, '知識・ちしき');
    expect(subtitle.style?.color, metrics.subtitleStyle(ctx).color);
  });

  testWidgets('「⋯」、右键、长按都能打开全部动作', (WidgetTester tester) async {
    final _Log log = _Log();
    await _pumpApple(tester, log);

    // 「⋯」：裸字形按钮。
    expect(find.byType(FushiAppleGlyphButton), findsNWidgets(3));
    await tester.tap(
      find.byKey(const ValueKey<String>('lookup_history_apple_more')).first,
    );
    await tester.pumpAndSettle();
    expect(find.text(t.lookup_history_favorite), findsOneWidget);
    expect(find.text(t.lookup_history_remove), findsOneWidget);
    await tester.tap(find.text(t.lookup_history_favorite));
    await tester.pumpAndSettle();
    expect(log.events, <String>['favorite:win today']);

    // 右键第二行。
    await tester.tap(
      find.text('比賽'),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.lookup_history_remove));
    await tester.pumpAndSettle();
    expect(log.events.last, 'remove:比賽');

    // 长按第三行。
    await tester.longPress(find.text('妖怪'));
    await tester.pumpAndSettle();
    expect(find.text(t.lookup_history_favorite), findsOneWidget);
    await tester.tap(find.text(t.lookup_history_favorite));
    await tester.pumpAndSettle();
    expect(log.events.last, 'favorite:妖怪');
    // 菜单动作都不会顺带打开条目。
    expect(log.events.where((String e) => e.startsWith('open:')), isEmpty);
  });

  testWidgets('焦点 + Enter 打开条目，方向键在行间移动', (WidgetTester tester) async {
    final _Log log = _Log();
    await _pumpApple(tester, log);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(log.events, <String>['open:win today']);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(log.events.last, 'open:比賽');
  });

  testWidgets('M3E 色条行不变：满高色条 + 计数胶囊', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: _theme(glass: false),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: LookupHistoryCollageRow(
                term: '比賽',
                subtitle: '比・ひ',
                dictionaryCount: 29,
                selected: false,
                onOpen: () {},
                onFavorite: () {},
                onRemove: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Iterable<Size> boxSizes = find
        .byType(DecoratedBox)
        .evaluate()
        .map((Element e) => (e.renderObject! as RenderBox).size);
    expect(boxSizes, contains(const Size(8, 28)));
    final Container pill = tester.widget<Container>(
      find.byKey(const ValueKey<String>('lookup_history_row_count')),
    );
    expect((pill.decoration! as ShapeDecoration).shape, isA<StadiumBorder>());
    expect(find.byType(AppleLookupHistoryRow), findsNothing);
  });
}
