// BUG-4709 / 拍板台 35YfcYO-zR：IPTV 导入一万多条后批量删除「像没删」——其实是
// 删得极慢且界面没反馈。根因是删除链上几处逐条 N+1：
// ① 「同时删除统计」逐条 getByBookUid + 逐条一个事务（每条十来条查询）；
// ② 蓝光特典墓碑规划逐条 getVideoBookByBookUid；
// ③ 「从所有设备删除」的同步墓碑逐条独立提交；
// ④ 回收阶段每本各把全部幸存引用路径 canonicalize 一遍。
//
// 钉子：
// - 整条删除链的 SQL 语句数与删除条数无关（N+1 回归即红）；
// - 批量统计删除与逐条删除结果一致，且歧义复核 / 按集偏好 / 墓碑判据不变；
// - 删除进度按阶段回报，回收阶段走到 total；
// - 批量回收 app 副本的护栏语义不变，逐本回报进度。
import 'dart:io';

import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        BatchedStatements,
        QueryExecutor,
        QueryInterceptor,
        Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:path/path.dart' as p;

/// 数所有落到 SQLite 的语句（batch 算一次）。
class _StatementCounter extends QueryInterceptor {
  bool armed = false;
  int statements = 0;

  void _hit() {
    if (armed) statements++;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _hit();
    return executor.runSelect(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _hit();
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _hit();
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _hit();
    return executor.runDelete(statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _hit();
    return executor.runCustom(statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    _hit();
    return executor.runBatched(statements);
  }
}

Future<void> _seedVideo(
  FushiDatabase db, {
  required String bookUid,
  required String title,
  List<String> watchTitles = const <String>[],
}) async {
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: bookUid,
      title: title,
      videoPath: 'D:/Videos/$bookUid.mkv',
    ),
  );
  await db.upsertStudySegment(
    StudySegmentsCompanion.insert(
      uid: FushiDatabase.newStudySegmentUid(),
      deviceId: 'dev-test',
      mediaKind: kActivityMediaVideo,
      mediaKey: bookUid,
      title: title,
      startAt: 1000,
      endAt: 61000,
      dateKey: '2026-09-16',
      hour: 10,
      updatedAt: 61000,
    ),
  );
  for (final String watchTitle in <String>[title, ...watchTitles]) {
    await _insertWatch(db, title: watchTitle, bookUid: bookUid);
  }
  await db.addLookupCount(
    bookKey: bookUid,
    title: title,
    sourceType: FushiDatabase.statSourceVideo,
    dateKey: '2026-09-16',
  );
  await db.setPref(videoWatchCoveragePrefKey(bookUid), '{}');
}

Future<void> _insertWatch(
  FushiDatabase db, {
  required String title,
  required String? bookUid,
}) => db
    .into(db.videoWatchStatistics)
    .insert(
      VideoWatchStatisticsCompanion.insert(
        title: title,
        bookUid: Value(bookUid),
        dateKey: '2026-09-16',
        subtitleChars: 120,
        watchTimeMs: 60000,
        lastModified: 1,
      ),
    );

/// 统计删除涉及的全部表的可比快照（墓碑戳是时间，不比）。
Future<Map<String, List<String>>> _statsSnapshot(FushiDatabase db) async {
  List<String> sorted(Iterable<String> xs) => xs.toList()..sort();
  return <String, List<String>>{
    'segments': sorted(
      (await db.select(db.studySegments).get()).map(
        (StudySegmentRow r) => r.mediaKey,
      ),
    ),
    'segmentTombstones': sorted(
      (await db.select(db.studySegmentTombstones).get()).map(
        (StudySegmentTombstoneRow r) => '${r.mediaKind}|${r.mediaKey}',
      ),
    ),
    'statTombstones': sorted(
      (await db.select(db.statisticsTombstones).get()).map(
        (StatisticsTombstoneRow r) => '${r.sourceType}|${r.title}',
      ),
    ),
    'watch': sorted(
      (await db.select(db.videoWatchStatistics).get()).map(
        (VideoWatchStatisticRow r) => '${r.bookUid}|${r.title}',
      ),
    ),
    'counters': sorted(
      (await db.select(db.lookupMiningCounters).get()).map(
        (LookupMiningCounterRow r) => '${r.sourceType}|${r.bookKey}|${r.title}',
      ),
    ),
    'coveragePrefs': sorted(
      (await db.select(db.preferences).get())
          .map((PreferenceRow r) => r.key)
          .where((String k) => k.startsWith(kVideoWatchCoveragePrefPrefix)),
    ),
  };
}

/// 歧义复核的完整场景：改名历史 title、两条同名一起删、同名幸存者、别人也在用的
/// 历史 title、无身份遗留行、按集覆盖键与邻名 uid 的按集键。
Future<FushiDatabase> _ambiguityFixture() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await _seedVideo(
    db,
    bookUid: 'video/a',
    title: 'A',
    watchTitles: <String>['A-old', 'Shared-old'],
  );
  await _seedVideo(db, bookUid: 'video/b', title: 'S');
  await _seedVideo(db, bookUid: 'video/c', title: 'S');
  // 幸存者：也挂着 'Shared-old' 的身份行 → 该 title 歧义，不扫不立碑。
  await _seedVideo(
    db,
    bookUid: 'video/e',
    title: 'E',
    watchTitles: <String>['Shared-old'],
  );
  // 无身份遗留行：'A-old' 无歧义（可扫），'S' 歧义（库表同名 2 条，不可扫）。
  await _insertWatch(db, title: 'A-old', bookUid: null);
  await _insertWatch(db, title: 'S', bookUid: '');
  await db.addLookupCount(
    title: 'A-old',
    sourceType: FushiDatabase.statSourceVideo,
    dateKey: '2026-09-16',
  );
  await db.setPref('${videoWatchCoveragePrefKey('video/a')}#ep2', '{}');
  // 邻名 uid（video/ab 不删）的按集键不能被 video/a 的前缀误伤。
  await db.setPref('${videoWatchCoveragePrefKey('video/ab')}#ep1', '{}');
  return db;
}

const List<VideoStatisticsIdentity> _targets = <VideoStatisticsIdentity>[
  (title: 'A', bookUid: 'video/a'),
  (title: 'S', bookUid: 'video/b'),
  (title: 'S', bookUid: 'video/c'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('整条删除链（删统计 + 同步墓碑）的 SQL 语句数与删除条数无关', () async {
    Future<int> statementsFor(int n) async {
      final _StatementCounter counter = _StatementCounter();
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory().interceptWith(counter),
      );
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final List<String> uids = <String>[for (int i = 0; i < n; i++) 'v$i'];
      for (final String uid in uids) {
        await _seedVideo(db, bookUid: uid, title: 'T-$uid');
      }
      await _seedVideo(db, bookUid: 'keep', title: 'Keep');
      counter.armed = true;
      final VideoLibraryDeleteResult result =
          await deleteVideoBooksWithDecision(
            repo: repo,
            database: db,
            pipeline: null,
            bookUids: uids,
            decision: const DeleteDecision(
              scope: DeleteScope.syncEverywhere,
              deleteStatistics: true,
            ),
            compactDatabase: false,
          );
      counter.armed = false;
      expect(result.deleted, n);
      expect(result.failed, isEmpty);
      expect(await repo.getByBookUid('keep'), isNotNull);
      expect(
        (await db.getSyncDeletionTombstones())
            .map((SyncDeletionTombstoneRow r) => r.itemKey)
            .toSet(),
        uids.toSet(),
        reason: '同步墓碑一条不少',
      );
      expect(
        (await db.select(db.studySegments).get()).map(
          (StudySegmentRow r) => r.mediaKey,
        ),
        <String>['keep'],
        reason: '统计确实删了、只删了目标',
      );
      return counter.statements;
    }

    final int one = await statementsFor(1);
    final int many = await statementsFor(60);
    expect(many, one, reason: '删 60 条与删 1 条的语句数必须相同（原来每条十几条 = 一万条十几万条）');
  });

  for (final bool includeUnattributed in <bool>[false, true]) {
    test('批量统计删除 == 逐条删除（includeUnattributed: $includeUnattributed）', () async {
      final FushiDatabase sequential = await _ambiguityFixture();
      for (final VideoStatisticsIdentity target in _targets) {
        await sequential.deleteVideoStatisticsForIdentity(
          title: target.title,
          bookUid: target.bookUid,
          includeUnattributed: includeUnattributed,
        );
      }
      final FushiDatabase batched = await _ambiguityFixture();
      await batched.deleteVideoStatisticsForIdentities(
        _targets,
        includeUnattributed: includeUnattributed,
      );
      final Map<String, List<String>> snapshot = await _statsSnapshot(batched);
      expect(snapshot, await _statsSnapshot(sequential));

      // 结果本身也钉死，不只是两条路径互相一致。
      expect(snapshot['segments'], <String>['video/e']);
      expect(snapshot['segmentTombstones'], <String>[
        '$kActivityMediaVideo|video/a',
        '$kActivityMediaVideo|video/b',
        '$kActivityMediaVideo|video/c',
      ]);
      expect(snapshot['statTombstones'], <String>[
        '${FushiDatabase.statSourceVideo}|A',
        '${FushiDatabase.statSourceVideo}|A-old',
        '${FushiDatabase.statSourceVideo}|S',
      ], reason: '自身 title 恒立碑；无歧义历史 title 立碑；别人也在用的 Shared-old 不立');
      expect(snapshot['coveragePrefs'], <String>[
        '${videoWatchCoveragePrefKey('video/ab')}#ep1',
        videoWatchCoveragePrefKey('video/e'),
      ]);
      expect(
        snapshot['watch'],
        includeUnattributed
            ? <String>['|S', 'video/e|E', 'video/e|Shared-old']
            : <String>['null|A-old', '|S', 'video/e|E', 'video/e|Shared-old'],
        reason: '歧义 title S 的无身份行任何时候都不扫',
      );
      expect(snapshot['counters'], <String>[
        if (!includeUnattributed) '${FushiDatabase.statSourceVideo}||A-old',
        '${FushiDatabase.statSourceVideo}|video/e|E',
      ]);
    });
  }

  test('删除进度：先报删行阶段，回收阶段单调推进到 total', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    final List<String> uids = <String>[for (int i = 0; i < 5; i++) 'v$i'];
    for (final String uid in uids) {
      await _seedVideo(db, bookUid: uid, title: uid);
    }
    final List<VideoLibraryDeleteProgress> events =
        <VideoLibraryDeleteProgress>[];
    await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: uids,
      decision: const DeleteDecision(scope: DeleteScope.keepLocalOnly),
      compactDatabase: false,
      onProgress: events.add,
    );
    expect(events.first.stage, VideoLibraryDeleteStage.removingEntries);
    final List<VideoLibraryDeleteProgress> cleanup =
        <VideoLibraryDeleteProgress>[
          for (final VideoLibraryDeleteProgress e in events)
            if (e.stage == VideoLibraryDeleteStage.cleaningUp) e,
        ];
    expect(cleanup, isNotEmpty);
    expect(cleanup.last.done, cleanup.last.total);
    expect(cleanup.last.total, uids.length * 2);
    for (int i = 1; i < cleanup.length; i++) {
      expect(cleanup[i].done, greaterThanOrEqualTo(cleanup[i - 1].done));
    }
  });

  test('批量回收 app 副本：护栏语义与逐本一致，逐本回报进度', () async {
    final Directory root = await Directory.systemTemp.createTemp('bug4709_');
    addTearDown(() => root.delete(recursive: true));
    final Directory covers = await Directory(
      p.join(root.path, 'covers'),
    ).create();
    final Directory subtitles = await Directory(
      p.join(root.path, 'subs'),
    ).create();
    Future<String> touch(Directory dir, String name) async =>
        (await File(p.join(dir.path, name)).writeAsString('x')).path;
    final String coverA = await touch(covers, 'a.jpg');
    final String coverShared = await touch(covers, 'shared.jpg');
    final String subA = await touch(subtitles, 'a.srt');
    final String subB2 = await touch(subtitles, 'b2.srt');
    final String outside = await touch(root, 'user.srt');

    final List<int> progress = <int>[];
    final int removed = await VideoStorage.deleteBooksAssets(
      books: <DeletedVideoAssetPaths>[
        (coverPath: coverA, subtitlePath: subA, secondarySubtitlePath: null),
        (
          coverPath: coverShared,
          subtitlePath: outside,
          secondarySubtitlePath: subB2,
        ),
        (coverPath: null, subtitlePath: null, secondarySubtitlePath: null),
      ],
      stillReferencedCoverPaths: <String>[coverShared],
      stillReferencedSubtitlePaths: const <String>[],
      coversDirectory: covers,
      subtitlesDirectory: subtitles,
      onBookDone: progress.add,
    );

    expect(removed, 3);
    expect(File(coverA).existsSync(), isFalse);
    expect(File(subA).existsSync(), isFalse);
    expect(File(subB2).existsSync(), isFalse, reason: '副字幕副本也回收');
    expect(File(coverShared).existsSync(), isTrue, reason: '幸存行还引用');
    expect(File(outside).existsSync(), isTrue, reason: 'app 目录外的文件绝不碰');
    expect(progress, <int>[1, 2, 3]);
  });
}
