import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// HBK-AUDIT-042 / BUG-5127：统计侧栏只看一本书 / 一个视频时，单媒体读路径
/// 的等值条件没有可用索引——段表只能按 `(profile_id)` 扫本 Profile 全部段，计数表、
/// 视频 legacy 行、书表的标题回退整表扫。v168 按真实 WHERE 建四条索引，段查询拆成
/// 两支全等值查询。
///
/// 这里不手写 SQL 去猜查询形态：用拦截器截下 [FushiDatabase] 的读方法**真正发出**的
/// 语句与参数，再对它们跑 `EXPLAIN QUERY PLAN`。查询形态退回成一个 OR、或索引丢了，
/// 计划就会退回 `SCAN` / 只用 `profile_id` 前缀，测试变红。
const List<String> _singleMediaIndexes = <String>[
  'idx_study_segments_profile_media',
  'idx_lookup_mining_counters_book_title',
  'idx_video_watch_statistics_title',
  'idx_epub_books_title',
];

class _SelectRecorder extends QueryInterceptor {
  bool recording = false;
  final List<(String, List<Object?>)> selects = <(String, List<Object?>)>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (recording) selects.add((statement, List<Object?>.of(args)));
    return super.runSelect(executor, statement, args);
  }
}

Future<Set<String>> _indexNames(FushiDatabase db) async => <String>{
  for (final QueryRow row
      in await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get())
    row.read<String>('name'),
};

/// 录下 [read] 发出的全部 SELECT，逐条返回其查询计划（`detail` 列用 ` / ` 连起来）。
Future<List<String>> _plansOf(
  FushiDatabase db,
  _SelectRecorder recorder,
  Future<Object?> Function() read,
) async {
  recorder
    ..selects.clear()
    ..recording = true;
  try {
    await read();
  } finally {
    recorder.recording = false;
  }
  final List<(String, List<Object?>)> captured =
      List<(String, List<Object?>)>.of(recorder.selects);
  expect(captured, isNotEmpty);
  return <String>[
    for (final (String sql, List<Object?> args) in captured)
      (await db
              .customSelect(
                'EXPLAIN QUERY PLAN $sql',
                variables: <Variable<Object>>[
                  for (final Object? a in args) Variable<Object>(a),
                ],
              )
              .get())
          .map((QueryRow r) => r.read<String>('detail'))
          .join(' / '),
  ];
}

StudySegmentsCompanion _seg(
  String uid, {
  required int profile,
  required String kind,
  required String key,
  required String title,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: 'd',
  mediaKind: kind,
  mediaKey: key,
  title: title,
  startAt: 0,
  endAt: 1,
  dateKey: '2026-11-01',
  hour: 0,
  durationMs: const Value<int>(1000),
  updatedAt: 1,
  profileId: Value<int>(profile),
);

void main() {
  test('fresh 库建好四条单媒体统计索引', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await _indexNames(db), containsAll(_singleMediaIndexes));
  });

  test('单媒体读方法发出的每条查询都按等值前缀命中索引，结果与 OR 口径逐行相同', () async {
    final _SelectRecorder recorder = _SelectRecorder();
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(recorder),
    );
    addTearDown(db.close);

    // 5000 段属于同 Profile 同域的其他书——修前单媒体段查询要逐行扫过它们。
    await db.batch((Batch b) {
      b.insertAll(db.studySegments, <StudySegmentsCompanion>[
        for (int i = 0; i < 5000; i++)
          _seg('o$i', profile: 1, kind: 'book', key: 'other$i', title: 'T$i'),
        for (int i = 0; i < 10; i++)
          _seg('k$i', profile: 1, kind: 'book', key: 'bk', title: 'Book'),
        // legacy 无身份段：同名命中，异名不命中。
        _seg('l0', profile: 1, kind: 'book', key: '', title: 'Book'),
        _seg('l1', profile: 1, kind: 'book', key: '', title: 'Other'),
        // 其他 Profile / 其他域的同键段都不属于本次范围。
        _seg('p2', profile: 2, kind: 'book', key: 'bk', title: 'Book'),
        _seg('v0', profile: 1, kind: 'video', key: 'bk', title: 'Book'),
      ]);
      b.insertAll(db.lookupMiningCounters, <LookupMiningCountersCompanion>[
        for (int i = 0; i < 5000; i++)
          LookupMiningCountersCompanion.insert(
            bookKey: Value<String>('other$i'),
            title: Value<String>('T$i'),
            sourceType: 'book',
            dateKey: '2026-11-01',
          ),
        LookupMiningCountersCompanion.insert(
          bookKey: const Value<String>('bk'),
          title: const Value<String>('Book'),
          sourceType: 'book',
          dateKey: '2026-11-01',
        ),
        LookupMiningCountersCompanion.insert(
          title: const Value<String>('Book'),
          sourceType: 'book',
          dateKey: '2026-10-01',
        ),
      ]);
    });

    final List<StudySegmentRow> segs = await db.getStudySegments(
      profileId: 1,
      mediaKind: 'book',
      mediaKey: 'bk',
      orTitle: 'Book',
    );
    expect(segs.map((StudySegmentRow r) => r.uid).toSet(), <String>{
      for (int i = 0; i < 10; i++) 'k$i',
      'l0',
    });
    expect(segs, hasLength(11), reason: '两支互斥，不重不漏');
    final List<StudySegmentRow> keyOnly = await db.getStudySegments(
      profileId: 1,
      mediaKind: 'book',
      mediaKey: 'bk',
    );
    expect(keyOnly, hasLength(10));
    final List<LookupMiningCounterRow> counters = await db
        .getLookupMiningCountersForBook(bookKey: 'bk', orTitle: 'Book');
    expect(counters, hasLength(2));

    final List<String> segPlans = await _plansOf(
      db,
      recorder,
      () => db.getStudySegments(
        profileId: 1,
        mediaKind: 'book',
        mediaKey: 'bk',
        orTitle: 'Book',
      ),
    );
    expect(segPlans, hasLength(2));
    expect(
      segPlans[0],
      contains(
        'idx_study_segments_profile_media '
        '(profile_id=? AND media_kind=? AND media_key=?)',
      ),
    );
    expect(
      segPlans[1],
      contains(
        'idx_study_segments_profile_media '
        '(profile_id=? AND media_kind=? AND media_key=? AND title=?)',
      ),
    );

    final List<String> forMediaPlans = await _plansOf(
      db,
      recorder,
      () => db.getStudySegmentsForMedia(
        mediaKind: 'book',
        mediaKey: 'bk',
        profileId: 1,
      ),
    );
    expect(
      forMediaPlans.single,
      contains(
        'idx_study_segments_profile_media '
        '(profile_id=? AND media_kind=? AND media_key=?)',
      ),
    );

    final String counterPlan = (await _plansOf(
      db,
      recorder,
      () => db.getLookupMiningCountersForBook(bookKey: 'bk', orTitle: 'Book'),
    )).single;
    expect(counterPlan, isNot(contains('SCAN')), reason: counterPlan);
    expect(
      counterPlan,
      contains(
        'idx_lookup_mining_counters_book_title (book_key=? AND title=?)',
      ),
      reason: counterPlan,
    );

    final String watchPlan = (await _plansOf(
      db,
      recorder,
      () => db.getVideoWatchStatisticsForMedia(bookUid: 'bk', orTitle: 'Book'),
    )).single;
    expect(watchPlan, isNot(contains('SCAN')), reason: watchPlan);
    expect(
      watchPlan,
      contains('idx_video_watch_statistics_title (title=?)'),
      reason: watchPlan,
    );

    final List<String> bookPlans = await _plansOf(
      db,
      recorder,
      () => db.getEpubBookMetas(matchingBookKey: 'bk', orTitle: 'Book'),
    );
    for (final String plan in bookPlans) {
      expect(plan, isNot(contains('SCAN epub_books')), reason: plan);
      expect(plan, contains('idx_epub_books_title'), reason: plan);
    }
  });

  test('缺这四条索引的存量库（升级前一档）打开后补齐，数据不动、重开幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync('stat_media_idx');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File file = File('${dir.path}/fushi.db');

    final FushiDatabase seeded = FushiDatabase.forTesting(NativeDatabase(file));
    await seeded.batch((Batch b) {
      b.insertAll(seeded.studySegments, <StudySegmentsCompanion>[
        _seg('a', profile: 1, kind: 'book', key: 'bk', title: 'Book'),
        _seg('b', profile: 1, kind: 'book', key: '', title: 'Book'),
      ]);
    });
    for (final String name in _singleMediaIndexes) {
      await seeded.customStatement('DROP INDEX IF EXISTS $name');
    }
    expect(
      (await _indexNames(seeded)).intersection(_singleMediaIndexes.toSet()),
      isEmpty,
    );
    await seeded.customStatement(
      'PRAGMA user_version = ${kFushiDbSchemaVersion - 1}',
    );
    await seeded.close();

    final FushiDatabase upgraded = FushiDatabase.forTesting(
      NativeDatabase(file),
    );
    try {
      expect(await _indexNames(upgraded), containsAll(_singleMediaIndexes));
      expect(
        (await upgraded.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        kFushiDbSchemaVersion,
      );
      expect(
        await upgraded.getStudySegments(
          profileId: 1,
          mediaKind: 'book',
          mediaKey: 'bk',
          orTitle: 'Book',
        ),
        hasLength(2),
      );
    } finally {
      await upgraded.close();
    }

    final FushiDatabase reopened = FushiDatabase.forTesting(
      NativeDatabase(file),
    );
    addTearDown(reopened.close);
    expect(await _indexNames(reopened), containsAll(_singleMediaIndexes));
  });
}
