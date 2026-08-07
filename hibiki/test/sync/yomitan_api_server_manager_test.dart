import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/sync/hibiki_remote_lookup_service.dart';
import 'package:fushi/src/sync/yomitan_api_server_manager.dart';

class _FakeLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary(
          {required String term,
          required bool wildcards,
          required int maximumTerms}) async =>
      null;
  @override
  Future<RemoteAudioLookup?> lookupAudio(
          {required String expression, required String reading}) async =>
      null;
}

void main() {
  test('start then stop toggles isRunning and frees port', () async {
    final YomitanApiServerManager mgr = YomitanApiServerManager(
      lookupService: _FakeLookup(),
      tokenizer: (String t) => <String>[t],
      readingResolver: (String w) => '',
    );

    // Bind to an ephemeral port (0) so concurrent CI test isolates never
    // contend on a fixed port (TODO-1014); read the real port back from the
    // manager after start().
    await mgr.start(port: 0, apiKey: '');
    expect(mgr.isRunning, true);
    final int boundPort = mgr.port!;

    final HttpClient client = HttpClient();
    final HttpClientRequest req =
        await client.post('127.0.0.1', boundPort, '/serverVersion');
    final HttpClientResponse resp = await req.close();
    expect(resp.statusCode, 200);
    final dynamic body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], 1);
    client.close(force: true);

    await mgr.stop();
    expect(mgr.isRunning, false);
  });
}
