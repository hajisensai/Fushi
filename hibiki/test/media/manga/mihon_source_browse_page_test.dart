import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late Directory root;
  late HibikiDatabase database;
  late _BrowseRuntime runtime;
  late MihonManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-browse-');
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
    runtime = _BrowseRuntime();

    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'org.example.fixture',
        name: 'Raw Otaku fixture',
        versionCode: 1,
        versionName: '1.0.0',
        libVersion: '1.6',
        language: 'en',
        apkPath: 'extensions/org.example.fixture.ext',
        apkSha256: 'fixture-apk-sha',
        signerSha256: 'fixture-signer-sha',
        installedAt: 1,
      ),
    );
    await database.replaceMangaOnlineSources(
      'org.example.fixture',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'org.example.fixture',
          sourceId: '9223372036854775807',
          name: 'Raw Otaku',
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

  testWidgets(
    'opening a manga while its large chapter list resolves does not trip layout',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(2048, 1055));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Raw Otaku fixture'), findsOneWidget);
      await tester.tap(find.text('Raw Otaku fixture'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Add to manga shelf'), findsOneWidget);
    },
  );
}

class _BrowseRuntime extends Fake implements MihonRuntime {
  static const MihonManga manga = MihonManga(
    url: '/manga/fixture',
    title: 'Raw Otaku fixture',
  );

  @override
  Future<List<MihonFilter>> getFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      const <MihonFilter>[];

  @override
  Future<MihonMangaPage> getPopular(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      const MihonMangaPage(
        items: <MihonManga>[manga],
        hasNextPage: false,
      );

  @override
  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      const MihonManga(
        url: '/manga/fixture',
        title: 'Raw Otaku fixture',
        author: 'Fixture author',
        description: 'Fixture description',
        initialized: true,
      );

  @override
  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      List<MihonChapter>.generate(
        486,
        (int index) => MihonChapter(
          url: '/chapter/${index + 1}',
          name: 'Chapter ${index + 1}',
          uploadedAt: index,
          number: index + 1,
        ),
        growable: false,
      );

  @override
  Future<void> dispose() async {}
}
