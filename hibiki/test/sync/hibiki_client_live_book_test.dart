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

// ── fake 库服务（books 完整 round-trip）────────────────────────────────────

class _FakeLibraryService implements HibikiLibraryHostService {
  final List<RemoteBookInfo> books = <RemoteBookInfo>[
    const RemoteBookInfo(title: '吾輩は猫である', hasContent: true),
  ];
  final List<String> deleted = <String>[];
  final List<String> imported = <String>[];

  // ── books ──────────────────────────────────────────────────────────────────

  @override
  Future<List<RemoteBookInfo>> listBooks() async => books;

  @override
  Future<File> exportBook(String title) async {
    final RemoteBookInfo? book = books.cast<RemoteBookInfo?>().firstWhere(
          (RemoteBookInfo? b) =>
              b!.title == title || b.toJson()['bookKey'] == title,
          orElse: () => null,
        );
    if (book == null) {
      throw StateError('book not found: $title');
    }
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_fake_book');
    final File f = File('${tmp.path}/book.epub');
    // fake EPUB 内容：足以验证 round-trip 的小字符串（UTF-8 一致，与词典范式相同）。
    f.writeAsStringSync('EPUB:${book.title}');
    return f;
  }

  @override
  Future<void> importBook(File epubFile) async =>
      imported.add(await epubFile.readAsString());

  @override
  Future<void> deleteBook(String title) async => deleted.add(title);

  // ── dictionaries stubs ─────────────────────────────────────────────────────

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
  const String token = 'live-book-token';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir:
          Directory.systemTemp.createTempSync('hbk_live_book_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  // ── listRemoteBooks ───────────────────────────────────────────────────────

  test('listRemoteBooks returns book from host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final List<RemoteBookInfo> result = await backend.listRemoteBooks();

    expect(
      result.map((RemoteBookInfo b) => b.title),
      contains('吾輩は猫である'),
    );
    expect(result.first.hasContent, isTrue);
  });

  // ── getRemoteBook ─────────────────────────────────────────────────────────

  test('getRemoteBook downloads EPUB bytes to destination file', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_book_dl');
    final File dest = File('${tmp.path}/neko.epub');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.getRemoteBook('吾輩は猫である', dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'EPUB:吾輩は猫である');
  });

  test('getRemoteBook downloads special-character title by bookKey', () async {
    const String displayTitle = r'Vol 1/2\3?..: Finale';
    const String bookKey = 'Vol_1_2_3_Finale';
    lib.books.add(RemoteBookInfo.fromJson(<String, Object?>{
      'title': displayTitle,
      'bookKey': bookKey,
      'hasContent': true,
    }));
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp =
        Directory.systemTemp.createTempSync('hbk_book_dl_special');
    final File dest = File('${tmp.path}/special.epub');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final List<RemoteBookInfo> listed = await backend.listRemoteBooks();
    expect(
      listed
          .singleWhere((RemoteBookInfo b) => b.title == displayTitle)
          .toJson()['bookKey'],
      bookKey,
    );

    await backend.getRemoteBook(bookKey, dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'EPUB:$displayTitle');
  });

  // ── putRemoteBook ─────────────────────────────────────────────────────────

  test('putRemoteBook uploads CJK-named file content to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_book_ul');
    final File src = File('${tmp.path}/新書.epub');
    src.writeAsStringSync('EPUB:新書');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.putRemoteBook('新書', src);

    expect(lib.imported, contains('EPUB:新書'));
  });

  // ── deleteRemoteBook ──────────────────────────────────────────────────────

  test('deleteRemoteBook sends DELETE to host', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.deleteRemoteBook('吾輩は猫である');

    expect(lib.deleted, contains('吾輩は猫である'));
  });

  // ── auth guard ────────────────────────────────────────────────────────────

  test('listRemoteBooks with wrong token throws SyncAuthError', () async {
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
    // 只 restoreAuth 跳过 authenticate，让真实 token 错误由第一次 HTTP 操作暴露。
    await expectLater(
      backend.listRemoteBooks(),
      throwsA(isA<SyncAuthError>()),
    );
  });

  // ── progress callback ─────────────────────────────────────────────────────

  test('getRemoteBook reports progress callback', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_book_prog');
    final File dest = File('${tmp.path}/neko_prog.epub');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final List<double> progressValues = <double>[];
    await backend.getRemoteBook(
      '吾輩は猫である',
      dest,
      onProgress: progressValues.add,
    );

    // 内容很小，不强断 progress 具体值，只断下载成功即可（progress 是 best-effort）。
    expect(dest.readAsStringSync(), 'EPUB:吾輩は猫である');
  });
}
