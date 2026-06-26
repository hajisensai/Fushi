import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/anki_settings_page.dart';
import 'package:hibiki/utils.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: child),
    );
  }

  testWidgets('anki handlebar picker fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AnkiHandlebarPickerDialog(
          title: 'Select value for Expression',
          initialValue: '{expression}',
          options: List<String>.generate(
            24,
            (index) => '{single-glossary-long-dictionary-name-$index}',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  // TODO-103 / BUG-187: the value picker used to clamp its whole body
  // (search field + options ListView) to `height * 0.24` capped at 320px, so
  // on any normal window the options area was a tiny sliver ("小得可怜"). It now
  // takes a generous share of the screen height so users can actually browse
  // the handlebar options. Removing the fix (re-introducing the 320px cap)
  // turns this red because the sheet can no longer grow past ~320px.
  testWidgets(
    'anki handlebar picker grows well past the old 320px cap on a tall window',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        buildApp(
          AnkiHandlebarPickerDialog(
            title: 'Select value for Expression',
            initialValue: '{expression}',
            options: List<String>.generate(
              30,
              (index) => '{single-glossary-long-dictionary-name-$index}',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      final Size sheetSize = tester.getSize(find.byType(HibikiModalSheetFrame));
      // Old behaviour capped the body at 320px; the sheet (header + body +
      // footer) is even larger now. Assert it clears that old ceiling with
      // margin so a regression to the cap is caught.
      expect(
        sheetSize.height,
        greaterThan(500.0),
        reason: 'picker should use a generous slice of the 1200px-tall window, '
            'not the old ~320px sliver',
      );
    },
  );

  // TODO-843: the picker shows localized friendly labels (via `labelFor`) but
  // tapping an option must still return the raw handlebar literal — the field
  // mapping persists the literal that the renderer understands, never the
  // display label. This guards the display-vs-storage invariant.
  testWidgets(
    'picker shows friendly labels but returns the raw literal on tap',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.reset);

      String? returned;
      await tester.pumpWidget(
        buildApp(
          Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    returned = await showDialog<String>(
                      context: context,
                      builder: (_) => AnkiHandlebarPickerDialog(
                        title: 'Select value for Image',
                        initialValue: '',
                        options: const <String>['{book-cover}', '{video-clip}'],
                        labelFor: ankiHandlebarLabel,
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Friendly labels are shown, raw literals are not.
      expect(find.text('Book Cover'), findsOneWidget);
      expect(find.text('Video Clip (GIF)'), findsOneWidget);
      expect(find.text('{book-cover}'), findsNothing);
      expect(find.text('{video-clip}'), findsNothing);

      // Tapping the friendly "Video Clip (GIF)" returns the raw literal.
      await tester.tap(find.text('Video Clip (GIF)'));
      await tester.pumpAndSettle();
      expect(returned, '{video-clip}');
    },
  );
}
