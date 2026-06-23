import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

class _LiveBookLibraryService implements HibikiLibraryHostService {
  const _LiveBookLibraryService(this.bookTitle);

  final String bookTitle;

  @override
  Future<List<RemoteBookInfo>> listBooks() async =>
      <RemoteBookInfo>[RemoteBookInfo(title: bookTitle, hasContent: true)];

  @override
  Future<File> exportBook(String title) async {
    final Directory tmp =
        Directory.systemTemp.createTempSync('hibiki_compare_live_book');
    final File file = File('${tmp.path}/book.epub');
    final Archive archive = Archive();
    archive
        .addFile(ArchiveFile('mimetype', 20, 'application/epub+zip'.codeUnits));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}

  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async =>
      throw UnimplementedError();

  @override
  Future<void> importDictionary(File packageFile) async {}

  @override
  Future<void> deleteDictionary(String name) async {}

  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      <RemoteLocalAudioInfo>[];

  @override
  Future<File> exportLocalAudio(String displayName) async =>
      throw UnimplementedError();

  @override
  Future<void> importLocalAudio(File packageFile) async {}

  @override
  Future<void> deleteLocalAudio(String displayName) async {}

  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async =>
      <RemoteAudiobookInfo>[];

  @override
  Future<File> exportAudiobook(String bookKey) async =>
      throw UnimplementedError();

  @override
  Future<void> importAudiobook(
    File packageFile, {
    String? bookKeyOverride,
  }) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[];

  @override
  Future<File?> resolveVideoFile(String id) async => null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja'}) async =>
      null;

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs,
  ) async {}
}

Future<HibikiClientSyncBackend> _buildLiveBackend({
  required HibikiDatabase db,
  required String base,
  required String token,
}) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String url, String tok) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  test(
      'Hibiki interconnect compare lists remote-only live book as downloadable',
      () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_compare_live_tmp');
    addTearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: '${tempDir.path}/server',
      port: 0,
      token: 'compare-live-token',
      allowLan: false,
      libraryService: const _LiveBookLibraryService('LiveOnlyBook'),
    );
    await server.start();
    addTearDown(server.stop);

    final HibikiClientSyncBackend backend = await _buildLiveBackend(
      db: db,
      base: 'http://127.0.0.1:${server.port}',
      token: 'compare-live-token',
    );
    addTearDown(backend.clearCache);

    final List<SyncCompareEntry> entries =
        await fetchCompareDataForTest(db, backend);
    final SyncCompareEntry liveEntry =
        entries.singleWhere((SyncCompareEntry e) => e.title == 'LiveOnlyBook');

    expect(liveEntry.bookKey, isNull);
    expect(liveEntry.remoteFolderId, isNull,
        reason: 'live library book does not live in the WebDAV book folder');
    expect(liveEntry.isDownloadableRemoteOnly, isTrue,
        reason: 'Hibiki 互联 compare 必须读取 live /api/library/books');
  });
}
