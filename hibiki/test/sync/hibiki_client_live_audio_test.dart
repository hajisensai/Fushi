import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

// ── fake 库服务（local audio + audiobook 完整 round-trip）─────────────────

class _FakeLibraryService implements HibikiLibraryHostService {
  // ── local audio ───────────────────────────────────────────────────────────

  final List<RemoteLocalAudioInfo> localAudioEntries = <RemoteLocalAudioInfo>[
    const RemoteLocalAudioInfo(displayName: 'NHK ラジオ'),
  ];
  final List<String> localAudioDeleted = <String>[];
  final List<String> localAudioImported = <String>[];

  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      localAudioEntries;

  @override
  Future<File> exportLocalAudio(String displayName) async {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_fake_audio');
    final File f = File('${tmp.path}/$displayName.localaudio');
    f.writeAsStringSync('AUDIO:$displayName');
    return f;
  }

  @override
  Future<void> importLocalAudio(File packageFile) async =>
      localAudioImported.add(await packageFile.readAsString());

  @override
  Future<void> deleteLocalAudio(String displayName) async =>
      localAudioDeleted.add(displayName);

  // ── audiobooks ────────────────────────────────────────────────────────────

  final List<RemoteAudiobookInfo> audiobookEntries = <RemoteAudiobookInfo>[
    const RemoteAudiobookInfo(bookKey: '吾輩は猫であるAudio', title: '吾輩は猫である'),
  ];
  final List<String> audiobookDeleted = <String>[];
  final List<String> audiobookImported = <String>[];

  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async => audiobookEntries;

  @override
  Future<File> exportAudiobook(String bookKey) async {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_fake_ab');
    final File f = File('${tmp.path}/$bookKey.audiobook');
    f.writeAsStringSync('AUDIOBOOK:$bookKey');
    return f;
  }

  @override
  Future<bool> audiobookExists(String bookKey) async =>
      audiobookEntries.any((RemoteAudiobookInfo ab) => ab.bookKey == bookKey);

  @override
  Future<void> importAudiobook(File packageFile,
          {String? bookKeyOverride}) async =>
      audiobookImported.add(await packageFile.readAsString());

  @override
  Future<void> deleteAudiobook(String bookKey) async =>
      audiobookDeleted.add(bookKey);

  // ── dictionaries stubs ────────────────────────────────────────────────────

  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async =>
      throw UnimplementedError('dict export not needed in this test');

  @override
  Future<void> importDictionary(File packageFile) async {}

  @override
  Future<void> deleteDictionary(String name) async {}

  // ── books stubs ───────────────────────────────────────────────────────────

  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw UnimplementedError('books export not needed in this test');

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

  final Map<String, RemoteBookProgress> bookProgress =
      <String, RemoteBookProgress>{};

  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async =>
      bookProgress[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    final RemoteBookProgress current =
        bookProgress[bookKey] ?? RemoteBookProgress.empty;
    bookProgress[bookKey] =
        resolveBookProgressSync(local: current, remote: progress);
  }

  // ── 有声书断点（真实记录，BUG-471）──────────────────────────────────────────────
  final Map<String, ({int positionMs, int updatedAtMs})> audiobookPositions =
      <String, ({int positionMs, int updatedAtMs})>{};

  @override
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  ) async =>
      audiobookPositions[bookKey] ?? (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {
    audiobookPositions[bookKey] = (
      positionMs: positionMs < 0 ? 0 : positionMs,
      updatedAtMs: updatedAtMs,
    );
  }

  // ── video stubs (P4-1) ────────────────────────────────────────────────────
  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[];

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja', int episodeIndex = 0}) async =>
      null;

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

// ── helper: 建 SyncRepository + 配置 backend ──────────────────────────────

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 把 url + token 写库，restoreAuth + authenticate，返回配好的 backend。
Future<HibikiClientSyncBackend> _buildBackend({
  required String base,
  required String token,
}) async {
  final HibikiDatabase db = _testDb();
  final SyncRepository repo = SyncRepository(db);

  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);

  // fake probe：直接返回 true，不做真实探测（server 已在运行）。
  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String url, String tok) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

// ════════════════════════════════════════════════════════════════════════════
// Local audio round-trip tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  late String base;
  const String token = 'live-audio-token';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir:
          Directory.systemTemp.createTempSync('hbk_live_audio_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  // ── listRemoteLocalAudio ──────────────────────────────────────────────────

  test('listRemoteLocalAudio returns entry from host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final List<RemoteLocalAudioInfo> result =
        await backend.listRemoteLocalAudio();

    expect(
      result.map((RemoteLocalAudioInfo a) => a.displayName),
      contains('NHK ラジオ'),
    );
  });

  // ── getRemoteLocalAudio ───────────────────────────────────────────────────

  test('getRemoteLocalAudio downloads audio bytes to destination file',
      () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_audio_dl');
    final File dest = File('${tmp.path}/nhk.localaudio');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.getRemoteLocalAudio('NHK ラジオ', dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'AUDIO:NHK ラジオ');
  });

  // ── putRemoteLocalAudio ───────────────────────────────────────────────────

  test('putRemoteLocalAudio uploads CJK-named audio to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_audio_ul');
    final File src = File('${tmp.path}/日本語音源.localaudio');
    src.writeAsStringSync('AUDIO:日本語音源');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.putRemoteLocalAudio('日本語音源', src);

    expect(lib.localAudioImported, contains('AUDIO:日本語音源'));
  });

  // ── deleteRemoteLocalAudio ────────────────────────────────────────────────

  test('deleteRemoteLocalAudio sends DELETE to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.deleteRemoteLocalAudio('NHK ラジオ');

    expect(lib.localAudioDeleted, contains('NHK ラジオ'));
  });

  // ── auth guard (local audio) ──────────────────────────────────────────────

  test('listRemoteLocalAudio with wrong token throws SyncAuthError', () async {
    final HibikiDatabase db = _testDb();
    final SyncRepository repo = SyncRepository(db);
    await repo.setHibikiClientUrls(<HibikiClientUrl>[
      HibikiClientUrl(url: base, enabled: true),
    ]);
    await repo.setHibikiClientToken('wrong-token');

    final HibikiClientSyncBackend backend =
        HibikiClientSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);
    await expectLater(
      backend.listRemoteLocalAudio(),
      throwsA(isA<SyncAuthError>()),
    );
  });

  // ── progress callback (local audio) ──────────────────────────────────────

  test('getRemoteLocalAudio reports progress callback', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_audio_prog');
    final File dest = File('${tmp.path}/nhk_prog.localaudio');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final List<double> progressValues = <double>[];
    await backend.getRemoteLocalAudio(
      'NHK ラジオ',
      dest,
      onProgress: progressValues.add,
    );

    expect(dest.readAsStringSync(), 'AUDIO:NHK ラジオ');
  });

  // ════════════════════════════════════════════════════════════════════════════
  // Audiobook round-trip tests
  // ════════════════════════════════════════════════════════════════════════════

  // ── listRemoteAudiobooks ──────────────────────────────────────────────────

  test('listRemoteAudiobooks returns entry from host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final List<RemoteAudiobookInfo> result =
        await backend.listRemoteAudiobooks();

    expect(
      result.map((RemoteAudiobookInfo ab) => ab.bookKey),
      contains('吾輩は猫であるAudio'),
    );
    expect(result.first.title, '吾輩は猫である');
  });

  // ── getRemoteAudiobook ────────────────────────────────────────────────────

  test('getRemoteAudiobook downloads audiobook bytes to destination file',
      () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_ab_dl');
    final File dest = File('${tmp.path}/neko_audio.audiobook');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.getRemoteAudiobook('吾輩は猫であるAudio', dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'AUDIOBOOK:吾輩は猫であるAudio');
  });

  // ── putRemoteAudiobook ────────────────────────────────────────────────────

  test('putRemoteAudiobook uploads CJK-named audiobook to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_ab_ul');
    final File src = File('${tmp.path}/新着有声書.audiobook');
    src.writeAsStringSync('AUDIOBOOK:新着有声書');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.putRemoteAudiobook('新着有声書', src);

    expect(lib.audiobookImported, contains('AUDIOBOOK:新着有声書'));
  });

  // ── deleteRemoteAudiobook ─────────────────────────────────────────────────

  test('deleteRemoteAudiobook sends DELETE to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.deleteRemoteAudiobook('吾輩は猫であるAudio');

    expect(lib.audiobookDeleted, contains('吾輩は猫であるAudio'));
  });

  // ── auth guard (audiobooks) ───────────────────────────────────────────────

  test('listRemoteAudiobooks with wrong token throws SyncAuthError', () async {
    final HibikiDatabase db = _testDb();
    final SyncRepository repo = SyncRepository(db);
    await repo.setHibikiClientUrls(<HibikiClientUrl>[
      HibikiClientUrl(url: base, enabled: true),
    ]);
    await repo.setHibikiClientToken('wrong-token');

    final HibikiClientSyncBackend backend =
        HibikiClientSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);
    await expectLater(
      backend.listRemoteAudiobooks(),
      throwsA(isA<SyncAuthError>()),
    );
  });

  // ── progress callback (audiobooks) ───────────────────────────────────────

  test('getRemoteAudiobook reports progress callback', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_ab_prog');
    final File dest = File('${tmp.path}/neko_prog.audiobook');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final List<double> progressValues = <double>[];
    await backend.getRemoteAudiobook(
      '吾輩は猫であるAudio',
      dest,
      onProgress: progressValues.add,
    );

    expect(dest.readAsStringSync(), 'AUDIOBOOK:吾輩は猫であるAudio');
  });

  // ── audiobook position round-trip (BUG-471) ──────────────────────────────

  test('putRemoteAudiobookPosition then remoteAudiobookPosition round-trips',
      () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.putRemoteAudiobookPosition('吾輩は猫であるAudio', 88000, 4242);
    expect(lib.audiobookPositions['吾輩は猫であるAudio']?.positionMs, 88000);

    final ({int positionMs, int updatedAtMs}) got =
        await backend.remoteAudiobookPosition('吾輩は猫であるAudio');
    expect(got.positionMs, 88000);
    expect(got.updatedAtMs, 4242);
  });

  test('remoteAudiobookPosition returns (0,0) when host has no record',
      () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final ({int positionMs, int updatedAtMs}) got =
        await backend.remoteAudiobookPosition('吾輩は猫であるAudio');
    expect(got.positionMs, 0);
    expect(got.updatedAtMs, 0);
  });
}
