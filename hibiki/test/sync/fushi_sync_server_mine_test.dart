import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';

class _FakeMining implements FushiRemoteMiningService {
  Map<String, String>? lastFields;
  String? lastSentence;
  ImmersionMinePayload? lastImmersion;
  @override
  Future<RemoteMineResult> mineEntry(
      {required Map<String, String> fields, required String sentence}) async {
    lastFields = fields;
    lastSentence = sentence;
    return const RemoteMineResult(result: 'success');
  }

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async {
    lastImmersion = payload;
    return const RemoteMineResult(result: 'success');
  }

  ForwardedMinePayload? lastForwarded;

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async {
    lastForwarded = payload;
    return const RemoteMineResult(result: 'success');
  }

  bool dupResult = false;
  String? lastDupExpression;
  String? lastDupReading;
  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    lastDupExpression = expression;
    lastDupReading = reading;
    return dupResult;
  }
}

Future<HttpClientResponse> _post(
    int port, String path, Object body, String token) async {
  final c = HttpClient();
  final r = await c.post('127.0.0.1', port, path);
  r.headers.set(
      'authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  return r.close();
}

void main() {
  test('POST /api/mine maps result to JSON', () async {
    final mining = _FakeMining();
    final server = FushiSyncServer(
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

  test('POST /api/mine with screenshot routes to mineImmersion', () async {
    final mining = _FakeMining();
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: mining);
    await server.start();
    final resp = await _post(
        server.port,
        '/api/mine',
        {
          'fields': {'expression': '走る'},
          'sentence': '走り出した',
          'timestampMs': 1234,
          'netflixVideoId': '81',
          'screenshotBase64': base64Encode(<int>[1, 2, 3]),
        },
        'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(out['result'], 'success');
    expect(mining.lastImmersion, isNotNull);
    expect(mining.lastImmersion?.netflixVideoId, '81');
    expect(mining.lastImmersion?.timestampMs, 1234);
    expect(mining.lastFields, isNull); // 未走纯文本 mineEntry
    await server.stop();
  });

  test('POST /api/mine without auth is 401', () async {
    final server = FushiSyncServer(
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

  test('POST /api/duplicate returns real duplicate flag (TODO-1176)', () async {
    final mining = _FakeMining()..dupResult = true;
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: mining);
    await server.start();
    final resp = await _post(server.port, '/api/duplicate',
        {'expression': '分かる', 'reading': 'わかる'}, 'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(out['duplicate'], true);
    expect(mining.lastDupExpression, '分かる');
    expect(mining.lastDupReading, 'わかる');
    await server.stop();
  });

  test('POST /api/duplicate with empty expression short-circuits to false',
      () async {
    final mining = _FakeMining()..dupResult = true;
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: mining);
    await server.start();
    final resp =
        await _post(server.port, '/api/duplicate', {'expression': ''}, 'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(out['duplicate'], false);
    expect(mining.lastDupExpression, isNull); // 未触达后端
    await server.stop();
  });

  test('POST /api/duplicate without auth is 401', () async {
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: _FakeMining());
    await server.start();
    final c = HttpClient();
    final r = await c.post('127.0.0.1', server.port, '/api/duplicate');
    r.headers.contentType = ContentType.json;
    r.write('{"expression":"猫"}');
    final resp = await r.close();
    expect(resp.statusCode, 401);
    await server.stop();
  });
}
