import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/library_progress_reset.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

// 库页「重置阅读状态 / 清除观看进度」（用户 2026-10-05：误点开一本书之后要能变回
// 没读过，并可选撤掉学习记录）的落地层行为契约：
//  * 位置写回开头（不删行——删行会被互联 / 云同步从对端灌回），读完标记清空；
//  * 学习记录默认不动；「最近一次」只撤最后一次会话（按 uid 写零、不立碑）；
//  * 「全部」走同步安全的按身份删除 + 墓碑。

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

const int _hour = 3600 * 1000;
// 2026-09-01 本地时区某整点附近；两次会话相隔数小时，必然归成两次。
final int _base = DateTime(2026, 9, 1, 9).millisecondsSinceEpoch;

StudySegmentsCompanion _seg(
  String uid, {
  required String kind,
  required String key,
  required int startAt,
  int ms = 60000,
  int chars = 100,
}) {
  final DateTime start = DateTime.fromMillisecondsSinceEpoch(startAt);
  return StudySegmentsCompanion.insert(
    uid: uid,
    deviceId: 'dev',
    mediaKind: kind,
    mediaKey: key,
    title: 'T',
    startAt: startAt,
    endAt: startAt + ms,
    dateKey:
        '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}',
    hour: start.hour,
    durationMs: Value(ms),
    chars: Value(chars),
    updatedAt: startAt + ms,
  );
}

Future<String> _insertBook(FushiDatabase db, String bookKey) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'Book $bookKey',
      epubPath: '/x/$bookKey.epub',
      extractDir: '/x/$bookKey',
      chapterCount: 3,
      chaptersJson: '[]',
      importedAt: 1000,
    ),
  );
  return (await db.resolveEpubBookUid(bookKey))!;
}

Future<Map<String, StudySegmentRow>> _segments(FushiDatabase db) async =>
    <String, StudySegmentRow>{
      for (final StudySegmentRow r in await db.getStudySegments()) r.uid: r,
    };

void main() {
  group('resetBookReadingState', () {
    test('带有声书时音频位置一并归零（开书以音频位置为主，BUG-2390）', () async {
      final FushiDatabase db = await _openDb();
      await _insertBook(db, 'ab');
      final AudiobookRepository audio = AudiobookRepository(db);
      await audio.ensureAudiobook('ab');
      await audio.updatePositionMs(bookKey: 'ab', positionMs: 123456);

      await resetBookReadingState(db: db, bookKey: 'ab', title: 'Book ab');

      expect(await audio.readPositionMs('ab'), 0);
    });

    test('位置写回开头且 updatedAt 严格变新，读完标记清空，统计默认不动', () async {
      final FushiDatabase db = await _openDb();
      final String uid = await _insertBook(db, 'bk');
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value(uid),
          sectionIndex: const Value(2),
          normCharOffset: const Value(4200),
          charOffset: const Value(88),
          updatedAt: const Value(5000),
        ),
      );
      await db.setEpubBookCompleted('bk', DateTime(2026, 9, 2));
      await db.upsertStudySegment(
        _seg('s1', kind: kActivityMediaBook, key: 'bk', startAt: _base),
      );

      await resetBookReadingState(
        db: db,
        bookKey: 'bk',
        title: 'Book bk',
        nowMs: 4000, // 墙钟落后于旧行：仍须严格新于旧行
      );

      final ReaderPositionRow? pos = await db.getReaderPosition(uid);
      expect(pos, isNotNull, reason: '不删行：删行会被同步通道从对端灌回');
      expect(pos!.sectionIndex, 0);
      expect(pos.normCharOffset, 0);
      expect(pos.charOffset, -1);
      expect(pos.updatedAt, 5001);
      expect(await db.getCompletedEpubBookKeys(), isNot(contains('bk')));
      // 书架进度：文字书 = 0（未读）。
      expect(
        computeBookProgress(
          sectionChars: const <int>[100, 100, 100],
          sectionIndex: pos.sectionIndex,
          charOffset: pos.charOffset,
          normCharOffset: pos.normCharOffset,
        ).position,
        0,
      );
      final Map<String, StudySegmentRow> segs = await _segments(db);
      expect(segs['s1']!.durationMs, 60000, reason: '默认不动学习记录');
      expect(segs['s1']!.chars, 100);
      expect(await db.getStudySegmentTombstones(), isEmpty);
    });

    test('从没留过位置的书不凭空造位置行（不顶进最近阅读）', () async {
      final FushiDatabase db = await _openDb();
      final String uid = await _insertBook(db, 'fresh');
      await resetBookReadingState(db: db, bookKey: 'fresh', title: 'x');
      expect(await db.getReaderPosition(uid), isNull);
    });

    test('lastSession：只把最近一次会话的段写零（LWW 新戳），更早的会话与碑都不动', () async {
      final FushiDatabase db = await _openDb();
      await _insertBook(db, 'bk');
      await db.upsertStudySegment(
        _seg('old', kind: kActivityMediaBook, key: 'bk', startAt: _base),
      );
      // 4 小时后误点开的一次（两段相邻 → 同一会话）。
      await db.upsertStudySegment(
        _seg(
          'new1',
          kind: kActivityMediaBook,
          key: 'bk',
          startAt: _base + 4 * _hour,
        ),
      );
      await db.upsertStudySegment(
        _seg(
          'new2',
          kind: kActivityMediaBook,
          key: 'bk',
          startAt: _base + 4 * _hour + 120000,
        ),
      );
      // 别的书的更晚会话不该被挑中。
      await db.upsertStudySegment(
        _seg(
          'other',
          kind: kActivityMediaBook,
          key: 'zz',
          startAt: _base + 6 * _hour,
        ),
      );

      await resetBookReadingState(
        db: db,
        bookKey: 'bk',
        title: 'Book bk',
        records: StudyRecordResetScope.lastSession,
        nowMs: _base + 5 * _hour,
      );

      final Map<String, StudySegmentRow> segs = await _segments(db);
      expect(segs['new1']!.durationMs, 0);
      expect(segs['new1']!.chars, 0);
      expect(segs['new2']!.durationMs, 0);
      expect(
        segs['new1']!.updatedAt,
        greaterThan(_base + 4 * _hour + 60000),
        reason: '写零是新的绝对值写，经 uid LWW 同步到对端',
      );
      expect(segs['old']!.durationMs, 60000, reason: '更早的会话保留');
      expect(segs['other']!.durationMs, 60000, reason: '别的书不受影响');
      expect(
        await db.getStudySegmentTombstones(),
        isEmpty,
        reason: '撤一次会话不立按身份的墓碑（会压死整段历史）',
      );
      final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
      expect(
        latestStudySessionFor(
          facts.sessions,
          mediaKind: kActivityMediaBook,
          mediaKeys: <String>{'bk'},
        )?.segmentUids,
        <String>['old'],
      );
    });

    test('lastSession：最近一次会话早于 24 小时就不撤（误点开没入账时不误删旧阅读）', () async {
      final FushiDatabase db = await _openDb();
      await _insertBook(db, 'bk');
      await db.upsertStudySegment(
        _seg('old', kind: kActivityMediaBook, key: 'bk', startAt: _base),
      );

      final bool undone = await undoLatestStudySession(
        db,
        mediaKind: kActivityMediaBook,
        mediaKeys: <String>{'bk'},
        nowMs: _base + 60000 + kUndoLatestStudySessionWindow.inMilliseconds + 1,
      );

      expect(undone, isFalse);
      expect((await _segments(db))['old']!.durationMs, 60000);
    });

    test('all：按身份删段并立墓碑（同步安全），含配对字幕书的 SRT uid 身份', () async {
      final FushiDatabase db = await _openDb();
      await _insertBook(db, 'bk');
      await db.upsertStudySegment(
        _seg('a', kind: kActivityMediaBook, key: 'bk', startAt: _base),
      );
      await db.upsertStudySegment(
        _seg('b', kind: kActivityMediaBook, key: 'srt-uid', startAt: _base),
      );
      await db.upsertStudySegment(
        _seg('c', kind: kActivityMediaBook, key: 'zz', startAt: _base),
      );

      await resetBookReadingState(
        db: db,
        bookKey: 'bk',
        title: 'Book bk',
        extraStatKeys: <String>{'srt-uid'},
        records: StudyRecordResetScope.all,
      );

      final Map<String, StudySegmentRow> segs = await _segments(db);
      expect(segs.keys, <String>['c']);
      final Set<String> tombstoned = <String>{
        for (final StudySegmentTombstoneRow r
            in await db.getStudySegmentTombstones())
          r.mediaKey,
      };
      expect(tombstoned, containsAll(<String>['bk', 'srt-uid']));
      expect(tombstoned, isNot(contains('zz')));
    });
  });

  group('页式书（漫画 / PDF）重置后判未读', () {
    test('isPageBasedResetPosition 只认「第 0 页 + 精确锚缺席」', () {
      expect(
        isPageBasedResetPosition(sectionIndex: 0, charOffset: null),
        isTrue,
      );
      expect(isPageBasedResetPosition(sectionIndex: 0, charOffset: -1), isTrue);
      // 页式阅读器真实落库恒传 charOffset >= 0：停在第 1 页仍是「在读」。
      expect(isPageBasedResetPosition(sectionIndex: 0, charOffset: 0), isFalse);
      expect(
        isPageBasedResetPosition(sectionIndex: 3, charOffset: null),
        isFalse,
      );
    });
  });

  group('resetVideoWatchState', () {
    Future<void> insertVideo(FushiDatabase db) async {
      await db
          .into(db.videoBooks)
          .insert(
            VideoBooksCompanion.insert(
              bookUid: 'v1',
              title: 'Ep 1',
              videoPath: '/tmp/v1.mp4',
              lastPositionMs: const Value(90000),
              lastPlayedAt: const Value(123),
              completedAt: Value(DateTime(2026, 9, 1)),
            ),
          );
    }

    test('清进度 + 撤最近一次观看会话', () async {
      final FushiDatabase db = await _openDb();
      await insertVideo(db);
      await db.upsertStudySegment(
        _seg('va', kind: kActivityMediaVideo, key: 'v1', startAt: _base),
      );
      await db.upsertStudySegment(
        _seg(
          'vb',
          kind: kActivityMediaVideo,
          key: 'v1',
          startAt: _base + 5 * _hour,
        ),
      );

      await resetVideoWatchState(
        db: db,
        repo: VideoBookRepository(db),
        bookUid: 'v1',
        title: 'Ep 1',
        records: StudyRecordResetScope.lastSession,
        nowMs: _base + 6 * _hour,
      );

      final VideoBookRow row = await (db.select(
        db.videoBooks,
      )..where((t) => t.bookUid.equals('v1'))).getSingle();
      expect(row.lastPositionMs, 0);
      expect(row.lastPlayedAt, isNull);
      expect(row.completedAt, isNull);
      final Map<String, StudySegmentRow> segs = await _segments(db);
      expect(segs['vb']!.durationMs, 0);
      expect(segs['va']!.durationMs, 60000);
    });

    test('all：删段 + 立墓碑；keep：统计不动', () async {
      final FushiDatabase db = await _openDb();
      await insertVideo(db);
      await db.upsertStudySegment(
        _seg('va', kind: kActivityMediaVideo, key: 'v1', startAt: _base),
      );
      await resetVideoWatchState(
        db: db,
        repo: VideoBookRepository(db),
        bookUid: 'v1',
        title: 'Ep 1',
      );
      expect((await _segments(db))['va']!.durationMs, 60000);

      await resetVideoWatchState(
        db: db,
        repo: VideoBookRepository(db),
        bookUid: 'v1',
        title: 'Ep 1',
        records: StudyRecordResetScope.all,
      );
      expect(await _segments(db), isEmpty);
      expect(
        (await db.getStudySegmentTombstones()).map((r) => r.mediaKey),
        contains('v1'),
      );
    });
  });
}
