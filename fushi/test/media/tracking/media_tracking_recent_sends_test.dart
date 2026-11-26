// The home Tracking widget's view of recent sends: one entry per title from
// the Activity log (sites merged only when they got the same update), the
// outbox grouped the same way, the counts over a time window, and that
// hidden (locked) titles drop out of both lists.

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        MediaTrackingActivityRow,
        MediaTrackingMappingRow,
        MediaTrackingOutboxRow;
import 'package:fushi_engine/media/tracking/media_tracking_recent_sends.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';

int _id = 0;

MediaTrackingActivityRow activity(
  String provider,
  String key,
  int progress, {
  required int at,
  bool ok = true,
  bool completed = false,
  String type = 'video_collection',
}) => MediaTrackingActivityRow(
  id: ++_id,
  provider: provider,
  mediaType: type,
  mediaKey: key,
  mediaTitle: 'title $key',
  kind: TrackingKind.anime.value,
  progressMode: TrackingProgressMode.episode.value,
  progress: progress,
  completed: completed,
  ok: ok,
  error: ok ? null : 'HTTP 503',
  createdAt: at,
);

PendingTrackingUpdate queued(
  String provider,
  String key,
  int progress, {
  required int at,
  String? error,
}) => PendingTrackingUpdate(
  outbox: MediaTrackingOutboxRow(
    id: ++_id,
    mappingId: _id,
    progress: progress,
    completed: false,
    attemptCount: error == null ? 0 : 1,
    nextAttemptAt: 0,
    lastError: error,
    updatedAt: at,
  ),
  mapping: MediaTrackingMappingRow(
    id: _id,
    provider: provider,
    mediaType: 'video_collection',
    mediaKey: key,
    mediaTitle: 'title $key',
    kind: TrackingKind.anime.value,
    subjectId: 1,
    subjectName: 's',
    progressMode: TrackingProgressMode.episode.value,
    progressOffset: 1,
    createdAt: 0,
    updatedAt: 0,
    sentCompleted: false,
  ),
);

void main() {
  group('mediaTrackingRecentSends', () {
    test('one entry per title, newest first, sites that got the same update '
        'merged', () {
      final List<MediaTrackingRecentSend> sends =
          mediaTrackingRecentSends(<MediaTrackingActivityRow>[
            activity('anilist', 'a', 12, at: 300),
            activity('mal', 'a', 12, at: 299),
            activity('anilist', 'b', 40, at: 200),
            activity('anilist', 'a', 11, at: 100),
          ]);
      expect(sends.map((MediaTrackingRecentSend s) => s.mediaKey), <String>[
        'a',
        'b',
      ]);
      expect(sends.first.progress, 12);
      expect(sends.first.siteIds, <String>['anilist', 'mal']);
      expect(sends.first.state, MediaTrackingSendState.sent);
      expect(sends.first.at, 300);
    });

    test('a site whose newest row for the title differs is left out', () {
      final List<MediaTrackingRecentSend> sends = mediaTrackingRecentSends(
        <MediaTrackingActivityRow>[
          activity('anilist', 'a', 12, at: 300),
          // MAL's newest is episode 11: it did not get episode 12.
          activity('mal', 'a', 11, at: 250),
          // An older MAL row with episode 12 does not count either: it is
          // not what MAL has now.
          activity('mal', 'a', 12, at: 50),
          // Same progress but failed: a different outcome.
          activity('bangumi', 'a', 12, at: 290, ok: false),
        ],
      );
      expect(sends.single.siteIds, <String>['anilist']);
    });

    test(
      'a title whose newest row failed is a failed entry with the error',
      () {
        final MediaTrackingRecentSend send = mediaTrackingRecentSends(
          <MediaTrackingActivityRow>[
            activity('mal', 'a', 7, at: 10, ok: false),
          ],
        ).single;
        expect(send.state, MediaTrackingSendState.failed);
        expect(send.error, 'HTTP 503');
      },
    );

    test('stops at the limit of titles', () {
      final List<MediaTrackingRecentSend> sends = mediaTrackingRecentSends(
        <MediaTrackingActivityRow>[
          for (int i = 0; i < 12; i++)
            activity('anilist', 'k$i', 1, at: 100 - i),
        ],
        limit: 3,
      );
      expect(sends.map((MediaTrackingRecentSend s) => s.mediaKey), <String>[
        'k0',
        'k1',
        'k2',
      ]);
    });
  });

  group('mediaTrackingQueuedSends', () {
    test(
      'newest first, sites merged, a failing site makes the entry failed',
      () {
        final List<MediaTrackingRecentSend> sends =
            mediaTrackingQueuedSends(<PendingTrackingUpdate>[
              queued('anilist', 'a', 3, at: 100),
              queued('mal', 'a', 3, at: 90, error: 'HTTP 429'),
              queued('anilist', 'b', 9, at: 200),
            ]);
        expect(sends.map((MediaTrackingRecentSend s) => s.mediaKey), <String>[
          'b',
          'a',
        ]);
        expect(sends.first.state, MediaTrackingSendState.queued);
        expect(sends.last.state, MediaTrackingSendState.failed);
        expect(sends.last.error, 'HTTP 429');
        expect(sends.last.siteIds, <String>['anilist', 'mal']);
      },
    );
  });

  group('mediaTrackingSendTotals', () {
    test(
      'counts accepted updates in the window, one per title and progress',
      () {
        final MediaTrackingSendTotals totals =
            mediaTrackingSendTotals(<MediaTrackingActivityRow>[
              activity('anilist', 'a', 12, at: 300),
              activity('mal', 'a', 12, at: 299),
              activity('anilist', 'a', 11, at: 200),
              activity('anilist', 'b', 5, at: 250, completed: true),
              activity('anilist', 'c', 1, at: 260, ok: false),
              activity('anilist', 'd', 1, at: 10),
            ], sinceMs: 100);
        expect(totals.updates, 3);
        expect(totals.titles, 2);
        expect(totals.finished, 1);
      },
    );

    test('nothing in the window is zero', () {
      expect(
        mediaTrackingSendTotals(<MediaTrackingActivityRow>[
          activity('anilist', 'a', 1, at: 10),
        ], sinceMs: 100),
        same(MediaTrackingSendTotals.zero),
      );
    });
  });

  test('withoutMedia drops hidden titles from the log and the outbox', () {
    final MediaTrackingHomeSnapshot snapshot = MediaTrackingHomeSnapshot(
      sites: const <MediaTrackingProviderStatus>[],
      siteNames: const <String, String>{},
      mappings: const <MediaTrackingMappingRow>[],
      unlinked: const <MediaTrackingUnlinkedItem>[],
      activity: <MediaTrackingActivityRow>[
        activity('anilist', 'locked', 2, at: 20),
        activity('anilist', 'open', 1, at: 10),
      ],
      queued: <PendingTrackingUpdate>[queued('anilist', 'locked', 3, at: 30)],
    );
    final MediaTrackingHomeSnapshot visible = snapshot.withoutMedia(
      (String type, String key) => key == 'locked',
    );
    expect(
      visible.recentSends().map((MediaTrackingRecentSend s) => s.mediaKey),
      <String>['open'],
    );
    expect(visible.queuedSends, isEmpty);
  });
}
