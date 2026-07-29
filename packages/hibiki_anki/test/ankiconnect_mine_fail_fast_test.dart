import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki_anki/hibiki_anki.dart';

// BUG-665: when the configured AnkiConnect endpoint accepts a connection but
// never answers (unreachable/black-holed host, VPN down, wrong service on the
// port, a hung add-on), a request used to dangle to the full 10s response
// budget and surface an opaque `TimeoutException: Future not completed`.
// These tests lock both sides of the fail-fast contract: idempotent reads
// surface their bounded timeout, while a timed-out atomic addNote is
// commit-unknown because the server may already have created the note.

/// An HTTP client whose every request never completes — models an AnkiConnect
/// endpoint that connected but never responds. Counts issued requests so a test
/// can assert a timed-out request is not blindly retried.
class _UnresponsiveClient extends http.BaseClient {
  int sent = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent++;
    // Never completes: the service must rely on its own timeout to give up.
    return Completer<http.StreamedResponse>().future;
  }
}

/// Repository with fixed settings so the mine path reaches the AnkiConnect
/// isDuplicate query (allowDupes:false forces the dupe check on a non-empty
/// first field). No media in the context, so isDuplicate is the *first* network
/// call — matching the reported stack (findNotesByField -> isDuplicate).
class _ConfiguredRepo extends AnkiConnectRepository {
  _ConfiguredRepo({required AnkiConnectService service, required this.settings})
      : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _dupeCheckSettings() => const AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(id: 2, name: 'Hibiki', fields: <String>['Expression']),
      ],
      fieldMappings: <String, String>{'Expression': '{expression}'},
      allowDupes: false,
    );

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';

void main() {
  const Duration shortTimeout = Duration(milliseconds: 200);

  test('findNotesByField fails fast (once) when AnkiConnect never responds',
      () async {
    final client = _UnresponsiveClient();
    final service = AnkiConnectService(
      host: '127.0.0.1',
      port: 8765,
      client: client,
      timeout: shortTimeout,
    );

    final stopwatch = Stopwatch()..start();
    await expectLater(
      service.findNotesByField(
        deckName: 'Mining',
        fieldName: 'Expression',
        fieldValue: '勉強',
      ),
      throwsA(isA<TimeoutException>()),
    );
    stopwatch.stop();

    // A timeout is not a connection-drop, so it must not be retried.
    expect(client.sent, 1);
    // Bounded by the (short) request budget — the request did not hang.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test(
      'mineEntry returns commit-unknown (no hang, no retry) when atomic '
      'addNote times out', () async {
    final client = _UnresponsiveClient();
    final service = AnkiConnectService(
      host: '127.0.0.1',
      port: 8765,
      client: client,
      timeout: shortTimeout,
    );
    final repo =
        _ConfiguredRepo(service: service, settings: _dupeCheckSettings());

    final stopwatch = Stopwatch()..start();
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: _payload,
      context: const AnkiMiningContext(sentence: ''),
    );
    stopwatch.stop();

    // The response timeout starts after the request is handed to the HTTP
    // client, so delivery is ambiguous and must not be reported as a proven
    // connection failure or retried.
    expect(outcome.result, MineResult.error);
    expect(outcome.errorCode, isNull);
    expect(outcome.errorDetail, contains('may have created'));
    expect(client.sent, 1);
    // Fail-fast: bounded by the request budget, nowhere near an indefinite hang.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
