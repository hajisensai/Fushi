import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

const List<int> _coverBytes = <int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4];

/// Fake service：dict 方法存根（不抛，返回空），books 方法真实记录调用。
class _FakeLibraryService implements HibikiLibraryHostService {
  // ── dict stubs ──────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async {
    throw StateError('not used in books test');
  }

  @override
  Future<void> importDictionary(File packageFile) async {}

  @override
  Future<void> deleteDictionary(String name) async {}

  // ── books ────────────────────────────────────────────────────────────────────
  final List<RemoteBookInfo> books = <RemoteBookInfo>[
    const RemoteBookInfo(title: 'Sample', hasContent: true),
  ];
  final List<String> deletedBooks = <String>[];
  final List<String> importedBooks = <String>[];

  @override
  Future<List<RemoteBookInfo>> listBooks() async => books;

  @override
  Future<File> exportBook(String title) async {
    if (!books.any((RemoteBookInfo b) => b.title == title)) {
      throw StateError('book not found: $title');
    }
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_exp');
    final File f = File('${tmp.path}/$title.epub');
    f.writeAsBytesSync(utf8.encode('EPUB:$title'));
    return f;
  }

  @override
  Future<void> importBook(File epubFile) async {
    importedBooks.add(await epubFile.readAsString());
  }

  @override
  Future<void> deleteBook(String title) async => deletedBooks.add(title);

  // ── local audio stubs ──────────────────────────────────────────────────────
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      <RemoteLocalAudioInfo>[];

  @override
  Future<File> exportLocalAudio(String displayName) async =>
      throw UnimplementedError('not used in books test');

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
      throw UnimplementedError('not used in books test');

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

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  const String token = 'test-token';
  late String base;
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_books_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  // ── capabilities ─────────────────────────────────────────────────────────────

  test('GET /api/capabilities reports books == true when service injected',
      () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/capabilities'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    final Map<dynamic, dynamic> live =
        json['liveLibrary'] as Map<dynamic, dynamic>;
    expect(live['books'], true);
    c.close();
  });

  // ── list ─────────────────────────────────────────────────────────────────────

  test('GET /api/library/books lists host books with hasContent', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/books'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final List<dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
    expect(json.length, 1);
    final Map<dynamic, dynamic> first = json.first as Map<dynamic, dynamic>;
    expect(first['title'], 'Sample');
    expect(first['hasContent'], true);
    c.close();
  });

  test('GET /api/library/books exposes and serves book covers', () async {
    final File cover = File(
      '${Directory.systemTemp.createTempSync('hbk_book_cover').path}/cover.png',
    )..writeAsBytesSync(_coverBytes);
    lib.books[0] = RemoteBookInfo.fromJson(<String, Object?>{
      'title': 'Sample',
      'hasContent': true,
      'coverPath': cover.path,
    });
    addTearDown(() => cover.parent.deleteSync(recursive: true));

    final HttpClient c = HttpClient();
    final HttpClientRequest listReq =
        await c.getUrl(Uri.parse('$base/api/library/books'));
    listReq.headers.set('authorization', authHeader());
    final HttpClientResponse listRes = await listReq.close();
    expect(listRes.statusCode, 200);
    final List<dynamic> json =
        jsonDecode(await listRes.transform(utf8.decoder).join())
            as List<dynamic>;
    final Map<dynamic, dynamic> first = json.first as Map<dynamic, dynamic>;
    expect(first['hasCover'], true);
    final Uri coverUri = Uri.parse(first['coverUrl'] as String);

    final HttpClientRequest coverReq = await c.getUrl(coverUri);
    coverReq.headers.set('authorization', authHeader());
    final HttpClientResponse coverRes = await coverReq.close();
    expect(coverRes.statusCode, 200);
    expect(coverRes.headers.contentType?.mimeType, 'image/png');
    final List<int> body = await coverRes.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) {
        acc.addAll(chunk);
        return acc;
      },
    );
    expect(body, _coverBytes);
    c.close();
  });

  // ── GET single ───────────────────────────────────────────────────────────────

  test('GET /api/library/books/<title> streams epub bytes', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/books/Sample'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'application/epub+zip');
    final String body = await res.transform(utf8.decoder).join();
    expect(body, 'EPUB:Sample');
    c.close();
  });

  test('GET /api/library/books/<missing> returns 404', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/books/NoSuchBook'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
  });

  // ── PUT ──────────────────────────────────────────────────────────────────────

  test('PUT /api/library/books/<title> imports body', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.putUrl(Uri.parse('$base/api/library/books/NewBook'));
    req.headers.set('authorization', authHeader());
    req.add(utf8.encode('EPUB:NewBook'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 201, 204));
    expect(lib.importedBooks, contains('EPUB:NewBook'));
    c.close();
  });

  // ── DELETE ───────────────────────────────────────────────────────────────────

  test('DELETE /api/library/books/<title> deletes and returns 204', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.deleteUrl(Uri.parse('$base/api/library/books/Sample'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 204));
    expect(lib.deletedBooks, contains('Sample'));
    c.close();
  });

  // ── auth ─────────────────────────────────────────────────────────────────────

  test('unauthenticated request to /api/library/books returns 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/books'));
    // no Authorization header
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  // ── path traversal ───────────────────────────────────────────────────────────

  test('path-traversal title is rejected with 403', () async {
    final HttpClient c = HttpClient();

    // DELETE with path-traversal → must NOT reach lib.deletedBooks.
    final HttpClientRequest delReq =
        await c.deleteUrl(Uri.parse('$base/api/library/books/%2e%2e%2fevil'));
    delReq.headers.set('authorization', authHeader());
    final HttpClientResponse delRes = await delReq.close();
    expect(delRes.statusCode, 403,
        reason: 'DELETE with "../evil" must be 403 Forbidden');
    await delRes.drain<void>();
    expect(lib.deletedBooks, isEmpty,
        reason: 'no deletion must occur for a traversal title');

    // GET with path-traversal → must also be 403.
    final HttpClientRequest getReq =
        await c.getUrl(Uri.parse('$base/api/library/books/%2e%2e%2fevil'));
    getReq.headers.set('authorization', authHeader());
    final HttpClientResponse getRes = await getReq.close();
    expect(getRes.statusCode, 403,
        reason: 'GET with "../evil" must be 403 Forbidden');
    await getRes.drain<void>();

    c.close();
  });

  // ── no service injected ──────────────────────────────────────────────────────

  test('books endpoints return 404 when no service injected', () async {
    final HibikiSyncServer bare = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_bare').path,
      port: 0,
      token: token,
      allowLan: false,
      // libraryService 为 null
    );
    await bare.start();
    final String bareBase = 'http://127.0.0.1:${bare.port}';
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$bareBase/api/library/books'));
    req.headers.set(
        'authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
    await bare.stop();
  });

  // ── CJK title ────────────────────────────────────────────────────────────────

  test('GET /api/library/books/<CJK-title> 正确解码中文书名', () async {
    lib.books.add(const RemoteBookInfo(title: '三体', hasContent: true));
    final HttpClient c = HttpClient();
    final String encoded = Uri.encodeComponent('三体');
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/books/$encoded'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200, reason: 'GET 三体 应返回 200，双重解码会致 500');
    final String body = await res.transform(utf8.decoder).join();
    expect(body, 'EPUB:三体', reason: 'server 应以正确 CJK 书名（三体）调用 exportBook');
    c.close();
  });

  test('PUT /api/library/books/<CJK-title> 以中文书名导入', () async {
    final HttpClient c = HttpClient();
    final String encoded = Uri.encodeComponent('三体');
    final HttpClientRequest req =
        await c.putUrl(Uri.parse('$base/api/library/books/$encoded'));
    req.headers.set('authorization', authHeader());
    req.add(utf8.encode('EPUB:三体'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 201, 204), reason: 'PUT 三体 应成功（2xx）');
    expect(lib.importedBooks, contains('EPUB:三体'),
        reason: 'importBook 应被以正确内容调用');
    c.close();
  });

  test('DELETE /api/library/books/<CJK-title> 以中文书名删除', () async {
    lib.books.add(const RemoteBookInfo(title: '三体', hasContent: true));
    final HttpClient c = HttpClient();
    final String encoded = Uri.encodeComponent('三体');
    final HttpClientRequest req =
        await c.deleteUrl(Uri.parse('$base/api/library/books/$encoded'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 204), reason: 'DELETE 三体 应成功');
    expect(lib.deletedBooks, contains('三体'),
        reason: 'deleteBook 应以解码后中文名「三体」被调用');
    c.close();
  });
}
