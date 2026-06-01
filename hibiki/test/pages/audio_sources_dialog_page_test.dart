import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/pages/implementations/dictionary_settings_dialog_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return TranslationProvider(
      child: MaterialApp(home: home),
    );
  }

  testWidgets('audio sources dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: List.generate(
            12,
            (index) => AudioSourceConfig.remoteAudio(
              url:
                  'https://audio.example.com/very/long/source/$index/{term}/{reading}',
            ),
          ),
          onSave: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });
}
