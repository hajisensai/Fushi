import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// BUG-077: the popup mine button (`assets/popup/popup.js`) disables itself and
// `await`s the `mineEntry` JS handler, which forwards to these repositories. If
// `mineEntry` *throws* instead of returning a `MineOutcome`, the JS promise
// rejects, the caller's switch (toast + button restore) never runs, and the
// '+' is stuck disabled forever with no feedback — exactly the reported bug.
//
// The fix wraps each implementation so it always resolves to a `MineOutcome`.
// These tests force an escape on the first unguarded call inside the body
// (`loadSettings`) and assert the contract holds: no throw, `MineResult.error`.
//
// BUG-089: a bare `MineResult.error` discarded the real cause — neither the
// toast nor the error log could show *why* mining failed. `MineOutcome` now
// carries `errorDetail` (concise reason → toast) plus `error`/`stackTrace`
// (full diagnostics → ErrorLogService). These tests also assert the cause is
// carried back on the top-level catch path.

class _ThrowingLoadConnectRepo extends AnkiConnectRepository {
  @override
  Future<AnkiSettings> loadSettings() async =>
      throw StateError('loadSettings boom');
}

class _ThrowingLoadDroidRepo extends AnkiRepository {
  @override
  Future<AnkiSettings> loadSettings() async =>
      throw StateError('loadSettings boom');
}

void main() {
  const AnkiMiningContext context = AnkiMiningContext(sentence: '');
  const String payload = '{"expression":"勉強","reading":"べんきょう"}';

  group('mineEntry honors its MineOutcome contract (never throws)', () {
    test('AnkiConnectRepository maps an unhandled inner error to error',
        () async {
      final AnkiConnectRepository repo = _ThrowingLoadConnectRepo();

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: context,
      );

      expect(outcome.result, MineResult.error);
    });

    test('AnkiConnectRepository carries the real cause back to the caller',
        () async {
      final AnkiConnectRepository repo = _ThrowingLoadConnectRepo();

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: context,
      );

      // Concise reason for the toast.
      expect(outcome.errorDetail, isNotNull);
      expect(outcome.errorDetail, isNotEmpty);
      // Full diagnostics for the error log.
      expect(outcome.error, isA<StateError>());
      expect(outcome.stackTrace, isNotNull);
    });

    test('AnkiConnectRepository.mineEntry future does not reject', () {
      final AnkiConnectRepository repo = _ThrowingLoadConnectRepo();

      expect(
        repo
            .mineEntry(rawPayloadJson: payload, context: context)
            .then((o) => o.result),
        completion(MineResult.error),
      );
    });

    test('AnkiRepository (AnkiDroid) maps an unhandled inner error to error',
        () async {
      final AnkiRepository repo = _ThrowingLoadDroidRepo();

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: context,
      );

      expect(outcome.result, MineResult.error);
    });

    test('AnkiRepository (AnkiDroid) carries the real cause back to the caller',
        () async {
      final AnkiRepository repo = _ThrowingLoadDroidRepo();

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: context,
      );

      expect(outcome.errorDetail, isNotNull);
      expect(outcome.errorDetail, isNotEmpty);
      expect(outcome.error, isA<StateError>());
      expect(outcome.stackTrace, isNotNull);
    });

    test('AnkiRepository.mineEntry future does not reject', () {
      final AnkiRepository repo = _ThrowingLoadDroidRepo();

      expect(
        repo
            .mineEntry(rawPayloadJson: payload, context: context)
            .then((o) => o.result),
        completion(MineResult.error),
      );
    });
  });

  group('MineOutcome construction', () {
    test('success/duplicate/notConfigured carry no error detail', () {
      expect(const MineOutcome.success().result, MineResult.success);
      expect(const MineOutcome.success().errorDetail, isNull);
      expect(const MineOutcome.duplicate().result, MineResult.duplicate);
      expect(
          const MineOutcome.notConfigured().result, MineResult.notConfigured);
      expect(const MineOutcome.notConfigured().error, isNull);
    });

    test('failure carries concise detail and optional diagnostics', () {
      final StackTrace stack = StackTrace.current;
      final MineOutcome o = MineOutcome.failure(
        'boom reason',
        error: const FormatException('bad'),
        stackTrace: stack,
      );
      expect(o.result, MineResult.error);
      expect(o.errorDetail, 'boom reason');
      expect(o.error, isA<FormatException>());
      expect(o.stackTrace, stack);
    });
  });
}
