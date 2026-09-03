import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/models/local_audio_source_pref.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

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
    SyncCoverDataProvider? readCoverData,
  }) =>
      _store.ensureFolder(rootFolderId, bookTitle);

  // ── Unreached members ─────────────────────────────────────────────
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
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
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
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
  Future<SyncFileRef?> findContentFile(
          String folderId, String fileName) async =>
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
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  void evictFolderId(String folderId) {}
}

SyncOrchestrator _orchestrator(
  FushiDatabase db,
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
    final FushiDatabase srcDb = _memDb();
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
        .syncDictionaries(pushReport, direction: SyncAssetDirection.both);
    expect(pushReport.dictionariesExported, 1);
    expect(pushReport.errors, isEmpty);

    // ── Target device: empty DB + empty resource root ──
    final FushiDatabase tgtDb = _memDb();
    addTearDown(tgtDb.close);
    final Directory tgtDictRoot = Directory('${work.path}/tgt_dicts')
      ..createSync();

    final SyncRunReport pullReport = SyncRunReport();
    await _orchestrator(tgtDb, backend, tgtDictRoot, tmp, tmp)
        .syncDictionaries(pullReport, direction: SyncAssetDirection.both);

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

  test('syncDictionaries emits per-item progress with file fraction', () async {
    final FakeAssetStore store = FakeAssetStore();
    final FakeSyncBackend backend = FakeSyncBackend(store);
    final Directory tmp = Directory('${work.path}/tmp')..createSync();

    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
      name: 'progdict',
      formatKey: 'yomitan',
      order: 0,
      type: const Value('term'),
      metadataJson: const Value('{}'),
      hiddenLanguagesJson: const Value('[]'),
      collapsedLanguagesJson: const Value('[]'),
    ));
    final Directory dictRoot = Directory('${work.path}/dicts')..createSync();
    Directory('${dictRoot.path}/progdict').createSync(recursive: true);
    File('${dictRoot.path}/progdict/index.json').writeAsStringSync('{}');

    final List<SyncProgress> events = <SyncProgress>[];
    final orchestrator = SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: dictRoot,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncDictionary: true,
      onProgress: events.add,
    );
    await orchestrator.syncDictionaries(SyncRunReport(),
        direction: SyncAssetDirection.both);

    // One push: a start tick (no fraction) then the putAsset fraction tick.
    final dictEvents =
        events.where((e) => e.phase == SyncPhase.dictionaries).toList();
    expect(dictEvents, isNotEmpty);
    expect(dictEvents.every((e) => e.itemTotal == 1), isTrue);
    expect(dictEvents.first.title, 'progdict');
    expect(dictEvents.any((e) => e.fileFraction == 1.0), isTrue,
        reason: 'putAsset onProgress(1.0) must blend into the bar');
    // Fraction at the file tick = (0 + 1) / 1 = 1.0.
    expect(dictEvents.last.fraction, 1.0);
  });

  test('dictionary already present on both sides is not re-imported', () async {
    final FakeAssetStore store = FakeAssetStore();
    final FakeSyncBackend backend = FakeSyncBackend(store);
    final Directory tmp = Directory('${work.path}/tmp')..createSync();

    final FushiDatabase db = _memDb();
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
        .syncDictionaries(first, direction: SyncAssetDirection.both);
    expect(first.dictionariesExported, 1);

    final SyncRunReport second = SyncRunReport();
    await _orchestrator(db, backend, dictRoot, tmp, tmp)
        .syncDictionaries(second, direction: SyncAssetDirection.both);
    expect(second.dictionariesExported, 0);
    expect(second.dictionariesImported, 0);
    expect(second.errors, isEmpty);
  });

  test('audiobook package uploads without pulling remote-only package',
      () async {
    final FakeAssetStore store = FakeAssetStore();
    final FakeSyncBackend backend = FakeSyncBackend(store);
    final Directory tmp = Directory('${work.path}/tmp')..createSync();
    final Directory srcAudioRoot = Directory('${work.path}/src_audio')
      ..createSync();
    final Directory tgtAudioRoot = Directory('${work.path}/tgt_audio')
      ..createSync();

    SyncOrchestrator orch(FushiDatabase db, Directory audioRoot) =>
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

    // ── Source device: book keyed by title + its audiobook/srt/cues/files ──
    final FushiDatabase srcDb = _memDb();
    addTearDown(srcDb.close);
    final String srcKey = await srcDb.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'MyBook',
      title: 'MyBook',
      epubPath: '/fake/mybook.epub',
      extractDir: '/fake/extract',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
    ));
    final File track = File('${srcAudioRoot.path}/track.mp3')
      ..writeAsStringSync('audio');
    final File align = File('${srcAudioRoot.path}/align.srt')
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
    await srcDb.upsertAudiobook(AudiobooksCompanion.insert(
      bookKey: srcKey,
      audioRoot: Value(srcAudioRoot.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      alignmentFormat: 'srt',
      alignmentPath: align.path,
    ));
    await srcDb.upsertSrtBook(SrtBooksCompanion.insert(
      uid: 'srt-$srcKey',
      title: 'MyBook',
      audioRoot: Value(srcAudioRoot.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      srtPath: align.path,
      importedAt: 1,
      bookKey: Value(srcKey),
    ));
    await srcDb.replaceCuesForBook(srcKey, <AudioCuesCompanion>[
      AudioCuesCompanion.insert(
        bookKey: srcKey,
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

    // ── Target device: SAME title → SAME bookKey (stable identity across
    // devices), NO audiobook yet ──
    final FushiDatabase tgtDb = _memDb();
    addTearDown(tgtDb.close);
    final String tgtKey = await tgtDb.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'MyBook',
      title: 'MyBook',
      epubPath: '/fake/mybook.epub',
      extractDir: '/fake/extract2',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 2,
    ));
    expect(tgtKey, srcKey); // bookKey is stable across devices

    final SyncRunReport second = SyncRunReport();
    await orch(tgtDb, tgtAudioRoot).syncAudiobookPackages('root', second);
    expect(second.errors, isEmpty, reason: second.errors.join(' | '));
    expect(second.audiobooksImported, 0,
        reason: 'Upload audiobook files 不能自动拉取远端独有有声书包');

    // The remote-only package stays remote; explicit manual download is a
    // separate flow.
    expect(tgtKey, srcKey); // bookKey is stable across devices
    expect(await tgtDb.getAudiobookByBookKey(tgtKey), isNull);
    expect(await tgtDb.getSrtBookByBookKey(tgtKey), isNull);
    expect(await tgtDb.getCuesForBook(tgtKey), isEmpty);

    final SyncRunReport targetUpload = SyncRunReport();
    await orch(srcDb, srcAudioRoot).syncAudiobookPackages('root', targetUpload);
    expect(targetUpload.errors, isEmpty,
        reason: targetUpload.errors.join(' | '));
    expect(targetUpload.audiobooksExported, 0, reason: '远端已有包时不重复上传');
  });

  // ── 方向裁剪 ─────────────────────────────────────────────────────────────
  //
  // 开关时代这两半是绑死的：要么双向 union，要么完全不动，用户没法表达「现在只把
  // 本机词典推上去」。方向变成调用点携带的数据之后，这里钉住两件事：选中的那一半
  // 真的做了，**没选中的那一半一件都没做** —— 后者才是回归高发处，因为「在循环里
  // 加个 if」既容易漏裁一边，也容易把进度分母算错。
  group('dictionary transfer direction', () {
    /// 造出「远端只有 remoteonly、本机只有 localonly」的局面，返回本机的 orchestrator。
    Future<SyncOrchestrator> seedBothSides(
      FakeSyncBackend backend,
      Directory tmp,
      FushiDatabase localDb,
      Directory localDictRoot,
      String tag,
    ) async {
      final FushiDatabase srcDb = _memDb();
      addTearDown(srcDb.close);
      await srcDb.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
        name: 'remoteonly',
        formatKey: 'yomitan',
        order: 0,
        type: const Value('term'),
        metadataJson: const Value('{}'),
        hiddenLanguagesJson: const Value('[]'),
        collapsedLanguagesJson: const Value('[]'),
      ));
      final Directory srcRoot = Directory('${work.path}/src_$tag')
        ..createSync();
      Directory('${srcRoot.path}/remoteonly').createSync(recursive: true);
      File('${srcRoot.path}/remoteonly/index.json')
          .writeAsStringSync('{"title":"remoteonly"}');
      await _orchestrator(srcDb, backend, srcRoot, tmp, tmp).syncDictionaries(
        SyncRunReport(),
        direction: SyncAssetDirection.upload,
      );

      await localDb.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
        name: 'localonly',
        formatKey: 'yomitan',
        order: 0,
        type: const Value('term'),
        metadataJson: const Value('{}'),
        hiddenLanguagesJson: const Value('[]'),
        collapsedLanguagesJson: const Value('[]'),
      ));
      Directory('${localDictRoot.path}/localonly').createSync(recursive: true);
      File('${localDictRoot.path}/localonly/index.json')
          .writeAsStringSync('{"title":"localonly"}');
      return _orchestrator(localDb, backend, localDictRoot, tmp, tmp);
    }

    test('upload 只推本端独有，一份远端独有的都不拉', () async {
      final FakeSyncBackend backend = FakeSyncBackend(FakeAssetStore());
      final Directory tmp = Directory('${work.path}/tmp_up')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final Directory dictRoot = Directory('${work.path}/dir_up')..createSync();

      final SyncOrchestrator orch =
          await seedBothSides(backend, tmp, db, dictRoot, 'up');
      final SyncRunReport report = SyncRunReport();
      await orch.syncDictionaries(report, direction: SyncAssetDirection.upload);

      expect(report.dictionariesExported, 1, reason: 'localonly 应被推上去');
      expect(report.dictionariesImported, 0,
          reason: 'upload 绝不能顺手把 remoteonly 拉下来');
      expect(report.errors, isEmpty);
      final List<DictionaryMetaRow> local = await db.getAllDictionaryMetadata();
      expect(local.map((DictionaryMetaRow d) => d.name).toList(),
          <String>['localonly'],
          reason: '本地词典表不该多出 remoteonly');
    });

    test('download 只拉远端独有，一份本端独有的都不推', () async {
      final FakeSyncBackend backend = FakeSyncBackend(FakeAssetStore());
      final Directory tmp = Directory('${work.path}/tmp_down')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final Directory dictRoot = Directory('${work.path}/dir_down')
        ..createSync();

      final SyncOrchestrator orch =
          await seedBothSides(backend, tmp, db, dictRoot, 'down');
      final SyncRunReport report = SyncRunReport();
      await orch.syncDictionaries(report,
          direction: SyncAssetDirection.download);

      expect(report.dictionariesImported, 1, reason: 'remoteonly 应被拉下来');
      expect(report.dictionariesExported, 0,
          reason: 'download 绝不能顺手把 localonly 推上去');
      expect(report.errors, isEmpty);
      final List<AssetEntry> remote =
          await backend.listChildren(kSyncDictionaryNamespace);
      final Iterable<String> names = remote
          .where((AssetEntry e) => !e.isFolder)
          .map((AssetEntry e) => e.name);
      expect(names.any((String n) => n.startsWith('localonly')), isFalse,
          reason: '远端不该多出 localonly');
    });

    test('进度分母只算被选中的那一半', () async {
      final FakeSyncBackend backend = FakeSyncBackend(FakeAssetStore());
      final Directory tmp = Directory('${work.path}/tmp_prog')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final Directory dictRoot = Directory('${work.path}/dir_prog')
        ..createSync();
      await seedBothSides(backend, tmp, db, dictRoot, 'prog');

      // 两侧各一份 → union 是 2；upload 只做 1 件，分母必须是 1。分母撒谎的进度条
      // 比没有进度条更糟：它会停在 50% 然后消失。
      final List<SyncProgress> events = <SyncProgress>[];
      await SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: dictRoot,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncAudioBookFiles: false,
        syncDictionary: true,
        onProgress: events.add,
      ).syncDictionaries(SyncRunReport(), direction: SyncAssetDirection.upload);

      final List<SyncProgress> dictEvents = events
          .where((SyncProgress e) => e.phase == SyncPhase.dictionaries)
          .toList();
      expect(dictEvents, isNotEmpty);
      expect(dictEvents.every((SyncProgress e) => e.itemTotal == 1), isTrue,
          reason: 'upload 的分母是本端独有的数量，不是 union 的大小');
    });

    test('runAssetTransferOnly 按 kind 分派到对应维度，不碰另一类', () async {
      final FakeSyncBackend backend = FakeSyncBackend(FakeAssetStore());
      final Directory tmp = Directory('${work.path}/tmp_kind')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final Directory dictRoot = Directory('${work.path}/dir_kind')
        ..createSync();

      final SyncOrchestrator orch =
          await seedBothSides(backend, tmp, db, dictRoot, 'kind');
      // 选 localAudio：词典两侧都有独有项，但这一轮一件都不该动。
      final SyncRunReport report = await orch.runAssetTransferOnly(
        kind: SyncAssetKind.localAudio,
        direction: SyncAssetDirection.both,
      );

      expect(report.dictionariesExported, 0);
      expect(report.dictionariesImported, 0);
      expect(report.errors, isEmpty);
    });
  });

  group('local audio phase', () {
    SyncOrchestrator orch(
      FushiDatabase db,
      SyncBackend backend,
      Directory tmp, {
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
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      final LocalAudioDbEntry entry = seedDb(tmp, 'NHK Audio');
      final SyncRunReport report = SyncRunReport();
      await orch(db, backend, tmp, entries: <LocalAudioDbEntry>[entry])
          .syncLocalAudioPackages(report, direction: SyncAssetDirection.both);

      expect(report.localAudioExported, 1);
      expect(report.localAudioImported, 0);
      expect(report.errors, isEmpty, reason: report.errors.join(' | '));
      final String ns = await backend.ensureNamespace(kSyncLocalAudioNamespace);
      final List<AssetEntry> children = await backend.listChildren(ns);
      expect(children.where((AssetEntry e) => !e.isFolder).length, 1);
      expect(children.first.name, 'NHK Audio.fushiaudiolib');
    });

    test('remote-only package is pulled and registered via callback', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();

      // Source pushes one entry into the shared backend.
      final FushiDatabase srcDb = _memDb();
      addTearDown(srcDb.close);
      final LocalAudioDbEntry srcEntry = seedDb(tmp, 'Forvo');
      final SyncRunReport push = SyncRunReport();
      await orch(srcDb, backend, tmp, entries: <LocalAudioDbEntry>[srcEntry])
          .syncLocalAudioPackages(push, direction: SyncAssetDirection.both);
      expect(push.localAudioExported, 1);

      // Target has no local entries → pulls + invokes the import callback.
      final FushiDatabase tgtDb = _memDb();
      addTearDown(tgtDb.close);
      final List<LocalAudioPackageContents> imported =
          <LocalAudioPackageContents>[];
      // Capture the staging .db path + its existence *inside* the callback:
      // AppModel.importSyncedLocalAudioDb copies the staged .db while the
      // callback runs (so it must still exist here), and the orchestrator
      // deletes it afterwards (I-1).
      bool dbFileExistedDuringImport = false;
      String? stagingDbPath;
      final SyncRunReport pull = SyncRunReport();
      await orch(
        tgtDb,
        backend,
        tmp,
        onImported: (LocalAudioPackageContents c) async {
          imported.add(c);
          stagingDbPath = c.dbFile.path;
          dbFileExistedDuringImport = c.dbFile.existsSync();
        },
      ).syncLocalAudioPackages(pull, direction: SyncAssetDirection.both);

      expect(pull.localAudioImported, 1);
      expect(pull.errors, isEmpty, reason: pull.errors.join(' | '));
      expect(imported.length, 1);
      expect(imported.single.displayName, 'Forvo');
      expect(imported.single.enabled, isTrue);
      expect(imported.single.sources.single.name, 'nhk16');
      // Staged .db is available while the import callback runs…
      expect(dbFileExistedDuringImport, isTrue);
      // …and is cleaned up afterwards — no staging .db leak (I-1).
      expect(File(stagingDbPath!).existsSync(), isFalse,
          reason: 'staging .db must be deleted after import (I-1)');
    });

    test('entry present on both sides (same displayName) is skipped', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      final LocalAudioDbEntry entry = seedDb(tmp, 'Shared');
      // First run pushes.
      final SyncRunReport first = SyncRunReport();
      await orch(db, backend, tmp, entries: <LocalAudioDbEntry>[entry])
          .syncLocalAudioPackages(first, direction: SyncAssetDirection.both);
      expect(first.localAudioExported, 1);

      // Second run with the SAME displayName present on both sides: no push,
      // no pull (callback never even needed).
      final SyncRunReport second = SyncRunReport();
      await orch(
        db,
        backend,
        tmp,
        entries: <LocalAudioDbEntry>[entry],
        onImported: (LocalAudioPackageContents c) async =>
            fail('must not import a same-named entry'),
      ).syncLocalAudioPackages(second, direction: SyncAssetDirection.both);
      expect(second.localAudioExported, 0);
      expect(second.localAudioImported, 0);
      expect(second.errors, isEmpty);
    });

    // 本地音频源数据库已从 run() 里整段拿掉（它没有开关，只由设置页的显式上传 /
    // 下载动作驱动），所以这条断言从「开关关着时不跑」变成「run() 恒不跑」。
    test('run() never touches the local-audio namespace', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      final LocalAudioDbEntry entry = seedDb(tmp, 'Disabled');
      final SyncRunReport report = await orch(
        db,
        backend,
        tmp,
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

  group('sync cooldown timestamp lifecycle (TODO-1332)', () {
    test(
        'run() records the cooldown timestamp only after a full sweep completes',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      // 整轮 sweep 前：从未同步过 -> 无冷却时间戳。
      expect(await SyncRepository(db).getLastSyncMs(SyncChannelScope.unscoped),
          isNull);

      await _orchestrator(db, backend, tmp, tmp, tmp).run();

      // 整轮完成 -> 记录冷却时间戳（下次 app-open 在冷却窗内不再重复整轮 sweep）。
      expect(await SyncRepository(db).getLastSyncMs(SyncChannelScope.unscoped),
          isNotNull,
          reason: '完整完成的 sweep 必须记录冷却时间戳');
    });

    test(
        'an interrupted sweep leaves the cooldown timestamp unset so the next '
        'app-open retries (discard incomplete, resync next startup)', () async {
      final FakeAssetStore store = FakeAssetStore();
      // 书阶段（无书）之后、词典阶段 ensureNamespace 抛出 -> 模拟整轮 sweep 被中断。
      final _InterruptDuringDictBackend backend =
          _InterruptDuringDictBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      await expectLater(
        _orchestrator(db, backend, tmp, tmp, tmp).run(),
        throwsA(isA<StateError>()),
      );

      // 中断态被丢弃：lastSyncMs 未写 -> 下次 app-open 自动同步重新整轮重试。
      expect(await SyncRepository(db).getLastSyncMs(SyncChannelScope.unscoped),
          isNull,
          reason: '被中断的残缺 sweep 不得记录冷却时间戳，否则会压制下次重试');
    });
  });
}

/// [FakeSyncBackend] 变体（TODO-1332 测试）：在词典阶段 [ensureNamespace] 抛出，
/// 模拟整轮 sweep 在书阶段之后被中断（异常 / app 退出 / 进程被杀）。用于验证
/// 被中断的 sweep 绝不记录同步冷却时间戳，故下次 app-open 会重新整轮重试。
class _InterruptDuringDictBackend extends FakeSyncBackend {
  _InterruptDuringDictBackend(super.store);

  @override
  Future<String> ensureNamespace(String name) async => throw StateError(
      'sweep interrupted during dictionary phase (TODO-1332 test)');
}
