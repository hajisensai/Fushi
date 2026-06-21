import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

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
    final File f =
        File('${Directory.systemTemp.createTempSync().path}/$name.hibikidict');
    f.writeAsStringSync('PKG:$name');
    return f;
  }

  @override
  Future<void> importDictionary(File packageFile) async =>
      imported.add(await packageFile.readAsString());

  @override
  Future<void> deleteDictionary(String name) async => deleted.add(name);

  // ── books stubs (not exercised in this test file) ──────────────────────────
  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw StateError('not used in library dict test');

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

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

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  const String token = 'test-token';
  late String base;
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  test('GET /api/capabilities reports liveDictionaries true', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/capabilities'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect((json['liveLibrary'] as Map)['dictionaries'], true);
    c.close();
  });

  test('GET /api/library/dictionaries lists host dictionaries', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/dictionaries'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final List<dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
    expect((json.first as Map)['name'], 'JMdict');
    c.close();
  });

  test('GET /api/library/dictionaries/<name> streams package bytes', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/dictionaries/JMdict'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), 'PKG:JMdict');
    c.close();
  });

  test('PUT /api/library/dictionaries/<name> imports body', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.putUrl(Uri.parse('$base/api/library/dictionaries/NHK'));
    req.headers.set('authorization', authHeader());
    req.add(utf8.encode('PKG:NHK'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 201, 204));
    expect(lib.imported, contains('PKG:NHK'));
    c.close();
  });

  test('DELETE /api/library/dictionaries/<name> deletes', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.deleteUrl(Uri.parse('$base/api/library/dictionaries/JMdict'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 204));
    expect(lib.deleted, contains('JMdict'));
    c.close();
  });

  test('unauthenticated request to /api/library is 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/dictionaries'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    c.close();
  });

  test('path-traversal name is rejected with 403', () async {
    // %2e%2e%2f decodes to "../" on the server; the HttpClient must not
    // normalise the path before sending so we use Uri.parse with the raw
    // percent-encoded string to preserve the dots.
    final HttpClient c = HttpClient();

    // DELETE with path-traversal → must NOT reach lib.deleted.
    final HttpClientRequest delReq = await c
        .deleteUrl(Uri.parse('$base/api/library/dictionaries/%2e%2e%2fevil'));
    delReq.headers.set('authorization', authHeader());
    final HttpClientResponse delRes = await delReq.close();
    expect(delRes.statusCode, 403,
        reason: 'DELETE with "../evil" must be 403 Forbidden');
    await delRes.drain<void>();
    expect(lib.deleted, isEmpty,
        reason: 'no deletion must occur for a traversal name');

    // GET with path-traversal → must also be 403.
    final HttpClientRequest getReq = await c
        .getUrl(Uri.parse('$base/api/library/dictionaries/%2e%2e%2fevil'));
    getReq.headers.set('authorization', authHeader());
    final HttpClientResponse getRes = await getReq.close();
    expect(getRes.statusCode, 403,
        reason: 'GET with "../evil" must be 403 Forbidden');
    await getRes.drain<void>();

    c.close();
  });

  // ── CJK 词典名（修复前应为红，修复后应为绿）────────────────────────────────

  test('GET /api/library/dictionaries/<CJK-name> 正确解码中文名', () async {
    // host 预置「明镜」词典（CJK 名）
    lib.dicts.add(const RemoteDictionaryInfo(name: '明镜', type: 'term'));
    final HttpClient c = HttpClient();
    // client 用 Uri.encodeComponent 编码 CJK 名，与 HibikiClientSyncBackend 一致
    final String encodedName = Uri.encodeComponent('明镜');
    final HttpClientRequest req = await c
        .getUrl(Uri.parse('$base/api/library/dictionaries/$encodedName'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200,
        reason: 'GET 明镜 应返回 200 而非 5xx（双重解码会致 500/502）');
    final String body = await res.transform(utf8.decoder).join();
    expect(body, 'PKG:明镜', reason: 'server 应以正确 CJK 名（明镜）调用 exportDictionary');
    c.close();
  });

  test('PUT /api/library/dictionaries/<CJK-name> 以中文名导入', () async {
    final HttpClient c = HttpClient();
    final String encodedName = Uri.encodeComponent('新明解');
    final HttpClientRequest req = await c
        .putUrl(Uri.parse('$base/api/library/dictionaries/$encodedName'));
    req.headers.set('authorization', authHeader());
    req.add(utf8.encode('PKG:新明解'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 201, 204), reason: 'PUT 新明解 应成功（2xx）');
    // importDictionary 收到的文件内容为 'PKG:新明解'
    expect(lib.imported, contains('PKG:新明解'),
        reason: 'importDictionary 应被以正确内容调用');
    c.close();
  });

  test('DELETE /api/library/dictionaries/<CJK-name> 以中文名删除', () async {
    lib.dicts.add(const RemoteDictionaryInfo(name: '明镜', type: 'term'));
    final HttpClient c = HttpClient();
    final String encodedName = Uri.encodeComponent('明镜');
    final HttpClientRequest req = await c
        .deleteUrl(Uri.parse('$base/api/library/dictionaries/$encodedName'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 204), reason: 'DELETE 明镜 应成功');
    expect(lib.deleted, contains('明镜'),
        reason: 'deleteDictionary 应以解码后中文名「明镜」被调用，而非编码串或乱码');
    c.close();
  });

  test('library endpoints 404 when no service injected', () async {
    final HibikiSyncServer bare = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync().path,
      port: 0,
      token: token,
      allowLan: false,
    );
    await bare.start();
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
        Uri.parse('http://127.0.0.1:${bare.port}/api/library/dictionaries'));
    req.headers.set(
        'authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    c.close();
    await bare.stop();
  });
}
