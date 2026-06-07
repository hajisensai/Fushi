import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';

class _FakeMining implements HibikiRemoteMiningService {
  Map<String, String>? lastFields;
  String? lastSentence;
  @override
  Future<String> mineEntry(
      {required Map<String, String> fields, required String sentence}) async {
    lastFields = fields;
    lastSentence = sentence;
    return 'success';
  }
}

Future<HttpClientResponse> _post(
    int port, String path, Object body, String token) async {
  final c = HttpClient();
  final r = await c.post('127.0.0.1', port, path);
  r.headers
      .set('authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  return r.close();
}

void main() {
  test('POST /api/mine maps result to JSON', () async {
    final mining = _FakeMining();
    final server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: mining);
    await server.start();
    final resp = await _post(
        server.port,
        '/api/mine',
        {
          'fields': {'expression': '分かる', 'sentence': 'これは分かる'},
          'sentence': 'これは分かる'
        },
        'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(out['result'], 'success');
    expect(mining.lastFields?['expression'], '分かる');
    expect(mining.lastSentence, 'これは分かる');
    await server.stop();
  });

  test('POST /api/mine without auth is 401', () async {
    final server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: _FakeMining());
    await server.start();
    final c = HttpClient();
    final r = await c.post('127.0.0.1', server.port, '/api/mine');
    r.headers.contentType = ContentType.json;
    r.write('{}');
    final resp = await r.close();
    expect(resp.statusCode, 401);
    await server.stop();
  });
}
