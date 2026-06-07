import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';

class _StubLookup implements HibikiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary(
      {required String term,
      required bool wildcards,
      required int maximumTerms}) async {
    return DictionarySearchResult(
        searchTerm: term,
        entries: [
          DictionaryEntry(
              dictionaryName: 'D',
              word: term,
              reading: term,
              meaning: 'm',
              extra: '{}',
              popularity: 0)
        ],
        bestLength: term.length);
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio(
          {required String expression, required String reading}) async =>
      null;
}

class _RecordingHistory implements HibikiRemoteHistoryService {
  int historyWrites = 0;
  @override
  void recordHistory(DictionarySearchResult result) {
    historyWrites++;
  }
}

Future<HttpClientResponse> _post(int port, Object body, String token) async {
  final c = HttpClient();
  final r = await c.post('127.0.0.1', port, '/api/lookup/dictionary');
  r.headers
      .set('authorization', 'Basic ${base64Encode(utf8.encode('h:$token'))}');
  r.headers.contentType = ContentType.json;
  r.write(jsonEncode(body));
  return r.close();
}

void main() {
  test('record:true writes history, default does not', () async {
    final history = _RecordingHistory();
    final server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('h').path,
        port: 0,
        token: 't',
        remoteLookupService: _StubLookup(),
        historyService: history);
    await server.start();

    await (await _post(server.port, {'term': '見る'}, 't')).drain();
    expect(history.historyWrites, 0);

    await (await _post(server.port, {'term': '見る', 'record': true}, 't'))
        .drain();
    expect(history.historyWrites, 1);

    await server.stop();
  });
}
