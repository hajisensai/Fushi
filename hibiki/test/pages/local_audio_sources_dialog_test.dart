import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki/src/pages/implementations/local_audio_sources_dialog.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget buildApp(Widget home) =>
      TranslationProvider(child: MaterialApp(home: Scaffold(body: home)));

  group('merge', () {
    test('keeps saved order and drops sources no longer in the db', () {
      final List<LocalAudioSourcePref> merged = LocalAudioSourcesDialog.merge(
        const <LocalAudioSourcePref>[
          LocalAudioSourcePref(name: 'forvo', enabled: false),
          LocalAudioSourcePref(name: 'gone'), // 库里已没有 → 丢弃
          LocalAudioSourcePref(name: 'nhk16'),
        ],
        <String>['nhk16', 'forvo'],
      );
      expect(merged.map((LocalAudioSourcePref s) => s.name),
          <String>['forvo', 'nhk16']);
      // 保留各自 enabled
      expect(merged.firstWhere((s) => s.name == 'forvo').enabled, isFalse);
    });

    test('appends newly discovered sources as enabled, after saved ones', () {
      final List<LocalAudioSourcePref> merged = LocalAudioSourcesDialog.merge(
        const <LocalAudioSourcePref>[LocalAudioSourcePref(name: 'nhk16')],
        <String>['nhk16', 'forvo', 'oald10'],
      );
      expect(merged.map((LocalAudioSourcePref s) => s.name),
          <String>['nhk16', 'forvo', 'oald10']);
      expect(merged[1].enabled, isTrue);
      expect(merged[2].enabled, isTrue);
    });
  });

  testWidgets('renders one row per merged source after enumeration', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        LocalAudioSourcesDialog(
          dbPath: '/tmp/x.db',
          savedPrefs: const <LocalAudioSourcePref>[
            LocalAudioSourcePref(name: 'nhk16'),
          ],
          listSources: () async => <String>['nhk16', 'forvo'],
          onApply: (_) async {},
        ),
      ),
    );
    // 枚举是 async：先 loading，settle 后出行。
    await tester.pumpAndSettle();
    expect(find.text('nhk16'), findsOneWidget);
    expect(find.text('forvo'), findsOneWidget);
  });

  testWidgets('empty db shows the no-sources message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        LocalAudioSourcesDialog(
          dbPath: '/tmp/empty.db',
          savedPrefs: const <LocalAudioSourcePref>[],
          listSources: () async => const <String>[],
          onApply: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.local_audio_no_sources), findsOneWidget);
  });

  testWidgets('close applies the current prefs', (WidgetTester tester) async {
    List<LocalAudioSourcePref>? applied;
    await tester.pumpWidget(
      buildApp(
        LocalAudioSourcesDialog(
          dbPath: '/tmp/x.db',
          savedPrefs: const <LocalAudioSourcePref>[],
          listSources: () async => <String>['nhk16'],
          onApply: (List<LocalAudioSourcePref> p) async => applied = p,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
    expect(applied, isNotNull);
    expect(applied!.single.name, 'nhk16');
  });
}
