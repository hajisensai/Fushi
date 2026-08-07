import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';

// live sync PUT body latin1 regression guard (TODO-1123 / BUG).
// The PUT sites used req.headers.set('Content-Type','application/json') (no
// charset) + req.write(jsonEncode(...)). dart:io HttpClientRequest defaults its
// IOSink encoding to latin1 and only switches to UTF-8 when Content-Type carries
// charset=utf-8. So a body with a Japanese title (code points >255) threw
// "Invalid argument (string): Contains invalid characters." at write time,
// before the request was even sent.
//
// Fix: Content-Type with charset=utf-8 + req.add(utf8.encode(jsonEncode(...)))
// (byte-level write, bypassing the latin1 default encoder). This test starts a
// real FushiSyncServer, drives the client aggregate/progress PUT path with a
// Japanese title, has the server UTF-8-decode the body into the fake library,
// and asserts the Japanese title round-trips intact. The old code throws at
// write time, so this test is red on old code and green after the fix.

/// Fake library service: captures the aggregate snapshot and book progress the
/// client PUTs, so the test can assert the UTF-8 round-trip.
class _CapturingLibraryService implements FushiLibraryHostService {
  // BUG-1004：host 端裁 mining 句子音频（本测试不涉及，返 null 即可）。
  @override
  Future<File?> clipVideoAudio(String id,
          {required int startMs,
          required int endMs,
          int episodeIndex = 0,
          int? audioStreamIndex,
          int? audioStreamCount,
          int audioChannels = 1,
          String audioBitrate = '64k'}) async =>
      null;

  @override
  Future<List<RemoteActivityEvent>> listActivityEvents(
          {int limit = 100}) async =>
      const <RemoteActivityEvent>[];

  @override
  Future<String?> videoCoverPath(String id) async {
    for (final RemoteVideoInfo v in await listVideos()) {
      if (v.id == id) return v.coverPath;
    }
    return null;
  }

  @override
  Future<String?> bookCoverPath(String id) async {
    for (final RemoteBookInfo b in await listBooks()) {
      if (b.downloadId == id || b.title == id) return b.coverPath;
    }
    return null;
  }

  AggregateSnapshot? applied;
  final Map<String, RemoteBookProgress> bookProgress =
      <String, RemoteBookProgress>{};

  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      const AggregateSnapshot();

  @override
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async =>
      applied = snapshot;

  @override
  Future<CollectionManifest> getCollectionManifest() async =>
      CollectionManifest.empty;

  @override
  Future<CollectionManifest> mergeCollectionManifest(
          CollectionManifest incoming) async =>
      incoming;

  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async =>
      bookProgress[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    bookProgress[bookKey] = progress;
  }

  // Unused interface members: throw / no-op.
  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw UnimplementedError('not used');

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async =>
      throw UnimplementedError('not used');

  @override
  Future<void> importDictionary(File packageFile) async {}

  @override
  Future<void> deleteDictionary(String name) async {}

  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      <RemoteLocalAudioInfo>[];

  @override
  Future<File> exportLocalAudio(String displayName) async =>
      throw UnimplementedError('not used');

  @override
  Future<void> importLocalAudio(File packageFile) async {}

  @override
  Future<void> deleteLocalAudio(String displayName) async {}

  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async =>
      <RemoteAudiobookInfo>[];

  @override
  Future<File> exportAudiobook(String bookKey) async =>
      throw UnimplementedError('not used');

  @override
  Future<bool> audiobookExists(String bookKey) async => false;

  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[];

  @override
  Future<bool> videoExists(String id) async => false;

  @override
  Future<void> importVideoSubtitle(File subtitleFile,
      {required String id, required String suffix}) async {}

  @override
  Future<void> importVideo(File videoFile,
      {required String id,
      required String title,
      String? originalFileName}) async {}

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja', int episodeIndex = 0}) async =>
      null;

  @override
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<InterconnectSyncBackend> _buildBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = _testDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final InterconnectSyncBackend backend =
      InterconnectSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  late FushiSyncServer server;
  late _CapturingLibraryService lib;
  late String base;
  const String token = 'utf8-body-token';
  // Japanese title (code points >255) is exactly what latin1 rejects.
  const String japaneseTitle = '謎解きはディナーのあとで';

  setUp(() async {
    lib = _CapturingLibraryService();
    server = FushiSyncServer(
      syncDataDir:
          Directory.systemTemp.createTempSync('hbk_utf8_body_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  test(
      'putRemoteAggregate with Japanese title round-trips UTF-8 (no latin1 crash)',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final AggregateSnapshot snapshot = AggregateSnapshot(
      readingStats: <ReadingStatRecord>[
        ReadingStatRecord(
          title: japaneseTitle,
          dateKey: '2026-07-03',
          charactersRead: 12345,
          readingTimeMs: 600000,
          lastStatisticModified: 1700000000000,
        ),
      ],
    );

    // On the old code, req.write(jsonEncode(...)) throws
    // "Invalid argument (string): Contains invalid characters." here; the
    // request never leaves the client.
    await backend.putRemoteAggregate(snapshot.toJson());

    // Server UTF-8-decodes the body; the Japanese title must survive intact.
    expect(lib.applied, isNotNull);
    expect(lib.applied!.readingStats, hasLength(1));
    expect(lib.applied!.readingStats.first.title, japaneseTitle);
    expect(lib.applied!.readingStats.first.charactersRead, 12345);
  });

  test(
      'putRemoteBookProgress with Japanese bookKey round-trips UTF-8 (no crash)',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.putRemoteBookProgress(
      japaneseTitle,
      const RemoteBookProgress(
        sectionIndex: 7,
        normCharOffset: 7000,
        charOffset: 42,
        updatedAtMs: 1700000001234,
      ),
    );

    expect(lib.bookProgress[japaneseTitle]?.sectionIndex, 7);
    final RemoteBookProgress read =
        await backend.remoteBookProgress(japaneseTitle);
    expect(read.sectionIndex, 7);
    expect(read.normCharOffset, 7000);
    expect(read.updatedAtMs, 1700000001234);
  });
}
