import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('lyrics mode hint dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(ReaderLyricsModeHintDialog(onClose: () {})),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.lyrics_mode_hint_title), findsOneWidget);
    expect(
      find.text(MaterialLocalizations.of(tester.element(find.byType(Dialog)))
          .okButtonLabel),
      findsOneWidget,
    );
  });

  testWidgets('SRT audio picker dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        ReaderSrtAudioPickerDialog(
          currentLabel: 'Very long current audio root label for compact layout',
          onPickFiles: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.srt_book_replace_audio), findsOneWidget);
    expect(find.text(t.srt_import_pick_audio_files), findsOneWidget);
  });
}
