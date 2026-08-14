import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';
import 'package:fushi_anki/fushi_anki.dart';

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

  // 互联 Lapis 客制化端点的捕获（/api/anki/note-type/*）。
  AnkiNoteTypeDefinition? noteTypeDef;
  bool noteTypeWriteOk = true;
  String? lastNoteTypeRead;
  (String, String)? lastStylingWrite;
  (String, List<AnkiCardTemplate>)? lastTemplatesWrite;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
      String modelName) async {
    lastNoteTypeRead = modelName;
    return noteTypeDef;
  }

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async {
    lastStylingWrite = (modelName, css);
    return noteTypeWriteOk;
  }

  @override
  Future<bool> updateNoteTypeTemplates(
      String modelName, List<AnkiCardTemplate> templates) async {
    lastTemplatesWrite = (modelName, templates);
    return noteTypeWriteOk;
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

  // ── 互联 Lapis 客制化端点（手机端经互联读写主机 Anki 的 note type）────────

  test('POST /api/anki/note-type/read returns host definition', () async {
    final mining = _FakeMining()
      ..noteTypeDef = const AnkiNoteTypeDefinition(
        name: 'Lapis',
        fields: <String>['Expression', 'Sentence'],
        templates: <AnkiCardTemplate>[
          AnkiCardTemplate(name: 'Card', front: 'F', back: 'B'),
        ],
        css: '.card {}',
      );
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: mining);
    await server.start();
    final resp = await _post(
        server.port, '/api/anki/note-type/read', {'modelName': 'Lapis'}, 'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(mining.lastNoteTypeRead, 'Lapis');
    expect(out['noteType']['name'], 'Lapis');
    expect(out['noteType']['css'], '.card {}');
    expect(out['noteType']['fields'], ['Expression', 'Sentence']);
    await server.stop();
  });

  test('POST /api/anki/note-type/styling writes through and echoes ok',
      () async {
    final mining = _FakeMining();
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: mining);
    await server.start();
    final resp = await _post(server.port, '/api/anki/note-type/styling',
        {'modelName': 'Lapis', 'css': '.card { color: red; }'}, 'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(out['ok'], true);
    expect(mining.lastStylingWrite, ('Lapis', '.card { color: red; }'));
    await server.stop();
  });

  test('POST /api/anki/note-type/templates writes through', () async {
    final mining = _FakeMining();
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: mining);
    await server.start();
    final resp = await _post(
        server.port,
        '/api/anki/note-type/templates',
        {
          'modelName': 'Lapis',
          'templates': [
            {'name': 'Card', 'front': 'F', 'back': 'B2'},
          ],
        },
        'tok');
    expect(resp.statusCode, 200);
    final out = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(out['ok'], true);
    expect(mining.lastTemplatesWrite?.$1, 'Lapis');
    expect(mining.lastTemplatesWrite?.$2.single.back, 'B2');
    await server.stop();
  });

  test('POST /api/anki/note-type/read with missing modelName is 400', () async {
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: _FakeMining());
    await server.start();
    final resp =
        await _post(server.port, '/api/anki/note-type/read', {}, 'tok');
    expect(resp.statusCode, 400);
    await server.stop();
  });

  test('POST /api/anki/note-type/read without auth is 401', () async {
    final server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk').path,
        port: 0,
        token: 'tok',
        miningService: _FakeMining());
    await server.start();
    final c = HttpClient();
    final r =
        await c.post('127.0.0.1', server.port, '/api/anki/note-type/read');
    r.headers.contentType = ContentType.json;
    r.write('{"modelName":"Lapis"}');
    final resp = await r.close();
    expect(resp.statusCode, 401);
    await server.stop();
  });
}
