import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// TODO-270 D: overwriting the latest mined card (updateMinedNote) is an
// AnkiConnect-only capability. The base repository — inherited by the AnkiDroid
// backend (B/C2 deferred) — must DEGRADE GRACEFULLY: return a MineResult.error
// (never throw, never silently succeed) so the popup's "overwrite" click cannot
// crash or corrupt state. In practice AnkiDroid never returns a note id, so the
// popup never even enters the editable state that calls this; this guards the
// defensive fallback if it were ever reached.
//
// AnkiConnectRepository overrides updateMinedNote with a real implementation
// (covered by note_id_and_update_test.dart); this test only locks the base
// default reachable through a backend that does not override it.
class _DegradingRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('n/a');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      const MineOutcome.success();

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

void main() {
  test('base updateMinedNote degrades to an error (does not throw or succeed)',
      () async {
    final repo = _DegradingRepo();

    final MineOutcome outcome = await repo.updateMinedNote(
      noteId: 123,
      rawPayloadJson: '{"expression":"勉強"}',
      context: const AnkiMiningContext(sentence: ''),
    );

    expect(outcome.result, MineResult.error,
        reason: 'a backend without overwrite support must report an error, '
            'never silently succeed');
    expect(outcome.errorDetail, isNotNull);
    expect(outcome.noteId, isNull);
  });
}
