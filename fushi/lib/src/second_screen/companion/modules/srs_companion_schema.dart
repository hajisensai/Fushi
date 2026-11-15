/// SRS review module of the companion (`CompanionContextKind.srs`): snapshot
/// keys, phases and command names shared by the review page (main engine,
/// `srs_review_companion.dart`) and `SrsCompanionPanel` (companion engine).
/// Pure Dart.
///
/// Snapshot (published by `SrsReviewPage` while it is the top page; the home
/// shell's review tab is a route-level `srs` context without a snapshot):
/// - [deck] String: the deck title as the top screen shows it.
/// - [phase] String: one of [SrsCompanionPhases].
/// - [newCount] / [learnCount] / [reviewCount] int: remaining counts.
/// - [intervals] `List<String>` (4 entries, ratings 1..4): the answer
///   buttons' next-interval labels exactly as the top screen shows them;
///   empty strings when the page hides / cannot compute them.
/// - [canUndo] bool, [busy] bool (a write is in flight: buttons disabled),
///   [twoButtons] bool (the page hides Hard / Easy).
///
/// Commands (`session.command(action, args)`): see [SrsCompanionActions].
abstract final class SrsCompanionKeys {
  static const String deck = 'deck';
  static const String phase = 'phase';
  static const String newCount = 'newCount';
  static const String learnCount = 'learnCount';
  static const String reviewCount = 'reviewCount';
  static const String intervals = 'intervals';
  static const String canUndo = 'canUndo';
  static const String busy = 'busy';
  static const String twoButtons = 'twoButtons';

  /// Command arg of [SrsCompanionActions.answer]: 1 Again, 2 Hard, 3 Good,
  /// 4 Easy.
  static const String rating = 'rating';
}

/// Where the review page is.
abstract final class SrsCompanionPhases {
  /// The first / next card is still loading.
  static const String loading = 'loading';

  /// Question side shown: "Show answer" is the next step.
  static const String question = 'question';

  /// Answer side shown: rate the card.
  static const String answer = 'answer';

  /// Nothing left for today.
  static const String done = 'done';

  /// The top screen shows something the panel cannot drive (load error,
  /// engine unavailable, RWKV still preparing).
  static const String unavailable = 'unavailable';
}

abstract final class SrsCompanionActions {
  /// Reveal the answer (no args).
  static const String showAnswer = 'showAnswer';

  /// Rate the card: `{rating: 1..4}`.
  static const String answer = 'answer';

  /// Undo the last step (no args).
  static const String undo = 'undo';
}
