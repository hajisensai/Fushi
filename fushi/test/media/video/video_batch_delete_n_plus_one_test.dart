// BUG-4748 / 拍板台 35YfcYO-zR：IPTV 导入一万多条后批量删除「像没删」——其实是
// 删得极慢且界面没反馈。根因是删除链上几处逐条 N+1：
// ① 「同时删除统计」逐条 getByBookUid + 逐条一个事务（每条十来条查询）；
// ② 蓝光特典墓碑规划逐条 getVideoBookByBookUid；
// ③ 「从所有设备删除」的同步墓碑逐条独立提交；
// ④ 回收阶段每本各把全部幸存引用路径 canonicalize 一遍。
//
// 钉子：
// - 整条删除链的 SQL 语句数与删除条数无关（N+1 回归即红）；
// - 批量统计删除的结果逐项钉死（歧义复核 / 按集偏好 / 墓碑判据不变）；
// - 删除进度按阶段回报，回收阶段走到 total；勾了删本地文件时原件删除也计入，
//   最后一个文件删完才报满，之后压缩数据库报不定态的 compacting；
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
  String? videoPath,
}) async {
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: bookUid,
      title: title,
      videoPath: videoPath ?? 'D:/Videos/$bookUid.mkv',
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
  // (book_uid, date_key) 唯一：同一身份的每个历史 title 落在不同的日子。
  final List<String> titles = <String>[title, ...watchTitles];
  for (int i = 0; i < titles.length; i++) {
    await _insertWatch(
      db,
      title: titles[i],
      bookUid: bookUid,
      dateKey: '2026-09-${10 + i}',
    );
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
  String dateKey = '2026-09-16',
}) => db
    .into(db.videoWatchStatistics)
    .insert(
      VideoWatchStatisticsCompanion.insert(
        title: title,
        bookUid: Value(bookUid),
        dateKey: dateKey,
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
    // 注意：单条入口 deleteVideoStatisticsForIdentity 现在委托给批量版，两条
    // 路径互相一致只说明入口接线对；语义锁在下方逐项钉死的结果上（按原逐条算法
    // 在这份 fixture 上推演得出）。
    test('批量统计删除：单条入口与批量入口一致，结果逐项钉死'
        '（includeUnattributed: $includeUnattributed）', () async {
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
            ? <String>['video/e|E', 'video/e|Shared-old', '|S']
            : <String>['null|A-old', 'video/e|E', 'video/e|Shared-old', '|S'],
        reason: '歧义 title S 的无身份行任何时候都不扫',
      );
      expect(snapshot['counters'], <String>[
        '${FushiDatabase.statSourceVideo}|video/e|E',
        if (!includeUnattributed) '${FushiDatabase.statSourceVideo}||A-old',
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

  test('删除进度：勾了删本地文件时原件删除计入总数，删完才满，压缩阶段不定态', () async {
    final Directory root = await Directory.systemTemp.createTemp('bug4748_lf_');
    addTearDown(() => root.delete(recursive: true));
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    final List<String> uids = <String>[for (int i = 0; i < 4; i++) 'lf$i'];
    final List<String> files = <String>[];
    for (final String uid in uids) {
      final String video = p.join(root.path, '$uid.mkv');
      await File(video).writeAsString('v');
      await File(p.join(root.path, '$uid.ja.srt')).writeAsString('s');
      files
        ..add(video)
        ..add(p.join(root.path, '$uid.ja.srt'));
      await _seedVideo(db, bookUid: uid, title: uid, videoPath: video);
    }
    final List<VideoLibraryDeleteProgress> events =
        <VideoLibraryDeleteProgress>[];
    // 每个回收事件发出时磁盘上还剩几个文件：报满的那一刻必须已经删完。
    final List<int> remainingAtEvent = <int>[];
    final VideoLibraryDeleteResult result = await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: uids,
      decision: const DeleteDecision(
        scope: DeleteScope.keepLocalOnly,
        deleteLocalFiles: true,
      ),
      onProgress: (VideoLibraryDeleteProgress e) {
        events.add(e);
        remainingAtEvent.add(
          files.where((String f) => File(f).existsSync()).length,
        );
      },
    );
    expect(result.deleted, uids.length);
    for (final String f in files) {
      expect(File(f).existsSync(), isFalse, reason: f);
    }
    expect(events.first.stage, VideoLibraryDeleteStage.removingEntries);
    expect(
      events.last.stage,
      VideoLibraryDeleteStage.compacting,
      reason: '压缩数据库排在最后，切回不定态',
    );
    final List<int> cleanupIdx = <int>[
      for (int i = 0; i < events.length; i++)
        if (events[i].stage == VideoLibraryDeleteStage.cleaningUp) i,
    ];
    expect(cleanupIdx, isNotEmpty);
    final int total = events[cleanupIdx.first].total;
    expect(total, uids.length * 4, reason: '回收两步 + sidecar 扫描与原件删除两步');
    for (int k = 1; k < cleanupIdx.length; k++) {
      expect(
        events[cleanupIdx[k]].done,
        greaterThanOrEqualTo(events[cleanupIdx[k - 1]].done),
      );
      expect(events[cleanupIdx[k]].total, total);
    }
    expect(events[cleanupIdx.last].done, total);
    final int firstFull = cleanupIdx.firstWhere(
      (int i) => events[i].done >= total,
    );
    expect(
      remainingAtEvent[firstFull],
      0,
      reason: '原件还没删完进度就到 100% = 对话框停在满格干等',
    );
    for (final int i in cleanupIdx) {
      if (events[i].done < total) continue;
      expect(remainingAtEvent[i], 0);
    }
    expect(
      remainingAtEvent[cleanupIdx.first],
      files.length,
      reason: '回收阶段开始时原件都还在',
    );
  });

  test('批量回收 app 副本：护栏语义与逐本一致，逐本回报进度', () async {
    final Directory root = await Directory.systemTemp.createTemp('bug4748_');
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
