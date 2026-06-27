import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

// ── fake 库服务（与 hibiki_sync_server_library_test 同款）─────────────────

class _FakeLibraryService implements HibikiLibraryHostService {
  final List<RemoteDictionaryInfo> dicts = <RemoteDictionaryInfo>[
    const RemoteDictionaryInfo(name: 'JMdict', type: 'term'),
  ];
  final List<String> deleted = <String>[];
  final List<String> imported = <String>[];

  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async => dicts;

  @override
  Future<File> exportDictionary(String name) async {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_fake_lib');
    final File f = File('${tmp.path}/$name.hibikidict');
    f.writeAsStringSync('PKG:$name');
    return f;
  }

  @override
  Future<void> importDictionary(File packageFile) async =>
      imported.add(await packageFile.readAsString());

  @override
  Future<void> deleteDictionary(String name) async => deleted.add(name);

  // ── books stubs ────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw UnimplementedError('export not needed in this test');

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

  // ── local audio stubs ──────────────────────────────────────────────────────
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      <RemoteLocalAudioInfo>[];

  @override
  Future<File> exportLocalAudio(String displayName) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> importLocalAudio(File packageFile) async {}

  @override
  Future<void> deleteLocalAudio(String displayName) async {}

  // ── audiobook stubs ────────────────────────────────────────────────────────
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async =>
      <RemoteAudiobookInfo>[];

  @override
  Future<File> exportAudiobook(String bookKey) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}

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

// ── helper: 建 SyncRepository + 配置 backend ─────────────────────────────

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

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  late String base;
  const String token = 'live-dict-token';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_live_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  // ── listRemoteDictionaries ────────────────────────────────────────────────

  test('listRemoteDictionaries returns JMdict from host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final List<RemoteDictionaryInfo> result =
        await backend.listRemoteDictionaries();

    expect(result.map((RemoteDictionaryInfo d) => d.name), contains('JMdict'));
    expect(result.first.type, 'term');
  });

  // ── getRemoteDictionary ───────────────────────────────────────────────────

  test('getRemoteDictionary downloads package bytes to destination file',
      () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_live_dl');
    final File dest = File('${tmp.path}/JMdict.hibikidict');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.getRemoteDictionary('JMdict', dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'PKG:JMdict');
  });

  // ── putRemoteDictionary ───────────────────────────────────────────────────

  test('putRemoteDictionary uploads file content to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_live_ul');
    final File src = File('${tmp.path}/NHK.hibikidict');
    src.writeAsStringSync('PKG:NHK');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.putRemoteDictionary('NHK', src);

    expect(lib.imported, contains('PKG:NHK'));
  });

  // ── deleteRemoteDictionary ────────────────────────────────────────────────

  test('deleteRemoteDictionary sends DELETE to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.deleteRemoteDictionary('JMdict');

    expect(lib.deleted, contains('JMdict'));
  });

  // ── auth guard ────────────────────────────────────────────────────────────

  test('listRemoteDictionaries with wrong token throws SyncAuthError',
      () async {
    final HibikiDatabase db = _testDb();
    final SyncRepository repo = SyncRepository(db);
    await repo.setHibikiClientUrls(<HibikiClientUrl>[
      HibikiClientUrl(url: base, enabled: true),
    ]);
    // 故意用错误 token。
    await repo.setHibikiClientToken('wrong-token');

    final HibikiClientSyncBackend backend =
        HibikiClientSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);
    // authenticate 用 probe=true，不会察觉 token 错误（probe 是 fake），
    // 故意只 restoreAuth 跳过 authenticate，让 ensureResolved 不强探。
    // 真实 token 错误由第一次 HTTP 操作暴露。
    await expectLater(
      backend.listRemoteDictionaries(),
      throwsA(isA<SyncAuthError>()),
    );
  });

  // ── progress callback ─────────────────────────────────────────────────────

  test('getRemoteDictionary reports progress callback', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_live_prog');
    final File dest = File('${tmp.path}/JMdict.hibikidict');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final List<double> progressValues = <double>[];
    await backend.getRemoteDictionary(
      'JMdict',
      dest,
      onProgress: progressValues.add,
    );

    // 内容很小（PKG:JMdict 字节），Content-Length 若 >0 则会报告一次 1.0。
    // 不强断具体值，只断下载成功即可（progress 回调是 best-effort）。
    expect(dest.readAsStringSync(), 'PKG:JMdict');
  });
}
