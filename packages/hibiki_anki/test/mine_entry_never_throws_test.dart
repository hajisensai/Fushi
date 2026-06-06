import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// BUG-077: the popup mine button (`assets/popup/popup.js`) disables itself and
// `await`s the `mineEntry` JS handler, which forwards to these repositories. If
// `mineEntry` *throws* instead of returning a `MineResult`, the JS promise
// rejects, the caller's switch (toast + button restore) never runs, and the
// '+' is stuck disabled forever with no feedback — exactly the reported bug.
//
// The fix wraps each implementation so it always resolves to a `MineResult`.
// These tests force an escape on the first unguarded call inside the body
// (`loadSettings`) and assert the contract holds: no throw, `MineResult.error`.

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

  group('mineEntry honors its MineResult contract (never throws)', () {
    test('AnkiConnectRepository maps an unhandled inner error to error',
        () async {
      final AnkiConnectRepository repo = _ThrowingLoadConnectRepo();

      final MineResult result = await repo.mineEntry(
        rawPayloadJson: payload,
        context: context,
      );

      expect(result, MineResult.error);
    });

    test('AnkiConnectRepository.mineEntry future does not reject', () {
      final AnkiConnectRepository repo = _ThrowingLoadConnectRepo();

      expect(
        repo.mineEntry(rawPayloadJson: payload, context: context),
        completion(MineResult.error),
      );
    });

    test('AnkiRepository (AnkiDroid) maps an unhandled inner error to error',
        () async {
      final AnkiRepository repo = _ThrowingLoadDroidRepo();

      final MineResult result = await repo.mineEntry(
        rawPayloadJson: payload,
        context: context,
      );

      expect(result, MineResult.error);
    });

    test('AnkiRepository.mineEntry future does not reject', () {
      final AnkiRepository repo = _ThrowingLoadDroidRepo();

      expect(
        repo.mineEntry(rawPayloadJson: payload, context: context),
        completion(MineResult.error),
      );
    });
  });
}
