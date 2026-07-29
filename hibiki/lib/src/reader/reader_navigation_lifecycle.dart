import 'package:flutter/foundation.dart';

/// Runs a reader rebuild only while its [State] is still mounted.
///
/// The callback owns the actual `setState` call. Keeping the guard and the
/// mutation in one production helper makes late async callbacks behaviorally
/// testable without scanning source text.
void runReaderRebuildIfMounted({
  required bool mounted,
  required VoidCallback rebuild,
}) {
  if (!mounted) return;
  rebuild();
}

/// Runs the synchronous start of a chapter navigation only while every
/// lifecycle precondition still holds.
///
/// The returned generation is produced by [start], after the caller has
/// initialized the real navigation state. A disposed reader therefore cannot
/// increment generations, rebuild, or start a WebView load.
int? runReaderNavigationStartIfActive({
  required bool mounted,
  required bool hasBook,
  required bool hasController,
  required bool validChapter,
  required int Function() start,
}) {
  if (!mounted || !hasBook || !hasController || !validChapter) return null;
  return start();
}

typedef ReaderImageChapterNavigate = Future<({bool loaded, int generation})>
    Function(int chapter);

/// Result of one image-only chapter sequence.
@immutable
class ReaderImageChapterSequenceResult {
  const ReaderImageChapterSequenceResult({
    required this.completed,
    required this.navigationGeneration,
  });

  /// True only when every requested chapter finished under the same current
  /// reader owner and no newer navigation superseded this sequence.
  final bool completed;

  /// Last navigation generation started by this sequence.
  final int navigationGeneration;
}

/// Executes the real image-only chapter await sequence behind injectable I/O
/// seams while keeping all lifecycle checks in production code.
///
/// [isCurrent] combines reader-owner epoch, captured controller identity and
/// navigation generation. Every await boundary rechecks it. [clearActiveIfOwner]
/// intentionally checks only reader ownership: a newer navigation on the same
/// reader should clear this old sequence's active bit, while a newly attached
/// reader must never be touched by the old continuation.
Future<ReaderImageChapterSequenceResult> runReaderImageChapterSequence({
  required List<int> chapters,
  required int initialNavigationGeneration,
  required int Function(int chapter) resolveChapter,
  required bool Function(int navigationGeneration) isCurrent,
  required bool Function() markActive,
  required bool Function() clearActiveIfOwner,
  required bool Function(int navigationGeneration) holdTransition,
  required ReaderImageChapterNavigate navigate,
  required Future<void> Function() reveal,
  required Future<void> Function() pause,
}) async {
  int generation = initialNavigationGeneration;
  if (!isCurrent(generation) || !markActive()) {
    return ReaderImageChapterSequenceResult(
      completed: false,
      navigationGeneration: generation,
    );
  }

  try {
    int lastResolved = -1;
    for (final int chapter in chapters) {
      if (!isCurrent(generation)) {
        return ReaderImageChapterSequenceResult(
          completed: false,
          navigationGeneration: generation,
        );
      }
      final int resolved = resolveChapter(chapter);
      if (resolved == lastResolved) continue;
      lastResolved = resolved;

      if (!holdTransition(generation)) {
        return ReaderImageChapterSequenceResult(
          completed: false,
          navigationGeneration: generation,
        );
      }
      final ({bool loaded, int generation}) navigation =
          await navigate(chapter);
      generation = navigation.generation;
      if (!isCurrent(generation)) {
        return ReaderImageChapterSequenceResult(
          completed: false,
          navigationGeneration: generation,
        );
      }
      if (!navigation.loaded) continue;

      await reveal();
      if (!isCurrent(generation)) {
        return ReaderImageChapterSequenceResult(
          completed: false,
          navigationGeneration: generation,
        );
      }
      await pause();
      if (!isCurrent(generation)) {
        return ReaderImageChapterSequenceResult(
          completed: false,
          navigationGeneration: generation,
        );
      }
    }
    return ReaderImageChapterSequenceResult(
      completed: true,
      navigationGeneration: generation,
    );
  } finally {
    clearActiveIfOwner();
    if (isCurrent(generation)) {
      holdTransition(generation);
    }
  }
}
