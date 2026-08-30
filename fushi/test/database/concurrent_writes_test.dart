import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

// These tests verify that Drift's transaction-based read-modify-write
// correctly serializes interleaved async operations on a single isolate.
// This matches the app's real usage pattern (single-isolate DB access).
//
// v92 起累加 DAO（addReadingStatistic / addHourlyReadingTime）已删，统计写入面
// 只剩 study_segments 的按 uid 绝对值 upsert（写入方自己持有段累计器，DB 层不做
// `+=`），因此这里压的是并发 upsertStudySegment：不同 uid 各成一行、同 uid 收敛到
// 最后写入者。累加语义的并发用例随 DAO 一起删除。

/// 一段 study_segments 事实（uid 由调用方给定，便于同 uid 竞写）。
StudySegmentsCompanion _segment({
  required String uid,
  required String mediaKey,
  required int durationMs,
}) =>
    StudySegmentsCompanion.insert(
      uid: uid,
      deviceId: 'dev-test',
      mediaKind: kActivityMediaBook,
      mediaKey: mediaKey,
      title: mediaKey,
      startAt: 1000,
      endAt: 1000 + durationMs,
      dateKey: '2026-05-17',
      hour: 14,
      durationMs: Value(durationMs),
      updatedAt: 1000 + durationMs,
    );

void main() {
  group('Interleaved StudySegments writes', () {
    test('50 interleaved upsertStudySegment with distinct uids all persist',
        () async {
      final db = await _openDb();
      const int n = 50;

      await Future.wait(
        List.generate(
          n,
          (int i) => db.upsertStudySegment(
            _segment(uid: 'seg-$i', mediaKey: 'book/A', durationMs: 1000),
          ),
        ),
      );

      final all = await db.getStudySegments();
      expect(all, hasLength(n));
      expect(all.map((StudySegmentRow r) => r.uid).toSet(), hasLength(n));
    });

    test('interleaved writes to different media stay independent', () async {
      final db = await _openDb();
      const int n = 20;

      await Future.wait([
        for (int i = 0; i < n; i++)
          db.upsertStudySegment(
            _segment(uid: 'a-$i', mediaKey: 'book/A', durationMs: 500),
          ),
        for (int i = 0; i < n; i++)
          db.upsertStudySegment(
            _segment(uid: 'b-$i', mediaKey: 'book/B', durationMs: 300),
          ),
      ]);

      expect(
          await db.getStudySegmentsForMedia(
              mediaKind: kActivityMediaBook, mediaKey: 'book/A'),
          hasLength(n));
      expect(
          await db.getStudySegmentsForMedia(
              mediaKind: kActivityMediaBook, mediaKey: 'book/B'),
          hasLength(n));
    });

    test('rapid upserts to the same uid converge to the last writer', () async {
      final db = await _openDb();
      const int n = 30;
      // upsertStudySegment 是单连接串行的 insert-or-replace：最后提交的写
      // （i == n-1）最后执行、必须胜出，行数恒 1（绝不累加成多行或 `+=`）。
      await Future.wait(
        List.generate(
          n,
          (int i) => db.upsertStudySegment(
            _segment(uid: 'same', mediaKey: 'book/A', durationMs: (i + 1) * 100),
          ),
        ),
      );

      final all = await db.getStudySegments();
      expect(all, hasLength(1));
      expect(all.single.durationMs, n * 100);
    });
  });

  group('Interleaved Preferences writes', () {
    test('50 interleaved setPref on same key produces valid final value',
        () async {
      final db = await _openDb();
      const int n = 50;

      await Future.wait(
        List.generate(
          n,
          (i) => db.setPref('counter', '$i'),
        ),
      );

      final value = await db.getPref('counter');
      expect(value, isNotNull);
      // Verify the value is a parseable integer and not corrupted
      expect(int.tryParse(value!), isNotNull,
          reason: 'value must be a valid integer string, not corrupted');
      // Only one row should exist — upsert should not duplicate
      final all = await db.getAllPrefs();
      expect(all.keys.where((k) => k == 'counter').length, 1);
    });

    test('compareAndSetPref changes the expected raw value and bumps once',
        () async {
      final db = await _openDb();
      final String hiddenRaw = PrefCodec.encode('macos');
      final String autoRaw = PrefCodec.encode('auto');
      await db.setPref('design_system', hiddenRaw);

      final bool changed = await db.compareAndSetPref(
        'design_system',
        expectedValue: hiddenRaw,
        newValue: autoRaw,
      );

      expect(changed, isTrue);
      expect(await db.getPref('design_system'), autoRaw);
      expect(
        PrefCodec.decode<int>(
          (await db.getPref(FushiDatabase.prefsVersionKey))!,
          0,
        ),
        2,
      );
    });

    test('compareAndSetPref mismatch changes neither value nor version',
        () async {
      final db = await _openDb();
      final String materialRaw = PrefCodec.encode('material');
      await db.setPref('design_system', materialRaw);
      final String versionBefore =
          (await db.getPref(FushiDatabase.prefsVersionKey))!;

      final bool changed = await db.compareAndSetPref(
        'design_system',
        expectedValue: PrefCodec.encode('macos'),
        newValue: PrefCodec.encode('auto'),
      );

      expect(changed, isFalse);
      expect(await db.getPref('design_system'), materialRaw);
      expect(
        await db.getPref(FushiDatabase.prefsVersionKey),
        versionBefore,
      );
    });

    test('concurrent compareAndSetPref calls allow exactly one winner',
        () async {
      final db = await _openDb();
      final String hiddenRaw = PrefCodec.encode('cupertino');
      await db.setPref('design_system', hiddenRaw);

      final List<bool> results = await Future.wait(<Future<bool>>[
        db.compareAndSetPref(
          'design_system',
          expectedValue: hiddenRaw,
          newValue: PrefCodec.encode('auto'),
        ),
        db.compareAndSetPref(
          'design_system',
          expectedValue: hiddenRaw,
          newValue: PrefCodec.encode('auto'),
        ),
      ]);

      expect(results.where((bool changed) => changed), hasLength(1));
      expect(
        PrefCodec.decode<int>(
          (await db.getPref(FushiDatabase.prefsVersionKey))!,
          0,
        ),
        2,
        reason: '只有成功的 CAS 能 bump prefs_version',
      );
    });

    test('interleaved setPref on different keys all persist', () async {
      final db = await _openDb();
      const int n = 30;

      await Future.wait(
        List.generate(n, (i) => db.setPref('key_$i', 'val_$i')),
      );

      final all = await db.getAllPrefs();
      // Exclude the prefs_version row: every setPref now auto-bumps the
      // cross-process change counter (TODO-855), adding one bookkeeping row on
      // top of the n user keys.
      final userKeys = all.keys
          .where((String k) => k != FushiDatabase.prefsVersionKey)
          .toList();
      expect(userKeys.length, n);
      for (int i = 0; i < n; i++) {
        expect(all['key_$i'], 'val_$i');
      }
    });

    test('interleaved set and delete does not corrupt', () async {
      final db = await _openDb();

      await Future.wait([
        db.setPref('x', '1'),
        db.setPref('y', '2'),
        db.deletePref('x'),
        db.setPref('x', '3'),
        db.deletePref('y'),
        db.setPref('z', '4'),
      ]);

      final all = await db.getAllPrefs();
      // z is always set last with no competing delete
      expect(all['z'], '4');
      // x and y depend on execution order; verify no corruption
      for (final key in ['x', 'y']) {
        final v = all[key];
        expect(v == null || int.tryParse(v) != null, isTrue,
            reason: '$key must be absent or a valid integer, got: $v');
      }
    });
  });

  group('Interleaved ReaderPositions writes', () {
    test('rapid upserts to same book converge to the last writer', () async {
      final db = await _openDb();
      const int n = 30;
      // HBK-AUDIT-144: deterministic, strictly-increasing values per writer so
      // the converged row can be asserted (not just non-null). upsertReaderPosition
      // is an unconditional insert-or-replace on a single serialized connection,
      // so the last submitted write (i == n-1) executes last and must win.
      const int baseUpdatedAt = 1700000000000;

      await Future.wait(
        List.generate(
          n,
          (i) => db.upsertReaderPosition(
            ReaderPositionsCompanion.insert(
              bookUid: 'book-1',
              sectionIndex: i % 10,
              normCharOffset: i * 100,
              updatedAt: baseUpdatedAt + i,
            ),
          ),
        ),
      );

      final row = await db.getReaderPosition('book-1');
      expect(row, isNotNull);
      // Last-write-wins: the final row reflects the i == n-1 writer's values.
      expect(row!.sectionIndex, (n - 1) % 10);
      expect(row.normCharOffset, (n - 1) * 100);
      expect(row.updatedAt, baseUpdatedAt + (n - 1));
    });

    test('interleaved upserts to different books all persist', () async {
      final db = await _openDb();
      const int n = 20;

      await Future.wait(
        List.generate(
          n,
          (i) => db.upsertReaderPosition(
            ReaderPositionsCompanion.insert(
              bookUid: 'book-$i',
              sectionIndex: i,
              normCharOffset: i * 100,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ),
        ),
      );

      for (int i = 0; i < n; i++) {
        final row = await db.getReaderPosition('book-$i');
        expect(row, isNotNull, reason: 'book $i should exist');
      }
    });
  });
}
