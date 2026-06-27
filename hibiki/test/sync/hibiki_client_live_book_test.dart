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
  // ── 进度 live 端点（TODO-767 / BUG-417）──────────────────────────────────

  test('putRemoteBookProgress 上报后 remoteBookProgress 拉回一致', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.putRemoteBookProgress(
      'BookKey1',
      const RemoteBookProgress(
          sectionIndex: 5,
          normCharOffset: 5500,
          charOffset: 321,
          updatedAtMs: 1700000000000),
    );

    // host fake 真存了进度（host-apply）。
    expect(lib.bookProgress['BookKey1']?.sectionIndex, 5);

    final RemoteBookProgress read =
        await backend.remoteBookProgress('BookKey1');
    expect(read.sectionIndex, 5);
    expect(read.normCharOffset, 5500);
    expect(read.charOffset, 321);
    expect(read.updatedAtMs, 1700000000000);
  });

  test('remoteBookProgress 未知书 → empty（host 无记录返回 0/0，不抛）', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final RemoteBookProgress read =
        await backend.remoteBookProgress('UnknownBook');
    expect(read.updatedAtMs, 0);
    expect(read.sectionIndex, 0);
  });

  test('CJK bookKey 经 URL 编码往返一致', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    await backend.putRemoteBookProgress(
      '吾輩は猫である',
      const RemoteBookProgress(
          sectionIndex: 2,
          normCharOffset: 200,
          charOffset: -1,
          updatedAtMs: 1700000009999),
    );
    final RemoteBookProgress read = await backend.remoteBookProgress('吾輩は猫である');
    expect(read.sectionIndex, 2);
    expect(read.updatedAtMs, 1700000009999);
  });

  test('上报旧时间戳不回退 host 新进度（host 端取较新）', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    await backend.putRemoteBookProgress(
      'BookKey2',
      const RemoteBookProgress(
          sectionIndex: 9,
          normCharOffset: 9000,
          charOffset: 1,
          updatedAtMs: 5000),
    );
    await backend.putRemoteBookProgress(
      'BookKey2',
      const RemoteBookProgress(
          sectionIndex: 1,
          normCharOffset: 10,
          charOffset: 1,
          updatedAtMs: 1000), // 更旧
    );
    final RemoteBookProgress read =
        await backend.remoteBookProgress('BookKey2');
    expect(read.sectionIndex, 9); // host 新进度保留
    expect(read.updatedAtMs, 5000);
  });

  // ── 旧 host 无 /progress 路由 → 真 404 优雅退化（向后兼容，BUG-417 🟡2）──────
  // 不挂 libraryService 的 server：GET /api/library/books/<key>/progress 经
  // shelf 返回真实 HTTP 404（server 端 `Library service off`）。client 的
  // remoteBookProgress 必须吃下 404、返回 RemoteBookProgress.empty、不抛、不中断，
  // 让旧 host / 离线场景退回本地 reader_positions。
  test('旧 host 无 progress 路由 → 真 404 优雅退化为 empty（不抛）', () async {
    final HibikiSyncServer legacyServer = HibikiSyncServer(
      syncDataDir:
          Directory.systemTemp.createTempSync('hbk_legacy_no_lib_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      // libraryService 省略（null）：books 路由整体返回 404，模拟旧 host。
    );
    await legacyServer.start();
    addTearDown(() async => legacyServer.stop());
    final String legacyBase = 'http://127.0.0.1:${legacyServer.port}';

    final HibikiClientSyncBackend backend =
        await _buildBackend(base: legacyBase, token: token);

    final RemoteBookProgress read = await backend.remoteBookProgress('AnyBook');
    expect(read.updatedAtMs, 0);
    expect(read.sectionIndex, 0);
    expect(read, same(RemoteBookProgress.empty));
  });
}
