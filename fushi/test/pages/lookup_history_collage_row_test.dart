import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/lookup_history_row.dart';

/// 设计稿 #lookup L1：查词历史从 2 列大色块改成列表行后，词形必须完整显示
/// （旧版被截成「やめ…」），第二行只显示历史里本来就存的写法 / 读音，行尾是
/// 命中词典数；整行可用键盘（Tab + Enter）打开。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget host({
    required String term,
    required String? subtitle,
    required VoidCallback onOpen,
    double width = 220,
  }) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: LookupHistoryCollageRow(
                term: term,
                subtitle: subtitle,
                dictionaryCount: 3,
                selected: false,
                onOpen: onOpen,
                onFavorite: () {},
                onRemove: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('long term wraps instead of being ellipsized', (
    WidgetTester tester,
  ) async {
    const String longTerm = '八つ当たりしてしまう気持ちを抑えられない';
    await tester.pumpWidget(
      host(term: longTerm, subtitle: 'やつあたり', onOpen: () {}),
    );
    await tester.pumpAndSettle();

    final Finder termFinder = find.byKey(
      const ValueKey<String>('lookup_history_row_term'),
    );
    expect(termFinder, findsOneWidget);
    final Text termText = tester.widget<Text>(termFinder);
    expect(termText.data, longTerm);
    expect(termText.maxLines, isNull);
    expect(termText.overflow, isNot(TextOverflow.ellipsis));

    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: termFinder, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    // 窄栏里长词要换行：段落高度超过一行。
    final double lineHeight = paragraph.getFullHeightForCaret(
      const TextPosition(offset: 0),
    );
    expect(paragraph.size.height, greaterThan(lineHeight * 1.5));

    expect(find.text('やつあたり'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('lookup_history_row_count')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no subtitle line when history has no distinct reading', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(term: 'する', subtitle: null, onOpen: () {}));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('lookup_history_row_subtitle')),
      findsNothing,
    );
  });

  testWidgets('dictionary count pill reads as a sentence to screen readers', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(term: 'やめる', subtitle: null, onOpen: () {}));
    await tester.pumpAndSettle();

    expect(
      // 胶囊的句子可能并进整行按钮节点的标签里，按子串匹配。
      find.bySemanticsLabel(
        RegExp(RegExp.escape(t.lookup_history_dictionary_count(count: 3))),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('Tab then Enter opens the history entry', (
    WidgetTester tester,
  ) async {
    int opened = 0;
    await tester.pumpWidget(
      host(term: 'やめる', subtitle: '止める', onOpen: () => opened++),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(opened, 1);
  });
}
