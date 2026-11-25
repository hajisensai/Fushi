import 'package:fushi_core/fushi_core.dart';

/// Who hears about finished / watched marks set by hand (media tracking in
/// the app). Built by `AppModel.libraryFinishTracking`; tests and callers
/// without tracking pass [none].
///
/// Only marks that were SET are reported: a cleared mark never lowers
/// progress on a tracking site, so there is nothing to send for it.
final class LibraryFinishTracking {
  const LibraryFinishTracking({
    required this.onBooksFinished,
    required this.onVideosWatched,
  });

  /// Books just marked finished (book keys).
  final Future<void> Function(List<String> bookKeys) onBooksFinished;

  /// Local library videos just marked watched (video book uids).
  final Future<void> Function(List<String> videoUids) onVideosWatched;

  /// Nobody listens (no tracking in this process, or a test).
  static const LibraryFinishTracking none = LibraryFinishTracking(
    onBooksFinished: _ignore,
    onVideosWatched: _ignore,
  );

  static Future<void> _ignore(List<String> _) async {}
}

/// The one place a book's "finished" mark (`EpubBooks.completedAt`) is set or
/// cleared by hand: shelf card menu, shelf batch / collection actions, CLI /
/// AI operations. Readers set it through their own end-of-book path, which
/// already reports to tracking.
///
/// [finished] = true stamps [now] (default: the current time) and tells
/// [tracking]; false clears the mark and tells nobody (see
/// [LibraryFinishTracking]). Empty keys are skipped.
Future<void> setBooksFinished({
  required FushiDatabase db,
  required LibraryFinishTracking tracking,
  required Iterable<String> bookKeys,
  required bool finished,
  DateTime? now,
}) async {
  final List<String> keys = <String>[
    for (final String key in bookKeys)
      if (key.isNotEmpty) key,
  ];
  if (keys.isEmpty) return;
  if (!finished) {
    await clearBooksFinished(db: db, bookKeys: keys);
    return;
  }
  final DateTime at = now ?? DateTime.now();
  for (final String key in keys) {
    await db.setEpubBookCompleted(key, at);
  }
  await tracking.onBooksFinished(keys);
}

/// Clears the "finished" mark of [bookKeys] (un-mark, progress reset). Never
/// reported to tracking: a site's progress is never lowered.
Future<void> clearBooksFinished({
  required FushiDatabase db,
  required Iterable<String> bookKeys,
}) async {
  for (final String key in bookKeys) {
    if (key.isEmpty) continue;
    await db.setEpubBookCompleted(key, null);
  }
}
