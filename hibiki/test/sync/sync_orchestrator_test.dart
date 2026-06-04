import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'fake_asset_store.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// Minimal [SyncBackend] test double: asset-store methods delegate to a shared
/// in-memory [FakeAssetStore]; book-folder/metadata methods are stubbed only as
/// far as the orchestrator's dictionary/audiobook paths need. Members the test
/// never reaches throw, so an unexpected code path fails loudly.
class FakeSyncBackend implements SyncBackend {
  FakeSyncBackend(this._store);
  final FakeAssetStore _store;

  // ── SyncAssetStore (delegated) ────────────────────────────────────
  @override
  Future<String> ensureNamespace(String name) => _store.ensureNamespace(name);
  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _store.ensureFolder(parentId, name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _store.findAsset(namespaceId, name);
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) =>
      _store.putAsset(namespaceId, name, file, onProgress: onProgress);
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) =>
      _store.getAsset(assetId, destination, onProgress: onProgress);
  @override
  Future<Object?> getJsonAsset(String assetId) => _store.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _store.deleteAsset(id, isFolder: isFolder);

  // ── Book-folder ops used by syncAudiobookPackages ─────────────────
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) =>
      _store.ensureFolder(rootFolderId, bookTitle);

  // ── Unreached members ─────────────────────────────────────────────
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      throw UnimplementedError();
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      throw UnimplementedError();
  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      throw UnimplementedError();
  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => 'root';
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}
}

SyncOrchestrator _orchestrator(
  HibikiDatabase db,
  SyncBackend backend,
  Directory dictRoot,
  Directory audioRoot,
  Directory tmp,
) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: dictRoot,
      audioDatabaseRoot: audioRoot,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncDictionary: true,
      syncLocalAudio: false,
    );

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orchestrator_');
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('dictionary syncs from source device to target device via backend',
      () async {
    final FakeAssetStore store = FakeAssetStore();
    final FakeSyncBackend backend = FakeSyncBackend(store);
    final Directory tmp = Directory('${work.path}/tmp')..createSync();

    // ── Source device: one dictionary + its resource files ──
    final HibikiDatabase srcDb = _memDb();
    addTearDown(srcDb.close);
    await srcDb.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
      name: 'testdict',
      formatKey: 'yomitan',
      order: 0,
      type: const Value('term'),
      metadataJson: const Value('{}'),
      hiddenLanguagesJson: const Value('[]'),
      collapsedLanguagesJson: const Value('[]'),
    ));
    final Directory srcDictRoot = Directory('${work.path}/src_dicts')
      ..createSync();
    Directory('${srcDictRoot.path}/testdict').createSync(recursive: true);
    File('${srcDictRoot.path}/testdict/index.json')
        .writeAsStringSync('{"title":"testdict"}');

    final SyncRunReport pushReport = SyncRunReport();
    await _orchestrator(srcDb, backend, srcDictRoot, tmp, tmp)
        .syncDictionaries(pushReport);
    expect(pushReport.dictionariesExported, 1);
    expect(pushReport.errors, isEmpty);

    // ── Target device: empty DB + empty resource root ──
    final HibikiDatabase tgtDb = _memDb();
    addTearDown(tgtDb.close);
    final Directory tgtDictRoot = Directory('${work.path}/tgt_dicts')
      ..createSync();

    final SyncRunReport pullReport = SyncRunReport();
    await _orchestrator(tgtDb, backend, tgtDictRoot, tmp, tmp)
        .syncDictionaries(pullReport);

    expect(pullReport.dictionariesImported, 1);
    expect(pullReport.errors, isEmpty);

    final List<DictionaryMetaRow> imported =
        await tgtDb.getAllDictionaryMetadata();
    expect(imported.map((DictionaryMetaRow d) => d.name), contains('testdict'));
    expect(
      File('${tgtDictRoot.path}/testdict/index.json').existsSync(),
      isTrue,
    );
  });

  test('dictionary already present on both sides is not re-imported', () async {
    final FakeAssetStore store = FakeAssetStore();
    final FakeSyncBackend backend = FakeSyncBackend(store);
    final Directory tmp = Directory('${work.path}/tmp')..createSync();

    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
      name: 'shared',
      formatKey: 'yomitan',
      order: 0,
      type: const Value('term'),
      metadataJson: const Value('{}'),
      hiddenLanguagesJson: const Value('[]'),
      collapsedLanguagesJson: const Value('[]'),
    ));
    final Directory dictRoot = Directory('${work.path}/dicts')..createSync();
    Directory('${dictRoot.path}/shared').createSync(recursive: true);
    File('${dictRoot.path}/shared/index.json').writeAsStringSync('{}');

    // First run pushes; second run on the same DB must be a no-op (present
    // on both sides → neither exported again nor imported).
    final SyncRunReport first = SyncRunReport();
    await _orchestrator(db, backend, dictRoot, tmp, tmp)
        .syncDictionaries(first);
    expect(first.dictionariesExported, 1);

    final SyncRunReport second = SyncRunReport();
    await _orchestrator(db, backend, dictRoot, tmp, tmp)
        .syncDictionaries(second);
    expect(second.dictionariesExported, 0);
    expect(second.dictionariesImported, 0);
    expect(second.errors, isEmpty);
  });

  test('audiobook package syncs and re-keys to the target device book',
      () async {
    final FakeAssetStore store = FakeAssetStore();
    final FakeSyncBackend backend = FakeSyncBackend(store);
    final Directory tmp = Directory('${work.path}/tmp')..createSync();
    final Directory srcAudioRoot = Directory('${work.path}/src_audio')
      ..createSync();
    final Directory tgtAudioRoot = Directory('${work.path}/tgt_audio')
      ..createSync();

    SyncOrchestrator orch(HibikiDatabase db, Directory audioRoot) =>
        SyncOrchestrator(
          db: db,
          backend: backend,
          dictionaryResourceRoot: tmp,
          audioDatabaseRoot: audioRoot,
          tempDir: tmp,
          syncStats: false,
          syncAudioBookPosition: false,
          syncContent: false,
          syncAudioBookFiles: true,
          syncDictionary: false,
          syncLocalAudio: false,
        );

    // ── Source device: book id 1 + its audiobook/srt/cues/files ──
    final HibikiDatabase srcDb = _memDb();
    addTearDown(srcDb.close);
    final int srcId = await srcDb.insertEpubBook(EpubBooksCompanion.insert(
      title: 'MyBook',
      epubPath: '/fake/mybook.epub',
      extractDir: '/fake/extract',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
    ));
    final String srcUid = buildLegacyBookUid(srcId);
    final File track = File('${srcAudioRoot.path}/track.mp3')
      ..writeAsStringSync('audio');
    final File align = File('${srcAudioRoot.path}/align.srt')
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
    await srcDb.upsertAudiobook(AudiobooksCompanion.insert(
      bookUid: srcUid,
      audioRoot: Value(srcAudioRoot.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      alignmentFormat: 'srt',
      alignmentPath: align.path,
    ));
    await srcDb.upsertSrtBook(SrtBooksCompanion.insert(
      uid: 'srt-$srcId',
      title: 'MyBook',
      audioRoot: Value(srcAudioRoot.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      srtPath: align.path,
      importedAt: 1,
      ttuBookId: Value(srcId),
    ));
    await srcDb.replaceCuesForBook(srcUid, <AudioCuesCompanion>[
      AudioCuesCompanion.insert(
        bookUid: srcUid,
        chapterHref: 'c.xhtml',
        sentenceIndex: 0,
        textFragmentId: 'f0',
        cueText: 'hi',
        startMs: 0,
        endMs: 1000,
        audioFileIndex: 0,
      ),
    ]);

    final SyncRunReport push = SyncRunReport();
    await orch(srcDb, srcAudioRoot).syncAudiobookPackages('root', push);
    expect(push.errors, isEmpty, reason: push.errors.join(' | '));
    expect(push.audiobooksExported, 1);

    // ── Target device: SAME title but a DIFFERENT book id (seed a throwaway
    // first so the real book gets id 2) and NO audiobook ──
    final HibikiDatabase tgtDb = _memDb();
    addTearDown(tgtDb.close);
    await tgtDb.insertEpubBook(EpubBooksCompanion.insert(
      title: 'Throwaway',
      epubPath: '/fake/t.epub',
      extractDir: '/fake/te',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
    ));
    final int tgtId = await tgtDb.insertEpubBook(EpubBooksCompanion.insert(
      title: 'MyBook',
      epubPath: '/fake/mybook.epub',
      extractDir: '/fake/extract2',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 2,
    ));
    expect(tgtId, isNot(srcId)); // proves re-keying is actually exercised

    final SyncRunReport pull = SyncRunReport();
    await orch(tgtDb, tgtAudioRoot).syncAudiobookPackages('root', pull);
    expect(pull.errors, isEmpty, reason: pull.errors.join(' | '));
    expect(pull.audiobooksImported, 1);

    // The synced audiobook must resolve via the TARGET device's own bookUid.
    final String tgtUid = buildLegacyBookUid(tgtId);
    expect(await tgtDb.getAudiobookByBookUid(tgtUid), isNotNull);
    expect(await tgtDb.getSrtBookByTtuBookId(tgtId), isNotNull);
    expect(await tgtDb.getCuesForBook(tgtUid), isNotEmpty);
    // Source's bookUid must NOT leak as the key on the target.
    expect(await tgtDb.getAudiobookByBookUid(srcUid), isNull);
  });

  group('local audio phase', () {
    SyncOrchestrator orch(
      HibikiDatabase db,
      SyncBackend backend,
      Directory tmp, {
      required bool syncLocalAudio,
      List<LocalAudioDbEntry> entries = const <LocalAudioDbEntry>[],
      Future<void> Function(LocalAudioPackageContents)? onImported,
    }) =>
        SyncOrchestrator(
          db: db,
          backend: backend,
          dictionaryResourceRoot: tmp,
          audioDatabaseRoot: tmp,
          tempDir: tmp,
          syncStats: false,
          syncAudioBookPosition: false,
          syncContent: false,
          syncAudioBookFiles: false,
          syncDictionary: false,
          syncLocalAudio: syncLocalAudio,
          localAudioEntries: entries,
          onLocalAudioImported: onImported,
        );

    LocalAudioDbEntry seedDb(Directory dir, String name) {
      final File db = File('${dir.path}/local_audio_${name.hashCode}.db')
        ..createSync(recursive: true)
        ..writeAsStringSync('sqlite-bytes-$name');
      return LocalAudioDbEntry(
        path: db.path,
        displayName: name,
        enabled: true,
        sources: const <LocalAudioSourcePref>[
          LocalAudioSourcePref(name: 'nhk16', enabled: true),
        ],
      );
    }

    test('local-only entry is pushed to the backend', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      final LocalAudioDbEntry entry = seedDb(tmp, 'NHK Audio');
      final SyncRunReport report = SyncRunReport();
      await orch(db, backend, tmp,
              syncLocalAudio: true, entries: <LocalAudioDbEntry>[entry])
          .syncLocalAudioPackages(report);

      expect(report.localAudioExported, 1);
      expect(report.localAudioImported, 0);
      expect(report.errors, isEmpty, reason: report.errors.join(' | '));
      final String ns =
          await backend.ensureNamespace(kSyncLocalAudioNamespace);
      final List<AssetEntry> children = await backend.listChildren(ns);
      expect(children.where((AssetEntry e) => !e.isFolder).length, 1);
      expect(children.first.name, 'NHK Audio.hibikiaudiolib');
    });

    test('remote-only package is pulled and registered via callback', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();

      // Source pushes one entry into the shared backend.
      final HibikiDatabase srcDb = _memDb();
      addTearDown(srcDb.close);
      final LocalAudioDbEntry srcEntry = seedDb(tmp, 'Forvo');
      final SyncRunReport push = SyncRunReport();
      await orch(srcDb, backend, tmp,
              syncLocalAudio: true, entries: <LocalAudioDbEntry>[srcEntry])
          .syncLocalAudioPackages(push);
      expect(push.localAudioExported, 1);

      // Target has no local entries → pulls + invokes the import callback.
      final HibikiDatabase tgtDb = _memDb();
      addTearDown(tgtDb.close);
      final List<LocalAudioPackageContents> imported =
          <LocalAudioPackageContents>[];
      final SyncRunReport pull = SyncRunReport();
      await orch(
        tgtDb,
        backend,
        tmp,
        syncLocalAudio: true,
        onImported: (LocalAudioPackageContents c) async => imported.add(c),
      ).syncLocalAudioPackages(pull);

      expect(pull.localAudioImported, 1);
      expect(pull.errors, isEmpty, reason: pull.errors.join(' | '));
      expect(imported.length, 1);
      expect(imported.single.displayName, 'Forvo');
      expect(imported.single.enabled, isTrue);
      expect(imported.single.sources.single.name, 'nhk16');
      expect(imported.single.dbFile.existsSync(), isTrue);
    });

    test('entry present on both sides (same displayName) is skipped', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      final LocalAudioDbEntry entry = seedDb(tmp, 'Shared');
      // First run pushes.
      final SyncRunReport first = SyncRunReport();
      await orch(db, backend, tmp,
              syncLocalAudio: true, entries: <LocalAudioDbEntry>[entry])
          .syncLocalAudioPackages(first);
      expect(first.localAudioExported, 1);

      // Second run with the SAME displayName present on both sides: no push,
      // no pull (callback never even needed).
      final SyncRunReport second = SyncRunReport();
      await orch(
        db,
        backend,
        tmp,
        syncLocalAudio: true,
        entries: <LocalAudioDbEntry>[entry],
        onImported: (LocalAudioPackageContents c) async =>
            fail('must not import a same-named entry'),
      ).syncLocalAudioPackages(second);
      expect(second.localAudioExported, 0);
      expect(second.localAudioImported, 0);
      expect(second.errors, isEmpty);
    });

    test('syncLocalAudio:false leaves the namespace untouched in run()',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      final LocalAudioDbEntry entry = seedDb(tmp, 'Disabled');
      final SyncRunReport report = await orch(
        db,
        backend,
        tmp,
        syncLocalAudio: false,
        entries: <LocalAudioDbEntry>[entry],
      ).run();

      expect(report.localAudioExported, 0);
      expect(report.localAudioImported, 0);
      // The phase never ran → the local-audio namespace holds no packages even
      // though a local entry existed that would otherwise have been pushed.
      final List<AssetEntry> children =
          await backend.listChildren(kSyncLocalAudioNamespace);
      expect(children.where((AssetEntry e) => !e.isFolder), isEmpty);
    });
  });
}
