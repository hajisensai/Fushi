import 'dart:async';
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
  test('source image queue starts only four cover fetches at a time', () async {
    final MihonSourceImageLoadQueue queue =
        MihonSourceImageLoadQueue(maxConcurrent: 4);
    final List<Completer<void>> gates = List<Completer<void>>.generate(
      10,
      (_) => Completer<void>(),
    );
    int active = 0;
    int maximumActive = 0;
    int started = 0;
    final List<Future<void>> tasks = <Future<void>>[
      for (int index = 0; index < gates.length; index++)
        queue.run<void>(() async {
          started++;
          active++;
          if (active > maximumActive) maximumActive = active;
          await gates[index].future;
          active--;
        }),
    ];

    await Future<void>.delayed(Duration.zero);
    expect(started, 4);
    expect(queue.active, 4);
    expect(queue.pending, 6);

    gates.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, 5);
    expect(maximumActive, 4);

    for (final Completer<void> gate in gates.skip(1)) {
      gate.complete();
    }
    await Future.wait<void>(tasks);
    expect(maximumActive, 4);
    expect(queue.active, 0);
    expect(queue.pending, 0);
  });

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

  testWidgets('a stale initial response cannot replace a newer search result',
      (WidgetTester tester) async {
    runtime.popularGate = Completer<MihonMangaPage>();
    runtime.searchGate = Completer<MihonMangaPage>();
    await tester.pumpWidget(
      MaterialApp(
        home: MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(manager.sources.single),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'new query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    runtime.searchGate!.complete(
      const MihonMangaPage(
        items: <MihonManga>[
          MihonManga(url: '/manga/new', title: 'New search result'),
        ],
        hasNextPage: false,
      ),
    );
    await tester.pump();
    expect(find.text('New search result'), findsOneWidget);

    runtime.popularGate!.complete(
      const MihonMangaPage(
        items: <MihonManga>[
          MihonManga(url: '/manga/old', title: 'Stale popular result'),
        ],
        hasNextPage: false,
      ),
    );
    await tester.pump();
    expect(find.text('New search result'), findsOneWidget);
    expect(find.text('Stale popular result'), findsNothing);
  });

  testWidgets('a duplicate-only next page terminates pagination',
      (WidgetTester tester) async {
    runtime.popularPages = <int, MihonMangaPage>{
      1: const MihonMangaPage(
        items: <MihonManga>[_BrowseRuntime.manga],
        hasNextPage: true,
      ),
      2: const MihonMangaPage(
        items: <MihonManga>[_BrowseRuntime.manga],
        hasNextPage: true,
      ),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(manager.sources.single),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Raw Otaku fixture'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pump();
    await tester.pump();

    expect(find.text('Raw Otaku fixture'), findsOneWidget);
    expect(find.byIcon(Icons.add_circle_outline), findsNothing);
  });
}

class _BrowseRuntime extends Fake implements MihonRuntime {
  static const MihonManga manga = MihonManga(
    url: '/manga/fixture',
    title: 'Raw Otaku fixture',
  );
  Completer<MihonMangaPage>? popularGate;
  Completer<MihonMangaPage>? searchGate;
  Map<int, MihonMangaPage>? popularPages;

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
      popularGate != null
          ? popularGate!.future
          : popularPages?[page] ??
              const MihonMangaPage(
                items: <MihonManga>[manga],
                hasNextPage: false,
              );

  @override
  Future<MihonMangaPage> search(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      searchGate?.future ??
      const MihonMangaPage(items: <MihonManga>[], hasNextPage: false);

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
