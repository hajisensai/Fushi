import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki_anki/hibiki_anki.dart';

// TODO-752a: connection failures during mining/lookup used to surface as
// garbled toasts. Two root causes: (1) the repository pasted the raw
// toString() of SocketException / TimeoutException / http.ClientException
// straight into the user-facing MineOutcome.errorDetail; (2) package:http
// decodes Response.body as latin1 when the response has no charset header,
// mojibaking a charset-less CJK error page, then leaking it through the
// interpolated exception. Fix: classify by a stable errno/type into a fixed
// AnkiErrorCode (locale-independent, never garbled); the host app localizes by
// code; the OS raw text only goes into MineOutcome.error (diagnostics), never
// into errorDetail. These tests guard both.

/// A latin1-mangled CJK marker: if it ever reaches errorDetail the user sees
/// garble. We assert it never does.
const String kLatin1Garble = 'mojibake-CJK-bytes';

/// Service double whose IPC surface throws a chosen network exception, with no
/// socket. Drives the repository top-level mineEntry catch path.
class _FailingService extends AnkiConnectService {
  _FailingService(this.toThrow);

  final Object toThrow;

  @override
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  }) async =>
      throw toThrow;

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
  }) async =>
      throw toThrow;
}

class _ConfiguredRepo extends AnkiConnectRepository {
  _ConfiguredRepo({required AnkiConnectService service})
      : super(service: service);

  @override
  Future<AnkiSettings> loadSettings() async => _settings();
}

// allowDupes:true => mineEntry skips the dupe query and calls addNote directly,
// so the injected exception surfaces on addNote (the real mining IPC).
AnkiSettings _settings() => const AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(
            id: 2, name: 'Hibiki', fields: <String>['Expression', 'Reading']),
      ],
      fieldMappings: <String, String>{
        'Expression': 'EXPR',
        'Reading': 'READ',
      },
      allowDupes: true,
    );

const String kPayload = '{"expression":"x","reading":"y"}';
const AnkiMiningContext kCtx = AnkiMiningContext(sentence: '');

/// True when [s] is plain ASCII (mojibake bytes fail an ASCII check).
bool isAscii(String s) => s.codeUnits.every((int c) => c < 0x80);

void main() {
  group('classifyAnkiConnectError maps each network failure to a stable code',
      () {
    test('refused (POSIX ECONNREFUSED 111) -> connectionRefused', () {
      const e = SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 111),
      );
      expect(classifyAnkiConnectError(e), AnkiErrorCode.connectionRefused);
    });

    test('refused (Win WSAECONNREFUSED 10061) -> connectionRefused', () {
      const e = SocketException(
        'Connection refused',
        osError: OSError('No connection could be made', 10061),
      );
      expect(classifyAnkiConnectError(e), AnkiErrorCode.connectionRefused);
    });

    test('SocketException with no OSError still classifies (not unknown)', () {
      const e = SocketException('Failed host lookup');
      expect(classifyAnkiConnectError(e), AnkiErrorCode.connectionRefused);
    });

    test('TimeoutException -> connectionTimeout', () {
      final e = TimeoutException('timed out', const Duration(seconds: 10));
      expect(classifyAnkiConnectError(e), AnkiErrorCode.connectionTimeout);
    });

    test('http.ClientException -> httpError', () {
      final e = http.ClientException('Connection closed before full header');
      expect(classifyAnkiConnectError(e), AnkiErrorCode.httpError);
    });

    test('any other exception -> connectionUnknown', () {
      expect(classifyAnkiConnectError(StateError('boom')),
          AnkiErrorCode.connectionUnknown);
    });
  });

  group('ankiConnectErrorHint returns fixed, ASCII-only fallback text', () {
    for (final code in <String>[
      AnkiErrorCode.connectionRefused,
      AnkiErrorCode.connectionTimeout,
      AnkiErrorCode.httpError,
      AnkiErrorCode.connectionUnknown,
    ]) {
      test('hint for ' + code + ' is ASCII and free of garble', () {
        final String hint = ankiConnectErrorHint(code);
        expect(isAscii(hint), isTrue, reason: 'hint must not carry garble');
        expect(hint, isNot(contains(kLatin1Garble)));
      });
    }
  });

  group('mineEntry classifies network errors and keeps raw text out of toast',
      () {
    Future<MineOutcome> mineWith(Object toThrow) {
      final repo = _ConfiguredRepo(service: _FailingService(toThrow));
      return repo.mineEntry(rawPayloadJson: kPayload, context: kCtx);
    }

    test('SocketException refused -> connectionRefused, clean detail',
        () async {
      final outcome = await mineWith(const SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 111),
      ));

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.connectionRefused);
      // The OS exception object reaches the diagnostic log...
      expect(outcome.error, isA<SocketException>());
      // ...but the user-facing detail is a fixed, ASCII fallback that does NOT
      // echo the raw exception toString() (no OSError/errno text). The real
      // user-facing path is the localized errorCode, not this English string.
      expect(outcome.errorDetail, isNotNull);
      expect(outcome.errorDetail, isNot(contains('OSError')));
      expect(outcome.errorDetail, isNot(contains('111')));
      expect(isAscii(outcome.errorDetail!), isTrue);
    });

    test('TimeoutException -> connectionTimeout', () async {
      final outcome =
          await mineWith(TimeoutException('x', const Duration(seconds: 10)));
      expect(outcome.errorCode, AnkiErrorCode.connectionTimeout);
      expect(outcome.error, isA<TimeoutException>());
    });

    test('http.ClientException -> httpError', () async {
      final outcome = await mineWith(http.ClientException('socket hang up'));
      expect(outcome.errorCode, AnkiErrorCode.httpError);
      expect(outcome.error, isA<http.ClientException>());
      expect(outcome.errorDetail, isNot(contains('socket hang up')));
    });

    test('latin1-garbled ClientException text never leaks into errorDetail',
        () async {
      final outcome = await mineWith(
        http.ClientException('proxy error: ' + kLatin1Garble),
      );
      expect(outcome.errorCode, AnkiErrorCode.httpError);
      expect(outcome.error.toString(), contains(kLatin1Garble));
      expect(outcome.errorDetail, isNot(contains(kLatin1Garble)));
      expect(isAscii(outcome.errorDetail!), isTrue);
    });

    test('non-network error keeps errorCode null and a clean ASCII detail',
        () async {
      final outcome = await mineWith(StateError('handlebar boom'));
      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, isNull);
      expect(outcome.error, isA<StateError>());
      expect(outcome.errorDetail, isNot(contains('handlebar boom')));
      expect(isAscii(outcome.errorDetail!), isTrue);
    });
  });

  test('repository never interpolates raw exception into failure detail', () {
    final File repo = File('lib/src/ankiconnect/ankiconnect_repository.dart');
    final String src = repo.readAsStringSync();
    final String e = String.fromCharCode(36) + 'e';
    // Old garble vectors transmitted raw exception text to the user. Forbid the
    // exact historical detail strings; built here so this file has no literal
    // interpolation of its own.
    expect(src.contains("'AnkiConnect: unexpected error: " + e + "'"), isFalse);
    expect(src.contains("'Cannot connect to AnkiConnect: " + e + "'"), isFalse);
    expect(src.contains("'Duplicate check failed: " + e + "'"), isFalse);
  });
}
