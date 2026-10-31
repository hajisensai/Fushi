import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

class _FakeLookup implements FushiRemoteLookupService {
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
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
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
  late FushiApiServer server;

  tearDown(() async => server.stop());

  test('termEntries returns Yomitan shape', () async {
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: _echoTokenize,
    );
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
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: _echoTokenize,
    );
    await server.start();
    final int port = server.port;

    final resp = await _post(port, '/termEntries', {
      'term': ['わかる', 'xxx'],
    });
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body, isA<List>());
    expect((body as List).length, 2);
    expect(body[1]['dictionaryEntries'], <dynamic>[]);
  });

  test('serverVersion is constant', () async {
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: _echoTokenize,
    );
    await server.start();
    final int port = server.port;
    final resp = await _post(port, '/serverVersion', null);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], 1);
  });

  test('GET method rejected with 405', () async {
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: _echoTokenize,
    );
    await server.start();
    final int port = server.port;
    final client = HttpClient();
    final req = await client.get('127.0.0.1', port, '/termEntries');
    final resp = await req.close();
    expect(resp.statusCode, 405);
  });

  test('api key enforced when set', () async {
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      apiKey: 'secret',
      tokenizer: _echoTokenize,
    );
    await server.start();
    final int port = server.port;

    final noKey = await _post(port, '/termEntries', {'term': 'わかる'});
    expect(noKey.statusCode, 401);

    final withKey = await _post(port, '/termEntries', {
      'term': 'わかる',
    }, apiKey: 'secret');
    expect(withKey.statusCode, 200);
  });

  test('api key accepts compatible token locations', () async {
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      apiKey: 'secret',
      tokenizer: _echoTokenize,
    );
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

    final queryToken = await _post(port, '/termEntries?token=secret', {
      'term': 'わかる',
    });
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

  // 改名为 Fushi API 后：新别名 fushiApiKey / fushi_api_key 可用，
  // yomitan-api 时代的旧别名 yomitanApiKey / yomitan_api_key 继续可用。
  test(
    'api key accepts new fushi aliases and legacy yomitan aliases',
    () async {
      server = FushiApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        apiKey: 'secret',
        tokenizer: _echoTokenize,
      );
      await server.start();
      final int port = server.port;

      for (final String name in <String>[
        'fushiApiKey',
        'fushi_api_key',
        'yomitanApiKey',
        'yomitan_api_key',
      ]) {
        final body = await _post(port, '/termEntries', {
          'term': 'わかる',
          name: 'secret',
        });
        expect(body.statusCode, 200, reason: 'body field $name');

        final query = await _post(port, '/termEntries?$name=secret', {
          'term': 'わかる',
        });
        expect(query.statusCode, 200, reason: 'query param $name');

        final wrong = await _post(port, '/termEntries', {
          'term': 'わかる',
          name: 'wrong',
        });
        expect(wrong.statusCode, 401, reason: 'wrong value via $name');
      }
    },
  );

  test('yomitanVersion is constant', () async {
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: _echoTokenize,
    );
    await server.start();
    final int port = server.port;
    final resp = await _post(port, '/yomitanVersion', null);
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], '0.0.0.0');
  });

  test('tokenize returns 2D content with readings', () async {
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: (List<String> texts) async => <List<TokenizedSegment>>[
        for (final String _ in texts)
          <TokenizedSegment>[
            (text: '日本語', reading: 'にほんご'),
            (text: 'は', reading: ''),
            (text: '難しい', reading: ''),
          ],
      ],
    );
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
    // 整批一次交给分词器（后台 isolate 里切完，HBK-AUDIT-009），不逐条调用。
    final List<List<String>> calls = <List<String>>[];
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: (List<String> texts) {
        calls.add(texts);
        return _echoTokenize(texts);
      },
    );
    await server.start();
    final int port = server.port;
    final resp = await _post(port, '/tokenize', {
      'text': ['あ', 'い'],
    });
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body, isA<List>());
    expect((body as List).length, 2);
    expect(body[0]['index'], 0);
    expect(body[1]['index'], 1);
    expect(((body[1]['content'] as List)[0] as List)[0]['text'], 'い');
    expect(calls, <List<String>>[
      <String>['あ', 'い'],
    ]);
  });
}

Future<List<List<TokenizedSegment>>> _echoTokenize(List<String> texts) async =>
    <List<TokenizedSegment>>[
      for (final String t in texts) <TokenizedSegment>[(text: t, reading: '')],
    ];
