// Optional contract extensions of docs/specs/2026-11-11-bangumi-bundled-plugin.md
// §2: games (status writes), one-book subjects, the user's list.
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/tracking_entry_plan.dart';
import 'package:test/test.dart';

TrackingSiteEntry _entry(
  TrackingEntryStatus status, {
  int progress = 0,
  int? volumes,
}) => TrackingSiteEntry(
  status: status,
  progress: progress,
  progressVolume: volumes,
);

void main() {
  group('singleVolume (chapter mode)', () {
    test('finishing the item completes a one-book subject without a chapter '
        'total, and sends volume 1 when the work has one volume', () {
      expect(
        planTrackingEntryWrite(
          entry: _entry(TrackingEntryStatus.current, progress: 3),
          mode: TrackingProgressMode.chapter,
          progress: 12,
          completed: true,
          singleVolume: true,
          finalVolume: 1,
        ),
        const TrackingEntryWrite(
          create: false,
          status: TrackingEntryStatus.completed,
          progress: 12,
          progressVolume: 1,
        ),
      );
    });

    test('volume count unknown: completes, no volume sent', () {
      expect(
        planTrackingEntryWrite(
          entry: null,
          mode: TrackingProgressMode.chapter,
          progress: 5,
          completed: true,
          singleVolume: true,
        ),
        const TrackingEntryWrite(
          create: true,
          status: TrackingEntryStatus.completed,
          progress: 5,
        ),
      );
    });

    test('volume already 1 and nothing else changes: no write', () {
      expect(
        planTrackingEntryWrite(
          entry: _entry(
            TrackingEntryStatus.completed,
            progress: 12,
            volumes: 1,
          ),
          mode: TrackingProgressMode.chapter,
          progress: 12,
          completed: true,
          singleVolume: true,
          finalVolume: 1,
        ),
        isNull,
      );
    });

    test('a completed entry still gets volume 1 (status kept)', () {
      expect(
        planTrackingEntryWrite(
          entry: _entry(TrackingEntryStatus.completed, progress: 12),
          mode: TrackingProgressMode.chapter,
          progress: 12,
          completed: true,
          singleVolume: true,
          finalVolume: 1,
        ),
        const TrackingEntryWrite(
          create: false,
          status: TrackingEntryStatus.completed,
          progress: 12,
          progressVolume: 1,
        ),
      );
    });

    test('not finished, or not one book, or volume mode: unchanged rules', () {
      expect(
        planTrackingEntryWrite(
          entry: null,
          mode: TrackingProgressMode.chapter,
          progress: 4,
          completed: false,
          singleVolume: true,
          finalVolume: 1,
        ),
        const TrackingEntryWrite(
          create: true,
          status: TrackingEntryStatus.current,
          progress: 4,
        ),
      );
      expect(
        planTrackingEntryWrite(
          entry: null,
          mode: TrackingProgressMode.chapter,
          progress: 4,
          completed: true,
          finalVolume: 1,
        ),
        const TrackingEntryWrite(
          create: true,
          status: TrackingEntryStatus.current,
          progress: 4,
        ),
      );
      expect(
        planTrackingEntryWrite(
          entry: null,
          mode: TrackingProgressMode.volume,
          progress: 1,
          completed: true,
          singleVolume: true,
          finalVolume: 3,
        ),
        const TrackingEntryWrite(
          create: true,
          status: TrackingEntryStatus.current,
          progressVolume: 1,
        ),
      );
    });
  });

  group('status writes (games)', () {
    test('play status codes 1..5', () {
      expect(
        <TrackingEntryStatus?>[
          for (int code = 0; code <= 6; code++)
            TrackingEntryStatus.ofPlayStatus(code),
        ],
        <TrackingEntryStatus?>[
          null,
          TrackingEntryStatus.planned,
          TrackingEntryStatus.completed,
          TrackingEntryStatus.current,
          TrackingEntryStatus.paused,
          TrackingEntryStatus.dropped,
          null,
        ],
      );
    });

    test('created when missing, written as is (no keep rule), skipped when '
        'equal or unreadable', () {
      expect(
        planTrackingStatusWrite(
          entry: null,
          status: TrackingEntryStatus.planned,
        ),
        const TrackingEntryWrite(
          create: true,
          status: TrackingEntryStatus.planned,
        ),
      );
      expect(
        planTrackingStatusWrite(
          entry: _entry(TrackingEntryStatus.completed),
          status: TrackingEntryStatus.current,
        )!.toJson(),
        <String, Object?>{'create': false, 'status': 'current'},
      );
      expect(
        planTrackingStatusWrite(
          entry: _entry(TrackingEntryStatus.dropped),
          status: TrackingEntryStatus.dropped,
        ),
        isNull,
      );
      expect(
        planTrackingStatusWrite(
          entry: const TrackingSiteEntry(status: null, progress: 0),
          status: TrackingEntryStatus.current,
        ),
        isNull,
      );
    });

    test('a progress planner refuses status mode', () {
      expect(
        () => planTrackingEntryWrite(
          entry: null,
          mode: TrackingProgressMode.status,
          progress: 1,
          completed: false,
        ),
        throwsArgumentError,
      );
    });
  });

  group('subjects', () {
    test('a game subject keeps id, name and second title only', () {
      final TrackingPluginSubject subject = parseTrackingSubject(
        <String, Object?>{
          'id': 9,
          'name': '  Game  ',
          'kind': 'game',
          'titles': <String>['Game', 'ゲーム'],
          'totalEpisodes': 3,
        },
      )!;
      expect(subject.kind, TrackingKind.game);
      expect(subject.subjectId, 9);
      expect(subject.name, 'Game');
      expect(subject.altName, 'ゲーム');
      expect(subject.game!.episodeCount, isNull);
      expect(subject.book, isNull);
      expect(subject.anime, isNull);
    });

    test('singleVolume is read only when exactly true', () {
      Map<String, Object?> book(Object? flag) => <String, Object?>{
        'id': 1,
        'name': 'Book',
        'kind': 'novel',
        'singleVolume': flag,
      };
      expect(parseTrackingSubject(book(true))!.singleVolume, isTrue);
      expect(parseTrackingSubject(book('true'))!.singleVolume, isFalse);
      expect(parseTrackingSubject(book(null))!.singleVolume, isFalse);
    });
  });

  group('TrackingListPage.fromJson', () {
    test('keeps good items, drops bad ones, reads next', () {
      final TrackingListPage page = TrackingListPage.fromJson(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'subject': <String, Object?>{'id': 1, 'name': 'A', 'kind': 'anime'},
            'status': 'completed',
            'progress': 12,
            'updatedAt': '2026-01-02T03:04:05Z',
          },
          <String, Object?>{
            'subject': <String, Object?>{'id': 0, 'name': 'B', 'kind': 'anime'},
            'status': 'completed',
            'progress': 1,
          },
          <String, Object?>{
            'subject': <String, Object?>{'id': 3, 'name': 'C', 'kind': 'anime'},
            'status': 'watched',
            'progress': 1,
          },
          <String, Object?>{
            'subject': <String, Object?>{'id': 4, 'name': 'D', 'kind': 'anime'},
            'status': 'current',
            'progress': -1,
          },
          'garbage',
        ],
        'next': 50,
      });
      expect(page.items, hasLength(1));
      expect(page.items.single.subject.subjectId, 1);
      expect(page.items.single.progress, 12);
      expect(page.items.single.updatedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(page.next, 50);
      expect(
        TrackingListPage.fromJson(<String, Object?>{'items': <Object?>[]}).next,
        isNull,
      );
      expect(
        () => TrackingListPage.fromJson(<String, Object?>{}),
        throwsFormatException,
      );
    });
  });
}
