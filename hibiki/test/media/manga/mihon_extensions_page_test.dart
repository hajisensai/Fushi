import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late Directory root;
  late HibikiDatabase database;
  late MihonManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('hibiki-mihon-extensions-');
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
    await database.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: 'https://repo.example/index.json',
        name: 'Fixture repository',
        format: MihonStoreFormat.currentJson.name,
        signingKey: const Value<String?>('aabb'),
      ),
    );
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: _PageRuntime(),
    );
    await manager.reload();
    manager.available = <MihonAvailableExtension>[
      _extension(
        name: 'フェイト Extension',
        packageName: 'org.example.fate',
        sourceName: 'Moon source',
      ),
      _extension(
        name: 'Unrelated extension',
        packageName: 'org.example.package-hit',
        sourceName: 'Other source',
      ),
    ];
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('search filters extensions by normalized name and package',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: MihonExtensionsPage(manager: manager),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('フェイト Extension'), findsOneWidget);
    expect(find.text('Unrelated extension'), findsOneWidget);

    final Finder search =
        find.byKey(const ValueKey<String>('mihon_extension_search_field'));
    await tester.enterText(search, 'ふぇいと');
    await tester.pump();

    expect(find.text('フェイト Extension'), findsOneWidget);
    expect(find.text('Unrelated extension'), findsNothing);

    await tester.enterText(search, 'package hit');
    await tester.pump();

    expect(find.text('フェイト Extension'), findsNothing);
    expect(find.text('Unrelated extension'), findsOneWidget);
  });
}

MihonAvailableExtension _extension({
  required String name,
  required String packageName,
  required String sourceName,
}) =>
    MihonAvailableExtension(
      storeUrl: 'https://repo.example/index.json',
      name: name,
      packageName: packageName,
      apkUrl: 'https://repo.example/$packageName.apk',
      iconUrl: '',
      libVersion: '1.6',
      versionCode: 1,
      versionName: '1.6.1',
      language: 'ja',
      contentWarning: 0,
      sources: <MihonAvailableSource>[
        MihonAvailableSource(
          id: packageName,
          name: sourceName,
          language: 'ja',
          baseUrl: 'https://source.example/$packageName',
        ),
      ],
    );

class _PageRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
