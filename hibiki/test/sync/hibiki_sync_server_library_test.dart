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
    final File f = File(
        '${Directory.systemTemp.createTempSync().path}/$name.hibikidict');
    f.writeAsStringSync('PKG:$name');
    return f;
  }

  @override
  Future<void> importDictionary(File packageFile) async =>
      imported.add(await packageFile.readAsString());

  @override
  Future<void> deleteDictionary(String name) async => deleted.add(name);
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
    final Map<String, dynamic> json = jsonDecode(
        await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
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

  test('library endpoints 404 when no service injected', () async {
    final HibikiSyncServer bare = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync().path,
      port: 0,
      token: token,
      allowLan: false,
    );
    await bare.start();
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(Uri.parse(
        'http://127.0.0.1:${bare.port}/api/library/dictionaries'));
    req.headers.set('authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    c.close();
    await bare.stop();
  });
}
