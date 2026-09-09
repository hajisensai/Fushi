import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_settings_dialog_page.dart';
import 'package:fushi/utils.dart';

Widget _host(Widget child) => TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
        home: Scaffold(body: child),
      ),
    );

AudioSourceConfig _local(String path, {bool enabled = false}) =>
    AudioSourceConfig.localAudio(
      label: 'Saved pronunciation name',
      path: path,
      enabled: enabled,
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('missing database exposes an executable file reselect action',
      (WidgetTester tester) async {
    final List<String> pickedPaths = <String>[];
    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: <AudioSourceConfig>[_local('/cache/gone.db')],
      onSave: (_) {},
      isLocalDbAvailable: (_) async => false,
      onReplaceLocalDb: (String path) async {
        pickedPaths.add(path);
        return null;
      },
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.local_audio_file_unavailable), findsOneWidget);
    await tester.tap(find.text(t.local_audio_file_reselect));
    await tester.pumpAndSettle();
    expect(pickedPaths, <String>['/cache/gone.db']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('healthy database has no missing-file warning or recovery action',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: <AudioSourceConfig>[_local('/support/audio.db')],
      onSave: (_) {},
      isLocalDbAvailable: (_) async => true,
      onReplaceLocalDb: (_) async => null,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Saved pronunciation name'), findsOneWidget);
    expect(find.text(t.local_audio_file_unavailable), findsNothing);
    expect(find.text(t.local_audio_file_reselect), findsNothing);
  });

  testWidgets(
      'replacement saves the new path with existing priority and settings',
      (WidgetTester tester) async {
    final List<List<AudioSourceConfig>> saves = <List<AudioSourceConfig>>[];
    final AudioSourceConfig remote = AudioSourceConfig.remoteAudio(
      url: 'https://example.com/audio?term={term}',
      label: 'Remote source',
    );
    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: <AudioSourceConfig>[remote, _local('/cache/gone.db')],
      onSave: (List<AudioSourceConfig> sources) =>
          saves.add(List<AudioSourceConfig>.of(sources)),
      isLocalDbAvailable: (String path) async => path == '/support/new.db',
      onReplaceLocalDb: (_) async => AudioSourceConfig.localAudio(
        label: 'New file name',
        path: '/support/new.db',
        enabled: true,
      ),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.local_audio_file_reselect));
    await tester.pumpAndSettle();

    expect(saves, hasLength(1));
    expect(saves.single.first.url, remote.url);
    expect(saves.single.last.path, '/support/new.db');
    expect(saves.single.last.label, 'Saved pronunciation name');
    expect(saves.single.last.enabled, isFalse);
    expect(find.text('/cache/gone.db'), findsNothing);
    expect(find.text('/support/new.db'), findsOneWidget);
    expect(find.text(t.local_audio_file_unavailable), findsNothing);
  });

  testWidgets(
      'cancelled replacement keeps the old source and does not save early',
      (WidgetTester tester) async {
    final List<List<AudioSourceConfig>> saves = <List<AudioSourceConfig>>[];
    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: <AudioSourceConfig>[_local('/cache/gone.db', enabled: true)],
      onSave: (List<AudioSourceConfig> sources) =>
          saves.add(List<AudioSourceConfig>.of(sources)),
      isLocalDbAvailable: (_) async => false,
      onReplaceLocalDb: (_) async => null,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.local_audio_file_reselect));
    await tester.pumpAndSettle();

    expect(saves, isEmpty);
    expect(find.text('/cache/gone.db'), findsOneWidget);
    expect(find.text(t.local_audio_file_unavailable), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saves.single.single.path, '/cache/gone.db');
    expect(saves.single.single.enabled, isTrue);
  });

  testWidgets(
      'failed replacement retains the source and permits another attempt',
      (WidgetTester tester) async {
    final List<List<AudioSourceConfig>> saves = <List<AudioSourceConfig>>[];
    int attempts = 0;
    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: <AudioSourceConfig>[_local('/cache/gone.db')],
      onSave: (List<AudioSourceConfig> sources) =>
          saves.add(List<AudioSourceConfig>.of(sources)),
      isLocalDbAvailable: (_) async => false,
      onReplaceLocalDb: (_) async {
        attempts++;
        throw StateError('fixture import failure');
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.local_audio_file_reselect));
    await tester.pumpAndSettle();

    expect(saves, isEmpty);
    expect(find.text('/cache/gone.db'), findsOneWidget);
    expect(find.textContaining('fixture import failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(t.local_audio_file_reselect));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saves.single.single.path, '/cache/gone.db');
  });

  testWidgets('pending replacement follows its source after reorder and toggle',
      (WidgetTester tester) async {
    final Completer<AudioSourceConfig?> replacement =
        Completer<AudioSourceConfig?>();
    final List<List<AudioSourceConfig>> saves = <List<AudioSourceConfig>>[];
    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: <AudioSourceConfig>[
        _local('/cache/gone.db'),
        AudioSourceConfig.localAudio(
          label: 'Healthy second source',
          path: '/support/healthy.db',
        ),
      ],
      onSave: (List<AudioSourceConfig> sources) =>
          saves.add(List<AudioSourceConfig>.of(sources)),
      isLocalDbAvailable: (String path) async => path != '/cache/gone.db',
      onReplaceLocalDb: (_) => replacement.future,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.local_audio_file_reselect));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up).last);
    await tester.pump();
    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    replacement.complete(AudioSourceConfig.localAudio(
      label: 'Replacement filename',
      path: '/support/new.db',
    ));
    await tester.pumpAndSettle();

    expect(saves, hasLength(1));
    expect(saves.single.map((AudioSourceConfig source) => source.path),
        <String>['/support/healthy.db', '/support/new.db']);
    expect(saves.single.first.label, 'Healthy second source');
    expect(saves.single.first.enabled, isFalse);
    expect(saves.single.last.label, 'Saved pronunciation name');
    expect(saves.single.last.enabled, isTrue);
    expect(find.text(t.local_audio_file_unavailable), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
