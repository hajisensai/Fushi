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
      child: MaterialApp(home: Scaffold(body: home)),
    );
  }

  test('isValidRemoteUrl enforces http(s) + a term/reading placeholder', () {
    expect(AudioSourcesDialog.isValidRemoteUrl('https://x.com/{term}'), isTrue);
    expect(
        AudioSourcesDialog.isValidRemoteUrl('http://x.com/{reading}'), isTrue);
    // 无占位符
    expect(AudioSourcesDialog.isValidRemoteUrl('https://x.com/audio'), isFalse);
    // 非 http(s)
    expect(AudioSourcesDialog.isValidRemoteUrl('ftp://x.com/{term}'), isFalse);
    // 无 scheme / authority
    expect(AudioSourcesDialog.isValidRemoteUrl('{term}'), isFalse);
    expect(AudioSourcesDialog.isValidRemoteUrl(''), isFalse);
  });

  testWidgets('fits a compact desktop window with many remote sources', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: List<AudioSourceConfig>.generate(
            12,
            (int i) => AudioSourceConfig.remoteAudio(
              url: 'https://audio.example.com/$i/{term}/{reading}',
            ),
          ),
          onSave: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('rejects an invalid url and clears the error on a valid one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: const <AudioSourceConfig>[],
          onSave: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://x.com/{term}/{reading}',
    );
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsNothing);
  });

  testWidgets(
      'local audio group expands to reveal the add-db button and '
      'toggles the master switch', (WidgetTester tester) async {
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

    // 折叠态：add-db 按钮不在树里。
    expect(find.text(t.local_audio_add_db), findsNothing);

    // 点组头展开。
    await tester.tap(find.text(t.local_audio));
    await tester.pumpAndSettle();
    expect(find.text(t.local_audio_add_db), findsOneWidget);

    // 总开关回调（Switch.adaptive 在不同平台渲染 Material/Cupertino，二者皆匹配）。
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
