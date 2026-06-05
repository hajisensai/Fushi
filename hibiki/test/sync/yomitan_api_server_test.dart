import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
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

Future<HttpClientResponse> _post(int port, String path, Object? body,
    {String? apiKey}) async {
  final client = HttpClient();
  final req = await client.post('127.0.0.1', port, path);
  req.headers.contentType = ContentType.json;
  if (apiKey != null) req.headers.set('X-API-Key', apiKey);
  if (body != null) req.write(jsonEncode(body));
  return req.close();
}

void main() {
  late YomitanApiServer server;

  tearDown(() async => server.stop());

  test('termEntries returns Yomitan shape', () async {
    const int port = 19733;
    server = YomitanApiServer(
        port: port,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();

    final resp = await _post(port, '/termEntries', {'term': 'わかる'});
    expect(resp.statusCode, 200);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['index'], 0);
    final de = (body['dictionaryEntries'] as List).first;
    expect((de['headwords'] as List).first['term'], '分かる');
  });

  test('termEntries with array term returns array', () async {
    const int port = 19734;
    server = YomitanApiServer(
        port: port,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();

    final resp = await _post(port, '/termEntries', {
      'term': ['わかる', 'xxx']
    });
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body, isA<List>());
    expect((body as List).length, 2);
    expect(body[1]['dictionaryEntries'], <dynamic>[]);
  });

  test('serverVersion is constant', () async {
    const int port = 19735;
    server = YomitanApiServer(
        port: port,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final resp = await _post(port, '/serverVersion', null);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], 1);
  });

  test('GET method rejected with 405', () async {
    const int port = 19736;
    server = YomitanApiServer(
        port: port,
        lookupService: _FakeLookup(),
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();
    final client = HttpClient();
    final req = await client.get('127.0.0.1', port, '/termEntries');
    final resp = await req.close();
    expect(resp.statusCode, 405);
  });

  test('api key enforced when set', () async {
    const int port = 19737;
    server = YomitanApiServer(
        port: port,
        lookupService: _FakeLookup(),
        apiKey: 'secret',
        tokenizer: (t) => [t],
        readingResolver: (w) => '');
    await server.start();

    final noKey = await _post(port, '/termEntries', {'term': 'わかる'});
    expect(noKey.statusCode, 401);

    final withKey =
        await _post(port, '/termEntries', {'term': 'わかる'}, apiKey: 'secret');
    expect(withKey.statusCode, 200);
  });
}
