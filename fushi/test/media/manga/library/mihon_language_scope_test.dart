import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2510：Mihon 适配器的「源语言范围」——只列同扩展、不同语言、已启用的源；
/// 语言为空 / `all` 的源不按语言取章，不给范围。
void main() {
  MangaOnlineSourceRow source(
    String sourceId, {
    required String language,
    String extensionPackage = 'org.example.mangadex',
    bool enabled = true,
  }) => MangaOnlineSourceRow(
    extensionPackage: extensionPackage,
    sourceId: sourceId,
    name: 'Source $sourceId',
    language: language,
    baseUrl: '',
    enabled: enabled,
    pinned: false,
    sortOrder: 0,
  );

  OnlineMangaLibraryEntry entryFor(String sourceId) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.mangadex',
    sourceId: sourceId,
    series: const OnlineMangaSeries(
      key: '/manga/x',
      title: 'Fixture',
      raw: <String, Object?>{},
    ),
    chapters: const <OnlineMangaChapter>[],
  );

  final List<MangaOnlineSourceRow> registry = <MangaOnlineSourceRow>[
    source('1', language: 'ja'),
    source('2', language: 'ko'),
    source('3', language: 'en'),
    source('4', language: 'fr', enabled: false),
    source('5', language: 'ja'), // 同语言镜像：对空列表没帮助
    source('6', language: 'all'),
    source('8', language: 'ko'), // 另一语言的镜像：每种语言只留一个
    source('7', language: 'en', extensionPackage: 'org.other'),
  ];

  test('siblingSourcesOf：同扩展、其它语言、已启用、有具体语言，按语言排序', () {
    final List<OnlineMangaSiblingSource> siblings =
        MihonLibraryAdapter.siblingSourcesOf(
          registry,
          extensionPackage: 'org.example.mangadex',
          language: 'ja',
        );
    expect(siblings.map((OnlineMangaSiblingSource s) => s.sourceId), <String>[
      '3',
      '2',
    ]);
    expect(siblings.first.language, 'en');
    expect(siblings.first.name, 'Source 3');
  });

  group('languageScope', () {
    late FushiDatabase database;
    late Directory root;
    late MihonManager manager;

    setUp(() async {
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      root = await Directory.systemTemp.createTemp('fushi-lang-scope-');
      manager = MihonManager(
        database: database,
        rootDirectory: root,
        runtime: _NoopRuntime(),
      )..sources = registry;
    });

    tearDown(() async {
      manager.dispose();
      await database.close();
      await root.delete(recursive: true);
    });

    test('从库行解析：给出本源语言与 sibling', () {
      final OnlineMangaSourceLanguageScope? scope = MihonLibraryAdapter(
        manager,
      ).languageScope(entryFor('1'));
      expect(scope, isNotNull);
      expect(scope!.language, 'ja');
      expect(
        scope.siblings.map((OnlineMangaSiblingSource s) => s.sourceId),
        <String>['3', '2'],
      );
    });

    test('语言为 all 的源不按语言取章：返回 null', () {
      expect(MihonLibraryAdapter(manager).languageScope(entryFor('6')), isNull);
    });

    test('源没登记 / 被禁用：返回 null，不抛', () {
      expect(MihonLibraryAdapter(manager).languageScope(entryFor('4')), isNull);
      expect(
        MihonLibraryAdapter(manager).languageScope(entryFor('404')),
        isNull,
      );
    });

    test('预置上下文优先于库行（预览态没有库行）', () {
      final MihonLibraryAdapter adapter = MihonLibraryAdapter(
        manager,
        presetContext: MihonSourceContext(
          extension: const MihonExtensionRef(
            packageName: 'org.example.mangadex',
            apkPath: 'x.apk',
          ),
          source: manager.sourceModel(source('99', language: 'zh')),
          preferences: const <MihonPreference>[],
        ),
      );
      final OnlineMangaSourceLanguageScope? scope = adapter.languageScope(
        entryFor('99'),
      );
      expect(scope?.language, 'zh');
      // 99 不在库里，sibling 仍按扩展从库行算：en / ja / ko 各留一个。
      expect(
        scope?.siblings.map((OnlineMangaSiblingSource s) => s.language),
        <String>['en', 'ja', 'ko'],
      );
    });
  });

  group('siblingOf', () {
    late FushiDatabase database;
    late Directory root;
    late MihonManager manager;

    /// 真写库：`_context` 走 `manager.initialise()` 会从 DB 重读 sources，
    /// 内存里赋的 `sources` 会被冲掉。
    Future<void> seed({required bool extensionEnabled}) async {
      await database.upsertMangaExtension(
        MangaExtensionsCompanion.insert(
          packageName: 'org.example.mangadex',
          name: 'MangaDex',
          versionCode: 1,
          versionName: '1',
          libVersion: '1.5',
          language: 'all',
          apkPath: 'mangadex.apk',
          apkSha256: 'x',
          signerSha256: 'y',
          enabled: Value<bool>(extensionEnabled),
          installedAt: 0,
        ),
      );
      await database.replaceMangaOnlineSources(
        'org.example.mangadex',
        <MangaOnlineSourcesCompanion>[
          for (final MangaOnlineSourceRow row in registry)
            if (row.extensionPackage == 'org.example.mangadex')
              MangaOnlineSourcesCompanion.insert(
                extensionPackage: row.extensionPackage,
                sourceId: row.sourceId,
                name: row.name,
                language: row.language,
                enabled: Value<bool>(row.enabled),
              ),
        ],
      );
    }

    setUp(() async {
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      root = await Directory.systemTemp.createTemp('fushi-sibling-of-');
      manager = MihonManager(
        database: database,
        rootDirectory: root,
        runtime: _NoopRuntime(),
      );
    });

    tearDown(() async {
      manager.dispose();
      await database.close();
      await root.delete(recursive: true);
    });

    test('成功：换成 sibling 的 sourceId、章节留空、adapter 带 sibling 的预置上下文', () async {
      await seed(extensionEnabled: true);
      final ({OnlineMangaRuntimeAdapter adapter, OnlineMangaLibraryEntry seed})
      handle = await MihonLibraryAdapter(manager).siblingOf(
        entryFor('1'),
        const OnlineMangaSiblingSource(
          sourceId: '3',
          name: 'Source 3',
          language: 'en',
        ),
      );
      expect(handle.seed.sourceId, '3');
      expect(handle.seed.extensionPackage, 'org.example.mangadex');
      expect(handle.seed.series.key, '/manga/x');
      expect(handle.seed.chapters, isEmpty);
      final MihonLibraryAdapter adapter = handle.adapter as MihonLibraryAdapter;
      expect(adapter.presetContext?.source.id, '3');
      expect(adapter.presetContext?.source.language, 'en');
      // 换源页上三件事都按 sibling 说话。
      expect(adapter.languageScope(handle.seed)?.language, 'en');
      expect(await adapter.sourceLabel(handle.seed), 'Source 3');
    });

    test('扩展被禁用：包成 OnlineMangaUnavailable，不裸抛', () async {
      await seed(extensionEnabled: false);
      await expectLater(
        MihonLibraryAdapter(manager).siblingOf(
          entryFor('1'),
          const OnlineMangaSiblingSource(
            sourceId: '3',
            name: 'Source 3',
            language: 'en',
          ),
        ),
        throwsA(isA<OnlineMangaUnavailable>()),
      );
    });

    test('sibling 源没登记：OnlineMangaUnavailable(sourceDisabled)', () async {
      await seed(extensionEnabled: true);
      await expectLater(
        MihonLibraryAdapter(manager).siblingOf(
          entryFor('1'),
          const OnlineMangaSiblingSource(
            sourceId: '404',
            name: 'nope',
            language: 'de',
          ),
        ),
        throwsA(
          isA<OnlineMangaUnavailable>().having(
            (OnlineMangaUnavailable e) => e.reason,
            'reason',
            OnlineMangaUnavailableReason.sourceDisabled,
          ),
        ),
      );
    });
  });
}

class _NoopRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
