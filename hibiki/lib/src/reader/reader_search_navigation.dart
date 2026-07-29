enum ReaderSearchJumpAction {
  navigate,
  replacePending,
  evaluateNow,
}

/// Decides which DOM owns a book-search result.
///
/// [currentChapter] is the logical navigation target and is updated before the
/// target document has loaded. It is therefore not sufficient on its own to
/// decide that JavaScript can run against the current DOM.
ReaderSearchJumpAction decideReaderSearchJump({
  required int targetChapter,
  required int currentChapter,
  required bool restoreInFlight,
  required bool readerContentReady,
}) {
  if (targetChapter != currentChapter) {
    return ReaderSearchJumpAction.navigate;
  }
  if (restoreInFlight || !readerContentReady) {
    return ReaderSearchJumpAction.replacePending;
  }
  return ReaderSearchJumpAction.evaluateNow;
}

/// Last-write-wins queue for a precise locate bound to a navigation generation.
///
/// Search results can be selected again after the logical current chapter has
/// changed but before the corresponding document is ready. Replacing the
/// request within the active generation ensures the final selection is the one
/// applied after restore settles.
class ReaderPreciseLocateQueue {
  ({int generation, String js})? _pending;

  void replace({
    required int generation,
    required String js,
  }) {
    _pending = (generation: generation, js: js);
  }

  void clear() {
    _pending = null;
  }

  /// Consumes the active generation once.
  ///
  /// A disposed/unavailable reader passes [canApply] as false; the request is
  /// still discarded so it can never leak into a later document.
  String? consume({
    required int generation,
    required bool canApply,
  }) {
    final ({int generation, String js})? pending = _pending;
    _pending = null;
    if (!canApply || pending == null || pending.generation != generation) {
      return null;
    }
    return pending.js;
  }
}
