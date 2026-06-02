import 'package:flutter/cupertino.dart';
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

  testWidgets('shows local audio master switch and add button when wired', (
    WidgetTester tester,
  ) async {
    bool? toggled;
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: const <AudioSourceConfig>[],
          onSave: (_) {},
          localAudioEnabled: false,
          onToggleLocalAudio: (bool v) async => toggled = v,
          onPickLocalDb: () async => null,
        ),
      ),
    );

    // (a) the add-db button label is present.
    expect(find.text(t.local_audio_add_db), findsOneWidget);

    // (b) toggling the master switch invokes onToggleLocalAudio with true.
    // Switch.adaptive renders a Material Switch or a CupertinoSwitch depending
    // on the host platform, so match either kind within the master-switch row.
    final Finder masterSwitch = find.descendant(
      of: find.ancestor(
        of: find.text(t.local_audio),
        matching: find.byType(Row),
      ),
      matching: find.byWidgetPredicate(
        (Widget w) => w is Switch || w is CupertinoSwitch,
      ),
    );
    expect(masterSwitch, findsOneWidget);

    await tester.tap(masterSwitch.first);
    await tester.pumpAndSettle();
    expect(toggled, isTrue);
  });
}
