import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/tracking_entry_plan.dart';
import 'package:test/test.dart';

const TrackingEntryStatus _planned = TrackingEntryStatus.planned;
const TrackingEntryStatus _current = TrackingEntryStatus.current;
const TrackingEntryStatus _completed = TrackingEntryStatus.completed;
const TrackingEntryStatus _paused = TrackingEntryStatus.paused;
const TrackingEntryStatus _dropped = TrackingEntryStatus.dropped;
const TrackingEntryStatus _repeating = TrackingEntryStatus.repeating;

TrackingSiteEntry _entry(
  TrackingEntryStatus status, {
  int progress = 0,
  int? volumes,
}) => TrackingSiteEntry(
  status: status,
  progress: progress,
  progressVolume: volumes,
);

TrackingEntryWrite _write(
  TrackingEntryStatus status, {
  bool create = false,
  int? progress,
  int? volumes,
}) => TrackingEntryWrite(
  create: create,
  status: status,
  progress: progress,
  progressVolume: volumes,
);

/// One planner case: [why] names the site test it was ported from.
typedef _Case = ({
  String why,
  TrackingSiteEntry? entry,
  TrackingProgressMode mode,
  int progress,
  bool completed,
  int? total,
  bool finished,
  TrackingEntryWrite? expected,
});

_Case _case(
  String why, {
  TrackingSiteEntry? entry,
  TrackingProgressMode mode = TrackingProgressMode.chapter,
  required int progress,
  bool completed = false,
  int? total,
  bool finished = false,
  required TrackingEntryWrite? expected,
}) => (
  why: why,
  entry: entry,
  mode: mode,
  progress: progress,
  completed: completed,
  total: total,
  finished: finished,
  expected: expected,
);

void _run(List<_Case> cases) {
  for (final _Case c in cases) {
    test(c.why, () {
      expect(
        planTrackingEntryWrite(
          entry: c.entry,
          mode: c.mode,
          progress: c.progress,
          completed: c.completed,
          total: c.total,
          subjectFinished: c.finished,
        ),
        c.expected,
      );
    });
  }
}

const TrackingProgressMode _episode = TrackingProgressMode.episode;
const TrackingProgressMode _volume = TrackingProgressMode.volume;

void main() {
  // planAniListEntryWrite (anilist_tracking_test.dart), 12-episode show.
  group('episodes (ported from planAniListEntryWrite)', () {
    _run(<_Case>[
      _case(
        'not on the list: add as watching',
        mode: _episode,
        total: 12,
        progress: 3,
        expected: _write(_current, create: true, progress: 3),
      ),
      _case(
        'never lowers progress: remote ahead and watching',
        mode: _episode,
        total: 12,
        entry: _entry(_current, progress: 8),
        progress: 3,
        expected: null,
      ),
      _case(
        'last episode completes',
        mode: _episode,
        total: 12,
        entry: _entry(_current, progress: 11),
        progress: 12,
        expected: _write(_completed, progress: 12),
      ),
      _case(
        'progress is capped at the episode count',
        mode: _episode,
        total: 12,
        progress: 15,
        expected: _write(_completed, create: true, progress: 12),
      ),
      _case(
        'completed keeps its status (nothing to write)',
        mode: _episode,
        total: 12,
        entry: _entry(_completed, progress: 12),
        progress: 2,
        expected: null,
      ),
      _case(
        'rewatching keeps its status',
        mode: _episode,
        total: 12,
        entry: _entry(_repeating, progress: 2),
        progress: 5,
        expected: _write(_repeating, progress: 5),
      ),
      for (final TrackingEntryStatus from in <TrackingEntryStatus>[
        _planned,
        _paused,
        _dropped,
      ])
        _case(
          '${from.wire} becomes watching',
          mode: _episode,
          total: 12,
          entry: _entry(from, progress: 1),
          progress: 1,
          expected: _write(_current, progress: 1),
        ),
      _case(
        'airing show (unknown count) stays watching',
        mode: _episode,
        progress: 30,
        expected: _write(_current, create: true, progress: 30),
      ),
      _case(
        'airing show (unknown count) completes when told',
        mode: _episode,
        progress: 30,
        completed: true,
        expected: _write(_completed, create: true, progress: 30),
      ),
      // Deliberate difference from planAniListEntryWrite (spec §4): with a
      // known count, completed only when the count is reached.
      _case(
        'known count not reached: finished locally stays watching',
        mode: _episode,
        total: 12,
        progress: 5,
        completed: true,
        expected: _write(_current, create: true, progress: 5),
      ),
    ]);
  });

  // planAniListReadingWrite (anilist_tracking_test.dart), 2-volume novel.
  group('reading (ported from planAniListReadingWrite)', () {
    _run(<_Case>[
      _case(
        'volume progress goes up; chapters are not sent',
        mode: _volume,
        total: 2,
        finished: true,
        entry: _entry(_planned, progress: 5),
        progress: 1,
        expected: _write(_current, volumes: 1),
      ),
      _case(
        'the last volume of a finished series completes it',
        mode: _volume,
        total: 2,
        finished: true,
        progress: 2,
        completed: true,
        expected: _write(_completed, create: true, volumes: 2),
      ),
      _case(
        'a releasing series never completes',
        mode: _volume,
        total: 2,
        progress: 2,
        completed: true,
        expected: _write(_current, create: true, volumes: 2),
      ),
      _case(
        'never lowers, nothing to do when already there',
        mode: _volume,
        total: 2,
        finished: true,
        entry: _entry(_current, volumes: 2),
        progress: 1,
        expected: null,
      ),
    ]);
  });

  // planMangaBakaEntryWrite (mangabaka_tracking_test.dart): Lord of the
  // Mysteries, finished, 1432 chapters, 18 volumes.
  group('reading (ported from planMangaBakaEntryWrite)', () {
    _run(<_Case>[
      _case(
        'first progress creates a reading entry',
        total: 1432,
        finished: true,
        progress: 12,
        expected: _write(_current, create: true, progress: 12),
      ),
      _case(
        'nothing to create at zero progress',
        mode: _volume,
        total: 18,
        finished: true,
        progress: 0,
        expected: null,
      ),
      _case(
        'never lowers progress',
        total: 1432,
        finished: true,
        entry: _entry(_current, progress: 40),
        progress: 12,
        expected: null,
      ),
      _case(
        'finishing volume 3 of 18 stays reading',
        mode: _volume,
        total: 18,
        finished: true,
        progress: 3,
        completed: true,
        expected: _write(_current, create: true, volumes: 3),
      ),
      _case(
        'finishing the final volume completes the series',
        mode: _volume,
        total: 18,
        finished: true,
        entry: _entry(_current, volumes: 17),
        progress: 18,
        completed: true,
        expected: _write(_completed, volumes: 18),
      ),
      _case(
        'a releasing series never completes and is not capped',
        total: 100,
        progress: 120,
        completed: true,
        expected: _write(_current, create: true, progress: 120),
      ),
      for (final TrackingEntryStatus kept in <TrackingEntryStatus>[
        _completed,
        _repeating,
      ])
        _case(
          '${kept.wire} keeps its state',
          total: 1432,
          finished: true,
          entry: _entry(kept, progress: 2),
          progress: 5,
          expected: _write(kept, progress: 5),
        ),
      for (final TrackingEntryStatus from in <TrackingEntryStatus>[
        _planned,
        _paused,
        _dropped,
      ])
        _case(
          '${from.wire} becomes reading',
          total: 1432,
          finished: true,
          entry: _entry(from),
          progress: 1,
          expected: _write(_current, progress: 1),
        ),
    ]);
  });

  group('host rules', () {
    _run(<_Case>[
      _case(
        'a finished-series cap applies to chapters too',
        total: 1432,
        finished: true,
        progress: 2000,
        completed: true,
        expected: _write(_completed, create: true, progress: 1432),
      ),
      _case(
        'volume mode never touches chapters, even when they are higher',
        mode: _volume,
        entry: _entry(_current, progress: 300, volumes: 1),
        progress: 2,
        expected: _write(_current, volumes: 2),
      ),
      _case(
        'chapter mode never touches volumes',
        entry: _entry(_current, progress: 3, volumes: 9),
        progress: 4,
        expected: _write(_current, progress: 4),
      ),
      _case(
        'a missing volume count is planned as 0',
        mode: _volume,
        entry: _entry(_current, progress: 3),
        progress: 1,
        expected: _write(_current, volumes: 1),
      ),
      _case(
        'a total of 0 is unknown (episodes not capped at 0)',
        mode: _episode,
        total: 0,
        progress: 4,
        expected: _write(_current, create: true, progress: 4),
      ),
      _case(
        'negative local progress never writes',
        progress: -3,
        expected: null,
      ),
      _case(
        'a completed entry is not reopened by a finished item',
        total: 10,
        finished: true,
        entry: _entry(_completed, progress: 10),
        progress: 10,
        completed: true,
        expected: null,
      ),
      _case(
        'paused with a finishing write becomes completed',
        mode: _volume,
        total: 2,
        finished: true,
        entry: _entry(_paused, volumes: 1),
        progress: 2,
        completed: true,
        expected: _write(_completed, volumes: 2),
      ),
      _case(
        'an entry with an unknown status is left alone',
        entry: const TrackingSiteEntry(status: null, progress: 1),
        progress: 50,
        completed: true,
        expected: null,
      ),
    ]);

    test('status mode is not a list entry unit', () {
      expect(
        () => planTrackingEntryWrite(
          entry: null,
          mode: TrackingProgressMode.status,
          progress: 2,
          completed: false,
        ),
        throwsArgumentError,
      );
    });

    test('toJson sends only the planned fields', () {
      expect(
        _write(_current, create: true, volumes: 3).toJson(),
        <String, Object?>{
          'create': true,
          'status': 'current',
          'progressVolume': 3,
        },
      );
      expect(_write(_repeating, progress: 7).toJson(), <String, Object?>{
        'create': false,
        'status': 'repeating',
        'progress': 7,
      });
    });
  });

  group('TrackingEntryStatus.tryParse', () {
    test('wire strings round-trip; anything else is unknown', () {
      for (final TrackingEntryStatus status in TrackingEntryStatus.values) {
        expect(TrackingEntryStatus.tryParse(' ${status.wire} '), status);
      }
      expect(TrackingEntryStatus.tryParse('CURRENT'), isNull);
      expect(TrackingEntryStatus.tryParse('rereading'), isNull);
      expect(TrackingEntryStatus.tryParse(3), isNull);
      expect(TrackingEntryStatus.tryParse(null), isNull);
    });
  });

  group('TrackingSiteEntry.fromJson', () {
    test('null means not on the list', () {
      expect(TrackingSiteEntry.fromJson(null), isNull);
    });

    test('a well-formed entry', () {
      final TrackingSiteEntry entry = TrackingSiteEntry.fromJson(
        <String, Object?>{
          'status': 'paused',
          'progress': 4.0,
          'progressVolume': 1,
        },
      )!;
      expect(entry.status, _paused);
      expect(entry.progress, 4);
      expect(entry.progressVolume, 1);
    });

    test('a missing volume count is fine', () {
      final TrackingSiteEntry entry = TrackingSiteEntry.fromJson(
        <String, Object?>{'status': 'current', 'progress': 2},
      )!;
      expect(entry.status, _current);
      expect(entry.progressVolume, isNull);
    });

    test('bad counts or status make the entry untouchable', () {
      for (final Map<String, Object?> json in <Map<String, Object?>>[
        <String, Object?>{'status': 'weird', 'progress': 2},
        <String, Object?>{'progress': 2},
        <String, Object?>{'status': 'current'},
        <String, Object?>{'status': 'current', 'progress': -1},
        <String, Object?>{'status': 'current', 'progress': 2.5},
        <String, Object?>{'status': 'current', 'progress': '7'},
        <String, Object?>{'status': 'current', 'progress': double.infinity},
        <String, Object?>{'status': 'current', 'progress': 1 << 40},
        <String, Object?>{
          'status': 'current',
          'progress': 2,
          'progressVolume': -2,
        },
      ]) {
        final TrackingSiteEntry entry = TrackingSiteEntry.fromJson(json)!;
        expect(entry.status, isNull, reason: '$json');
        expect(
          planTrackingEntryWrite(
            entry: entry,
            mode: _volume,
            progress: 99,
            completed: true,
          ),
          isNull,
          reason: '$json',
        );
      }
    });

    test('a non-object result is an error, never "not on the list"', () {
      expect(() => TrackingSiteEntry.fromJson('nope'), throwsFormatException);
      expect(
        () => TrackingSiteEntry.fromJson(<Object?>[]),
        throwsFormatException,
      );
    });
  });

  group('parseTrackingSubject', () {
    Map<String, Object?> book([
      Map<String, Object?> extra = const <String, Object?>{},
    ]) => <String, Object?>{
      'id': 84351,
      'name': ' Lord of Mysteries ',
      'kind': 'novel',
      ...extra,
    };

    test('a full novel subject', () {
      final TrackingPluginSubject subject = parseTrackingSubject(
        book(<String, Object?>{
          'titles': <Object?>['诡秘之主', 'Lord of Mysteries', '', 3],
          'authors': <Object?>[' Cuttlefish ', null],
          'totalChapters': 1432,
          'finalVolume': 18.0,
          'finished': true,
          'linkedIds': <String, Object?>{'anilist': 44893, 'mal': 30831},
        }),
      )!;
      expect(subject.kind, TrackingKind.novel);
      expect(subject.anime, isNull);
      expect(subject.subjectId, 84351);
      expect(subject.name, 'Lord of Mysteries');
      final TrackingBookSubject book0 = subject.book!;
      expect(book0.kind, TrackingKind.novel);
      expect(book0.titles, <String>['Lord of Mysteries', '诡秘之主']);
      expect(book0.authors, <String>['Cuttlefish']);
      expect(book0.totalChapters, 1432);
      expect(book0.finalVolume, 18);
      expect(book0.isFinished, isTrue);
      expect(book0.linkedIds, <String, int>{'anilist': 44893, 'mal': 30831});
    });

    test('an anime subject', () {
      final TrackingPluginSubject subject = parseTrackingSubject(
        <String, Object?>{
          'id': 21,
          'name': 'Show',
          'kind': 'anime',
          'totalEpisodes': 12,
        },
      )!;
      expect(subject.kind, TrackingKind.anime);
      expect(subject.book, isNull);
      expect(subject.anime!.subjectId, 21);
      expect(subject.anime!.name, 'Show');
      expect(subject.anime!.episodeCount, 12);
    });

    test('dropped without a positive id, a name or a known kind', () {
      for (final Object? json in <Object?>[
        null,
        'subject',
        <String, Object?>{'name': 'x', 'kind': 'manga'},
        book(<String, Object?>{'id': 0}),
        book(<String, Object?>{'id': -4}),
        book(<String, Object?>{'id': 1.5}),
        book(<String, Object?>{'id': '12'}),
        book(<String, Object?>{'name': '   '}),
        book(<String, Object?>{'name': 7}),
        <String, Object?>{'id': 1, 'name': 'x'},
        book(<String, Object?>{'kind': 'music'}),
        book(<String, Object?>{'kind': 'Manga'}),
      ]) {
        expect(parseTrackingSubject(json), isNull, reason: '$json');
      }
    });

    test('text is capped; at most 50 titles and 20 authors', () {
      final String long = 'a' * 900;
      final TrackingPluginSubject subject = parseTrackingSubject(
        book(<String, Object?>{
          'name': long,
          'titles': <String>[for (int i = 0; i < 80; i++) 'title $i'],
          'authors': <String>[for (int i = 0; i < 30; i++) 'author $i'],
        }),
      )!;
      expect(subject.name.length, 500);
      expect(subject.book!.titles, hasLength(50));
      expect(subject.book!.titles.first, subject.name);
      expect(subject.book!.authors, hasLength(20));
      expect(subject.book!.authors.last, 'author 19');
    });

    test('bad counts become unknown; only finished: true finishes', () {
      final TrackingPluginSubject subject = parseTrackingSubject(
        book(<String, Object?>{
          'totalChapters': -1,
          'finalVolume': 2.5,
          'finished': 'yes',
        }),
      )!;
      expect(subject.book!.totalChapters, isNull);
      expect(subject.book!.finalVolume, isNull);
      expect(subject.book!.isFinished, isFalse);
      expect(
        parseTrackingSubject(
          book(<String, Object?>{'totalChapters': 0}),
        )!.book!.totalChapters,
        isNull,
        reason: 'a total of 0 says nothing',
      );
      expect(
        parseTrackingSubject(<String, Object?>{
          'id': 1,
          'name': 'Show',
          'kind': 'anime',
          'totalEpisodes': '12',
        })!.anime!.episodeCount,
        isNull,
      );
    });

    test('linkedIds keeps at most 16 positive ids under valid names', () {
      final TrackingPluginSubject subject = parseTrackingSubject(
        book(<String, Object?>{
          'linkedIds': <Object?, Object?>{
            'bad key': 1,
            'UPPER': 2,
            'neg': -3,
            'zero': 0,
            'frac': 1.5,
            7: 4,
            for (int i = 0; i < 20; i++) 'site$i': i + 1,
          },
        }),
      )!;
      final Map<String, int> ids = subject.book!.linkedIds;
      expect(ids, hasLength(16));
      expect(ids.keys.first, 'site0');
      expect(ids.keys.last, 'site15');
      expect(ids.values.every((int id) => id > 0), isTrue);
      expect(
        parseTrackingSubject(
          book(<String, Object?>{
            'linkedIds': <Object?>[1, 2],
          }),
        )!.book!.linkedIds,
        isEmpty,
      );
    });
  });

  group('chapter companion (secondary progress number)', () {
    TrackingEntryWrite? companion(TrackingSiteEntry? entry, int progress) =>
        planTrackingEntryWrite(
          entry: entry,
          mode: TrackingProgressMode.chapter,
          progress: progress,
          completed: false,
          total: 40,
          subjectFinished: true,
          singleVolume: true,
          finalVolume: 1,
          companion: true,
        );

    test('a paused, dropped or planned entry keeps its status; only the '
        'chapter count moves', () {
      for (final TrackingEntryStatus status in <TrackingEntryStatus>[
        _paused,
        _dropped,
        _planned,
      ]) {
        expect(
          companion(_entry(status, progress: 3, volumes: 1), 5),
          _write(status, progress: 5),
          reason: status.wire,
        );
      }
    });

    test('never completes, even at the chapter total of a one-book subject; '
        'completed / repeating are kept', () {
      expect(
        companion(_entry(_current, progress: 39), 40),
        _write(_current, progress: 40),
      );
      expect(companion(_entry(_completed, progress: 10), 12), _write(_completed, progress: 12));
      expect(companion(_entry(_repeating, progress: 10), 12), _write(_repeating, progress: 12));
    });

    test('a new entry is created as current; nothing to send when the site '
        'already has the count', () {
      expect(
        companion(null, 4),
        _write(_current, create: true, progress: 4),
      );
      expect(companion(_entry(_paused, progress: 9), 7), isNull);
    });

    test('the primary unit still resumes a paused entry (unchanged rule)', () {
      expect(
        planTrackingEntryWrite(
          entry: _entry(_paused, volumes: 2),
          mode: TrackingProgressMode.volume,
          progress: 3,
          completed: false,
        ),
        _write(_current, volumes: 3),
      );
    });
  });
}
