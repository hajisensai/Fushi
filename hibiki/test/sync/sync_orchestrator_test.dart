import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
