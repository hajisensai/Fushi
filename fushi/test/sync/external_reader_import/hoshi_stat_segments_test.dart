import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_stat_segments.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

int _ms(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime(y, m, d, h, min).millisecondsSinceEpoch;

const ExternalReaderSegmentTarget _target = ExternalReaderSegmentTarget(
  mediaKey: 'book-key',
  title: 'Book',
  format: 'epub',
  profileId: 7,
  profileName: 'Main',
);

TtuStatistics _day(
  String dateKey, {
  int chars = 0,
  double seconds = 0,
  int modified = 0,
}) => TtuStatistics(
  title: 'Book',
  dateKey: dateKey,
  charactersRead: chars,
  readingTimeSec: seconds,
  minReadingSpeed: 0,
  altMinReadingSpeed: 0,
  lastReadingSpeed: 0,
  maxReadingSpeed: 0,
  lastStatisticModified: modified,
);

void main() {
  tearDown(() => FushiDatabase.statDayResetHour = 0);

  group('splitReadingSpanByLocalHour', () {
    test('keeps a span inside one hour as a single piece', () {
      final List<ExternalReaderSegmentPiece> pieces =
          splitReadingSpanByLocalHour(
            startAt: _ms(2026, 9, 1, 10, 5),
            endAt: _ms(2026, 9, 1, 10, 50),
            durationMs: 30 * 60000,
            chars: 900,
          );
      expect(pieces, hasLength(1));
      expect(pieces.single.durationMs, 30 * 60000);
      expect(pieces.single.chars, 900);
    });

    test('splits at local hour boundaries and sums exactly', () {
      final int start = _ms(2026, 9, 1, 10, 30);
      final int end = _ms(2026, 9, 1, 12, 30);
      const int duration = 100 * 60000 + 7;
      const int chars = 1001;
      final List<ExternalReaderSegmentPiece> pieces =
          splitReadingSpanByLocalHour(
            startAt: start,
            endAt: end,
            durationMs: duration,
            chars: chars,
          );
      expect(pieces, hasLength(3));
      expect(pieces.first.startAt, start);
      expect(pieces[1].startAt, _ms(2026, 9, 1, 11));
      expect(pieces.last.endAt, end);
      expect(
        pieces.fold<int>(
          0,
          (int a, ExternalReaderSegmentPiece b) => a + b.durationMs,
        ),
        duration,
      );
      expect(
        pieces.fold<int>(
          0,
          (int a, ExternalReaderSegmentPiece b) => a + b.chars,
        ),
        chars,
      );
      for (final ExternalReaderSegmentPiece piece in pieces) {
        expect(
          piece.endAt - piece.startAt,
          greaterThanOrEqualTo(piece.durationMs),
        );
        final DateTime s = DateTime.fromMillisecondsSinceEpoch(piece.startAt);
        final DateTime e = DateTime.fromMillisecondsSinceEpoch(piece.endAt - 1);
        expect(e.hour, s.hour, reason: 'piece must not cross an hour');
      }
    });

    test('zero-length span becomes one chars-only piece', () {
      final int at = _ms(2026, 9, 1, 8);
      final List<ExternalReaderSegmentPiece> pieces =
          splitReadingSpanByLocalHour(
            startAt: at,
            endAt: at,
            durationMs: 0,
            chars: 12,
          );
      expect(pieces.single.durationMs, 0);
      expect(pieces.single.chars, 12);
      expect(pieces.single.startAt, at);
    });
  });

  group('studySegmentsForSession', () {
    ExternalReaderSession session({
      int start = 0,
      int end = 0,
      double seconds = 0,
      int chars = 0,
      int modified = 0,
    }) => ExternalReaderSession(
      id: 'S-1',
      modifiedAt: modified,
      startedAt: start,
      endedAt: end,
      charactersRead: chars,
      readingTimeSec: seconds,
    );

    test('maps a session onto import segments with Fushi day keys', () {
      FushiDatabase.statDayResetHour = 4;
      final int start = _ms(2026, 9, 2, 2, 30); // 重置前的凌晨 → 昨日。
      final List<StudySegmentsCompanion> rows = studySegmentsForSession(
        session(
          start: start,
          end: start + 20 * 60000,
          seconds: 900,
          chars: 450,
          modified: 1234,
        ),
        _target,
      );
      expect(rows, hasLength(1));
      final StudySegmentsCompanion row = rows.single;
      expect(row.deviceId.value, kExternalReaderImportDeviceId);
      expect(row.mediaKind.value, kActivityMediaBook);
      expect(row.mediaKey.value, 'book-key');
      expect(row.format.value, BookFormat.epub.dbValue);
      expect(row.profileId.value, 7);
      expect(row.dateKey.value, '2026-09-01');
      expect(row.hour.value, 2);
      expect(row.durationMs.value, 900000);
      expect(row.chars.value, 450);
      expect(row.updatedAt.value, 1234);
      expect(row.uid.value, hasLength(32));
    });

    test('uids are deterministic and profile-scoped', () {
      final ExternalReaderSession s = session(
        start: _ms(2026, 9, 1, 9),
        end: _ms(2026, 9, 1, 9, 10),
        seconds: 600,
        chars: 10,
      );
      final String a = studySegmentsForSession(s, _target).single.uid.value;
      final String b = studySegmentsForSession(s, _target).single.uid.value;
      const ExternalReaderSegmentTarget other = ExternalReaderSegmentTarget(
        mediaKey: 'book-key',
        title: 'Book',
        format: 'epub',
        profileId: 8,
        profileName: 'Other',
      );
      final String c = studySegmentsForSession(s, other).single.uid.value;
      expect(a, b);
      expect(a, isNot(c));
    });

    test('updatedAt falls back to the reproducible end, not now', () {
      final int start = _ms(2026, 9, 1, 9);
      final StudySegmentsCompanion row = studySegmentsForSession(
        session(start: start, end: start + 60000, seconds: 60, chars: 1),
        _target,
      ).single;
      expect(row.updatedAt.value, start + 60000);
    });

    test('an idle reader left open does not smear reading across days', () {
      final int start = _ms(2026, 9, 1, 22);
      final List<StudySegmentsCompanion> rows = studySegmentsForSession(
        session(
          start: start,
          end: _ms(2026, 9, 3, 8),
          seconds: 30 * 60,
          chars: 300,
        ),
        _target,
      );
      expect(rows, hasLength(1));
      expect(rows.single.endAt.value, start + 30 * 60000);
    });

    test('extends the end when readingTime exceeds the wall span', () {
      final int start = _ms(2026, 9, 1, 9);
      final List<StudySegmentsCompanion> rows = studySegmentsForSession(
        session(start: start, end: start, seconds: 120, chars: 5),
        _target,
      );
      expect(rows.single.endAt.value, start + 120000);
      expect(rows.single.durationMs.value, 120000);
    });

    test('empty sessions produce nothing', () {
      expect(
        studySegmentsForSession(
          session(start: _ms(2026, 9, 1), end: _ms(2026, 9, 1, 1)),
          _target,
        ),
        isEmpty,
      );
    });
  });

  group('studySegmentsForDailyRecord', () {
    test('keeps Hoshi dateKey and anchors on lastStatisticModified', () {
      final int modified = _ms(2026, 9, 2, 1, 30); // Hoshi 日界后的凌晨。
      final int now = _ms(2026, 9, 20);
      final List<StudySegmentsCompanion> rows = studySegmentsForDailyRecord(
        _day('2026-09-01', chars: 600, seconds: 3600, modified: modified),
        sourceTitle: 'Book',
        target: _target,
        nowMs: now,
      );
      expect(
        rows.map((StudySegmentsCompanion r) => r.dateKey.value).toSet(),
        <String>{'2026-09-01'},
      );
      expect(rows.first.startAt.value, modified - 3600000);
      expect(rows.last.endAt.value, modified);
      expect(
        rows.fold<int>(
          0,
          (int a, StudySegmentsCompanion r) => a + r.durationMs.value,
        ),
        3600000,
      );
      expect(
        rows.fold<int>(
          0,
          (int a, StudySegmentsCompanion r) => a + r.chars.value,
        ),
        600,
      );
      expect(rows.first.updatedAt.value, modified);
    });

    test(
      'falls back to the stat day reset hour when the anchor is off-day',
      () {
        FushiDatabase.statDayResetHour = 5;
        final List<StudySegmentsCompanion> rows = studySegmentsForDailyRecord(
          _day(
            '2026-09-01',
            chars: 10,
            seconds: 600,
            modified: _ms(2026, 9, 10),
          ),
          sourceTitle: 'Book',
          target: _target,
          nowMs: _ms(2026, 9, 20),
        );
        expect(rows.single.startAt.value, _ms(2026, 9, 1, 5));
        expect(rows.single.endAt.value, _ms(2026, 9, 1, 5, 10));
        expect(rows.single.dateKey.value, '2026-09-01');
      },
    );

    test('never places reading in the future', () {
      final int now = _ms(2026, 9, 1, 0, 30);
      final List<StudySegmentsCompanion> rows = studySegmentsForDailyRecord(
        _day('2026-09-01', chars: 10, seconds: 3600),
        sourceTitle: 'Book',
        target: _target,
        nowMs: now,
      );
      expect(rows.last.endAt.value, now);
    });

    test('caps a corrupt day at 24 hours and skips empty days', () {
      final List<StudySegmentsCompanion> rows = studySegmentsForDailyRecord(
        _day('2026-09-01', seconds: 3 * 86400.0),
        sourceTitle: 'Book',
        target: _target,
        nowMs: _ms(2026, 9, 20),
      );
      expect(
        rows.fold<int>(
          0,
          (int a, StudySegmentsCompanion r) => a + r.durationMs.value,
        ),
        Duration.millisecondsPerDay,
      );
      expect(
        studySegmentsForDailyRecord(
          _day('2026-09-02'),
          sourceTitle: 'Book',
          target: _target,
          nowMs: _ms(2026, 9, 20),
        ),
        isEmpty,
      );
    });

    test('day uids are seeded by the Hoshi title, not the Fushi key', () {
      final TtuStatistics day = _day(
        '2026-09-01',
        chars: 5,
        seconds: 60,
        modified: 1,
      );
      const ExternalReaderSegmentTarget suffixed = ExternalReaderSegmentTarget(
        mediaKey: 'Book (2)',
        title: 'Book (2)',
        format: 'epub',
        profileId: 7,
        profileName: 'Main',
      );
      final String a = studySegmentsForDailyRecord(
        day,
        sourceTitle: 'Book',
        target: _target,
        nowMs: _ms(2026, 9, 20),
      ).single.uid.value;
      final String b = studySegmentsForDailyRecord(
        day,
        sourceTitle: 'Book',
        target: suffixed,
        nowMs: _ms(2026, 9, 20),
      ).single.uid.value;
      expect(a, b);
    });
  });
}
