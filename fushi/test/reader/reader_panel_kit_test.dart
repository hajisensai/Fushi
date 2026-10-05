import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi/reader_panel_kit.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('header shows cookie badge, title, subtitle and close', (
    WidgetTester tester,
  ) async {
    bool closed = false;
    await tester.pumpWidget(
      _host(
        ReaderPanelHeader(
          title: 'Audiobook',
          subtitle: 'Chapter 3',
          icon: Icons.headphones,
          onClose: () => closed = true,
        ),
      ),
    );
    expect(find.text('Audiobook'), findsOneWidget);
    expect(find.text('Chapter 3'), findsOneWidget);
    final DecoratedBox badge = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('fushi_side_sheet_icon')),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      (badge.decoration as ShapeDecoration).shape,
      isA<ReaderCookieBorder>(),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_side_sheet_close')),
    );
    expect(closed, isTrue);
  });

  testWidgets('tabs switch selection through the connected group', (
    WidgetTester tester,
  ) async {
    String selected = 'a';
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              ReaderPanelTabs<String>(
                tabs: const <ReaderPanelTab<String>>[
                  ReaderPanelTab<String>(value: 'a', label: 'Contents'),
                  ReaderPanelTab<String>(value: 'b', label: 'Bookmarks'),
                ],
                selected: selected,
                onChanged: (String v) => setState(() => selected = v),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Bookmarks'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
  });

  testWidgets('material progress is the expressive wavy bar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const ReaderPanelProgress(value: 0.4)));
    expect(find.byType(FushiWavyLinearProgress), findsOneWidget);
  });

  testWidgets('quote card, list item current state and empty state', (
    WidgetTester tester,
  ) async {
    int taps = 0;
    await tester.pumpWidget(
      _host(
        Column(
          children: <Widget>[
            ReaderQuoteCard(
              text: '吾輩は猫である。',
              meta: '12.5%',
              current: true,
              onTap: () => taps++,
            ),
            ReaderPanelListItem(
              title: 'Chapter 1',
              current: true,
              onTap: () => taps++,
            ),
            const ReaderPanelEmpty(
              icon: Icons.bookmark_border,
              message: 'No bookmarks yet',
            ),
            const ReaderStatNumber(value: '42', unit: '%', label: 'Book'),
          ],
        ),
      ),
    );
    await tester.tap(find.text('吾輩は猫である。'));
    await tester.tap(find.text('Chapter 1'));
    expect(taps, 2);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('No bookmarks yet'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.selected == true,
      ),
      findsNWidgets(2),
    );
  });
}
