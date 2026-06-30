import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/yomitan_api_server.dart';

class _FakeLookup implements HibikiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    if (term == 'わかる') {
      return DictionarySearchResult(
        searchTerm: term,
        entries: [
          DictionaryEntry(
            dictionaryName: 'Jitendex',
            word: '分かる',
            reading: 'わかる',
            meaning: 'to understand',
            extra: jsonEncode({'matched': 'わかる', 'deinflected': 'わかる'}),
            popularity: 0,
          ),
        ],
        bestLength: 3,
      );
    }
    return null;
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio(
          {required String expression, required String reading}) async =>
      null;
}

Future<HttpClientResponse> _post(
  int port,
  String path,
  Object? body, {
  String? apiKey,
  Map<String, String> headers = const <String, String>{},
}) async {
  final client = HttpClient();
  final req = await client.post('127.0.0.1', port, path);
  req.headers.contentType = ContentType.json;
  if (apiKey != null) req.headers.set('X-API-Key', apiKey);
  headers.forEach(req.headers.set);
  if (body != null) req.write(jsonEncode(body));
  return req.close();
}

void main() {
  late YomitanApiServer server;

  tearDown(() async => server.stop());

  test('termEntries returns Yomitan shape', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;

    final resp = await _post(port, '/termEntries', {'term': 'わかる'});
    expect(resp.statusCode, 200);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['index'], 0);
    final de = (body['dictionaryEntries'] as List).first;
    expect((de['headwords'] as List).first['term'], '分かる');
  });

  test('termEntries with array term returns array', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;

    final resp = await _post(port, '/termEntries', {
      'term': ['わかる', 'xxx']
    });
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body, isA<List>());
    expect((body as List).length, 2);
    expect(body[1]['dictionaryEntries'], <dynamic>[]);
  });

  test('serverVersion is constant', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;
    final resp = await _post(port, '/serverVersion', null);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], 1);
  });

  test('GET method rejected with 405', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;
    final client = HttpClient();
    final req = await client.get('127.0.0.1', port, '/termEntries');
    final resp = await req.close();
    expect(resp.statusCode, 405);
  });

  test('api key enforced when set', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        apiKey: 'secret',
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;

    final noKey = await _post(port, '/termEntries', {'term': 'わかる'});
    expect(noKey.statusCode, 401);

    final withKey =
        await _post(port, '/termEntries', {'term': 'わかる'}, apiKey: 'secret');
    expect(withKey.statusCode, 200);
  });

  test('api key accepts compatible token locations', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        apiKey: 'secret',
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;

    final bodyApiKey = await _post(port, '/termEntries', {
      'term': 'わかる',
      'apiKey': 'secret',
    });
    expect(bodyApiKey.statusCode, 200);

    final bodyToken = await _post(port, '/termEntries', {
      'term': 'わかる',
      'token': 'secret',
    });
    expect(bodyToken.statusCode, 200);

    final queryToken = await _post(
      port,
      '/termEntries?token=secret',
      {'term': 'わかる'},
    );
    expect(queryToken.statusCode, 200);

    final bearerToken = await _post(
      port,
      '/termEntries',
      {'term': 'わかる'},
      headers: <String, String>{'Authorization': 'Bearer secret'},
    );
    expect(bearerToken.statusCode, 200);

    final wrongToken = await _post(port, '/termEntries', {
      'term': 'わかる',
      'token': 'wrong',
    });
    expect(wrongToken.statusCode, 401);
  });

  test('yomitanVersion is constant', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;
    final resp = await _post(port, '/yomitanVersion', null);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], '0.0.0.0');
  });

  test('tokenize returns 2D content with readings', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (t) => ['日本語', 'は', '難しい'],
        readingResolver: (w) => w == '日本語' ? 'にほんご' : '');
    await server.start();
    final int port = server.port;
    final resp = await _post(port, '/tokenize', {'text': '日本語は難しい'});
    expect(resp.statusCode, 200);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['id'], 'scan');
    final content = body['content'] as List;
    expect(content.length, 3);
    final firstSeg = content[0] as List; // 二维：每段一个数组
    expect((firstSeg[0] as Map)['text'], '日本語');
    expect((firstSeg[0] as Map)['reading'], 'にほんご');
  });

  test('tokenize with array text returns array of results', () async {
    server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final int port = server.port;
    final resp = await _post(port, '/tokenize', {
      'text': ['あ', 'い']
    });
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body, isA<List>());
    expect((body as List).length, 2);
    expect(body[0]['index'], 0);
    expect(body[1]['index'], 1);
  });
}
