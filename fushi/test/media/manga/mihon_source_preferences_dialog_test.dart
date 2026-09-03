import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_sources_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late Directory root;
  late FushiDatabase database;
  late _PreferencesRuntime runtime;
  late MihonManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-mihon-preferences-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    runtime = _PreferencesRuntime();

    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'org.example.komga',
        name: 'Komga fixture',
        versionCode: 1,
        versionName: '1.0.0',
        libVersion: '1.6',
        language: 'en',
        apkPath: 'extensions/org.example.komga.ext',
        apkSha256: 'fixture-apk-sha',
        signerSha256: 'fixture-signer-sha',
        installedAt: 1,
      ),
    );
    await database.replaceMangaOnlineSources(
      'org.example.komga',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'org.example.komga',
          sourceId: '42',
          name: 'Komga',
          language: 'en',
        ),
      ],
    );

    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    await manager.initialise();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('Save persists focused text without requiring Enter', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (BuildContext context) => MihonPreferencesDialog(
                manager: manager,
                source: manager.sources.single,
              ),
            ),
            child: const Text('Open preferences'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open preferences'));
    await tester.pumpAndSettle();

    expect(find.text(t.dialog_save), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Address'),
      'https://komga.example',
    );
    expect(runtime.saved, isEmpty);

    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(runtime.saved, hasLength(1));
    expect(runtime.saved.single.key, 'address');
    expect(runtime.saved.single.value, 'https://komga.example');
    expect(find.text('Komga · ${t.mihon_source_preferences}'), findsNothing);

    final List<MangaSourcePreferenceRow> persisted = await database
        .getMangaSourcePreferences('org.example.komga', '42');
    expect(persisted, hasLength(1));
    expect(persisted.single.valueJson, '"https://komga.example"');
  });
}

class _PreferencesRuntime extends Fake implements MihonRuntime {
  List<MihonPreference> preferences = const <MihonPreference>[
    MihonPreference(
      key: 'address',
      kind: MihonPreferenceKind.text,
      title: 'Address',
      summary: 'The server address',
      value: '',
    ),
  ];
  final List<MihonPreference> saved = <MihonPreference>[];

  @override
  Future<List<MihonPreference>> getPreferences(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> persisted = const <MihonPreference>[],
  }) async => persisted.isEmpty ? preferences : persisted;

  @override
  Future<List<MihonPreference>> setPreference(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPreference preference, {
    required List<MihonPreference> persisted,
  }) async {
    saved.add(preference);
    preferences = <MihonPreference>[
      for (final MihonPreference current in preferences)
        if (current.key == preference.key) preference else current,
    ];
    return preferences;
  }

  @override
  Future<void> dispose() async {}
}
