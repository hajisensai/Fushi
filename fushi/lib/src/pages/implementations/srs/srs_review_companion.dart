/// The SRS review page's end of the companion (dual-screen handhelds): the
/// module snapshot it publishes and the commands it accepts. Pure functions
/// over the page's state, testable without pumping the page. Schema:
/// [SrsCompanionKeys]. The card itself stays on the top screen.
library;

import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/srs_companion_schema.dart';

/// The page's phase as the panel sees it (same precedence as the page body:
/// loading, error, finished, engine cannot schedule, card).
String srsCompanionPhase({
  required bool loading,
  required bool hasError,
  required bool finished,
  required bool rwkvPending,
  required bool canSchedule,
  required bool hasCard,
  required bool showingAnswer,
}) {
  if (loading) return SrsCompanionPhases.loading;
  if (hasError) return SrsCompanionPhases.unavailable;
  if (finished) {
    return rwkvPending
        ? SrsCompanionPhases.unavailable
        : SrsCompanionPhases.done;
  }
  if (!canSchedule) return SrsCompanionPhases.unavailable;
  if (!hasCard) return SrsCompanionPhases.loading;
  return showingAnswer
      ? SrsCompanionPhases.answer
      : SrsCompanionPhases.question;
}

/// The SRS module snapshot. [intervals] are the four answer buttons'
/// interval labels (ratings 1..4) exactly as the top screen shows them
/// (empty = none shown).
Map<String, Object?> buildSrsCompanionSnapshot({
  required String deck,
  required String phase,
  required int newCount,
  required int learnCount,
  required int reviewCount,
  required List<String> intervals,
  required bool canUndo,
  required bool busy,
  required bool twoButtons,
}) => <String, Object?>{
  SrsCompanionKeys.deck: deck,
  SrsCompanionKeys.phase: phase,
  SrsCompanionKeys.newCount: newCount,
  SrsCompanionKeys.learnCount: learnCount,
  SrsCompanionKeys.reviewCount: reviewCount,
  SrsCompanionKeys.intervals: <String>[
    for (int i = 0; i < 4; i++) i < intervals.length ? intervals[i] : '',
  ],
  SrsCompanionKeys.canUndo: canUndo,
  SrsCompanionKeys.busy: busy,
  SrsCompanionKeys.twoButtons: twoButtons,
};

/// Runs a companion command through the page's own paths (the same ones the
/// buttons, shortcuts and gestures use). Everything is ignored while a write
/// is in flight ([busy]), like the disabled buttons on top. Unknown
/// actions / bad args are ignored.
void handleSrsCompanionCommand(
  String action,
  Map<String, Object?> args, {
  required bool busy,
  required void Function() showAnswer,
  required void Function(int rating) rate,
  required void Function() undo,
}) {
  switch (action) {
    case SrsCompanionActions.showAnswer:
      if (busy) return;
      showAnswer();
    case SrsCompanionActions.answer:
      final int? rating = args.intOrNull(SrsCompanionKeys.rating);
      if (busy || rating == null || rating < 1 || rating > 4) return;
      rate(rating);
    case SrsCompanionActions.undo:
      if (busy) return;
      undo();
  }
}
