/// What the home Tracking widget says about recent sends: one entry per title
/// for the newest sends from the Activity log, the same for updates still in
/// the outbox, and counts over a time window. Pure functions over rows the
/// snapshot already read ([MediaTrackingHomeSnapshot.activity] /
/// [MediaTrackingHomeSnapshot.queued]); no database, no network.
library;

import 'package:fushi_core/fushi_core.dart'
    show MediaTrackingActivityRow, MediaTrackingOutboxRow;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show PendingTrackingUpdate;

/// Where one title's newest update stands.
enum MediaTrackingSendState {
  /// The site accepted it.
  sent,

  /// The last attempt failed (still queued when it came from the outbox).
  failed,

  /// Waiting in the outbox, not tried yet or backing off without an error.
  queued,
}

/// One title's newest update, merged over the sites it went to.
final class MediaTrackingRecentSend {
  const MediaTrackingRecentSend({
    required this.mediaType,
    required this.mediaKey,
    required this.mediaTitle,
    required this.kind,
    required this.progressMode,
    required this.progress,
    required this.completed,
    required this.state,
    required this.at,
    required this.siteIds,
    this.error,
  });

  /// `TrackingMediaType.value` and key of the local item.
  final String mediaType;
  final String mediaKey;
  final String mediaTitle;

  /// `TrackingKind.value` of the link.
  final String kind;

  /// `TrackingProgressMode.value` of the link (`status` = a game status).
  final String progressMode;

  /// The progress (or status code) in the site's units.
  final int progress;
  final bool completed;
  final MediaTrackingSendState state;

  /// When it was sent, or for an outbox entry when it was last queued or
  /// tried (epoch ms).
  final int at;

  /// The sites this update went to (or waits for), newest first, each once.
  final List<String> siteIds;

  /// The error text of a failed update.
  final String? error;

  /// `mediaType|mediaKey`, the identity rows are merged by.
  String get titleKey => '$mediaType|$mediaKey';
}

/// Counts over successful sends in a time window
/// ([mediaTrackingSendTotals]).
final class MediaTrackingSendTotals {
  const MediaTrackingSendTotals({
    required this.updates,
    required this.titles,
    required this.finished,
  });

  static const MediaTrackingSendTotals zero = MediaTrackingSendTotals(
    updates: 0,
    titles: 0,
    finished: 0,
  );

  /// Distinct updates (one title, one progress); the same update sent to two
  /// sites counts once.
  final int updates;

  /// Distinct titles that got at least one update.
  final int titles;

  /// Distinct titles sent as finished.
  final int finished;
}

/// The newest sends from the Activity log, one entry per title, newest first,
/// at most [limit] titles. [rows] must be newest first
/// ([MediaTrackingRepository.listActivity]).
///
/// A title's entry is its newest row; another site joins it when that site's
/// own newest row for the title sent the same thing with the same outcome
/// (AniList and MAL both got episode 12). A site whose newest row differs is
/// left out: it sent something else, which is not this entry.
List<MediaTrackingRecentSend> mediaTrackingRecentSends(
  Iterable<MediaTrackingActivityRow> rows, {
  int limit = 8,
}) {
  final Map<String, _SendBuilder> byTitle = <String, _SendBuilder>{};
  final Set<String> seenSiteOfTitle = <String>{};
  for (final MediaTrackingActivityRow row in rows) {
    final String title = '${row.mediaType}|${row.mediaKey}';
    // Only a site's newest row for a title says what that site has.
    if (!seenSiteOfTitle.add('$title|${row.provider}')) continue;
    final _SendBuilder? existing = byTitle[title];
    if (existing == null) {
      if (byTitle.length == limit) continue;
      byTitle[title] = _SendBuilder(
        mediaType: row.mediaType,
        mediaKey: row.mediaKey,
        mediaTitle: row.mediaTitle,
        kind: row.kind,
        progressMode: row.progressMode,
        progress: row.progress,
        completed: row.completed,
        state: row.ok
            ? MediaTrackingSendState.sent
            : MediaTrackingSendState.failed,
        at: row.createdAt,
        error: row.ok ? null : row.error,
        siteId: row.provider,
      );
      continue;
    }
    final bool same =
        existing.progressMode == row.progressMode &&
        existing.progress == row.progress &&
        existing.completed == row.completed &&
        (existing.state == MediaTrackingSendState.sent) == row.ok;
    if (same) existing.siteIds.add(row.provider);
  }
  return <MediaTrackingRecentSend>[
    for (final _SendBuilder b in byTitle.values) b.build(),
  ];
}

/// The updates waiting in the outbox, one entry per title, newest first.
/// An entry is [MediaTrackingSendState.failed] when any of its sites' last
/// attempt failed; its progress is the newest queued one.
List<MediaTrackingRecentSend> mediaTrackingQueuedSends(
  Iterable<PendingTrackingUpdate> updates,
) {
  final List<PendingTrackingUpdate> sorted =
      List<PendingTrackingUpdate>.of(updates)..sort(
        (PendingTrackingUpdate a, PendingTrackingUpdate b) =>
            b.outbox.updatedAt.compareTo(a.outbox.updatedAt),
      );
  final Map<String, _SendBuilder> byTitle = <String, _SendBuilder>{};
  for (final PendingTrackingUpdate update in sorted) {
    final MediaTrackingOutboxRow outbox = update.outbox;
    final String title =
        '${update.mapping.mediaType}|${update.mapping.mediaKey}';
    final String error = (outbox.lastError ?? '').trim();
    final _SendBuilder? existing = byTitle[title];
    if (existing == null) {
      byTitle[title] = _SendBuilder(
        mediaType: update.mapping.mediaType,
        mediaKey: update.mapping.mediaKey,
        mediaTitle: update.mapping.mediaTitle,
        kind: update.mapping.kind,
        progressMode: update.mapping.progressMode,
        progress: outbox.progress,
        completed: outbox.completed,
        state: error.isEmpty
            ? MediaTrackingSendState.queued
            : MediaTrackingSendState.failed,
        at: outbox.updatedAt,
        error: error.isEmpty ? null : error,
        siteId: update.mapping.provider,
      );
      continue;
    }
    if (!existing.siteIds.contains(update.mapping.provider)) {
      existing.siteIds.add(update.mapping.provider);
    }
    if (error.isNotEmpty && existing.state != MediaTrackingSendState.failed) {
      existing
        ..state = MediaTrackingSendState.failed
        ..error = error;
    }
  }
  return <MediaTrackingRecentSend>[
    for (final _SendBuilder b in byTitle.values) b.build(),
  ];
}

/// Counts over the successful rows of [rows] sent at or after [sinceMs].
MediaTrackingSendTotals mediaTrackingSendTotals(
  Iterable<MediaTrackingActivityRow> rows, {
  required int sinceMs,
}) {
  final Set<String> updates = <String>{};
  final Set<String> titles = <String>{};
  final Set<String> finished = <String>{};
  for (final MediaTrackingActivityRow row in rows) {
    if (!row.ok || row.createdAt < sinceMs) continue;
    final String title = '${row.mediaType}|${row.mediaKey}';
    titles.add(title);
    updates.add('$title|${row.progressMode}|${row.progress}|${row.completed}');
    if (row.completed) finished.add(title);
  }
  if (titles.isEmpty) return MediaTrackingSendTotals.zero;
  return MediaTrackingSendTotals(
    updates: updates.length,
    titles: titles.length,
    finished: finished.length,
  );
}

class _SendBuilder {
  _SendBuilder({
    required this.mediaType,
    required this.mediaKey,
    required this.mediaTitle,
    required this.kind,
    required this.progressMode,
    required this.progress,
    required this.completed,
    required this.state,
    required this.at,
    required this.error,
    required String siteId,
  }) : siteIds = <String>[siteId];

  final String mediaType;
  final String mediaKey;
  final String mediaTitle;
  final String kind;
  final String progressMode;
  final int progress;
  final bool completed;
  MediaTrackingSendState state;
  final int at;
  String? error;
  final List<String> siteIds;

  MediaTrackingRecentSend build() => MediaTrackingRecentSend(
    mediaType: mediaType,
    mediaKey: mediaKey,
    mediaTitle: mediaTitle,
    kind: kind,
    progressMode: progressMode,
    progress: progress,
    completed: completed,
    state: state,
    at: at,
    siteIds: List<String>.unmodifiable(siteIds),
    error: error,
  );
}
