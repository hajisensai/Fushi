/// 删除确认框「同时删除统计数据」（视频侧）的落地：默认不勾时统计原样保留，勾了
/// 才把这条视频的 study_segments 事实 / legacy 观看行 / 查词计数删掉并立碑防复活。
///
/// 勾选框本身的渲染与默认值在 `test/sync/delete_local_files_dialog_test.dart` 里断言，
/// 本文件只钉「勾了之后数据库里到底发生了什么」。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

/// 一行视频 + 它攒下的三类统计（v92 事实表 / legacy 观看行 / 查词计数）。
Future<void> _seedVideoWithStats(
  FushiDatabase db,
  VideoBookRepository repo, {
  required String bookUid,
  required String title,
}) async {
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value('/lib/$title.mkv'),
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
  await db.into(db.videoWatchStatistics).insert(
        VideoWatchStatisticsCompanion.insert(
          title: title,
          bookUid: Value(bookUid),
          dateKey: '2026-09-16',
          subtitleChars: 120,
          watchTimeMs: 60000,
          lastModified: 1,
        ),
      );
  await db.addLookupCount(
    bookKey: bookUid,
    title: title,
    sourceType: FushiDatabase.statSourceVideo,
    dateKey: '2026-09-16',
  );
}

Future<List<StudySegmentRow>> _segmentsOf(
  FushiDatabase db,
  String mediaKey,
) async =>
    (await db.select(db.studySegments).get())
        .where((StudySegmentRow row) => row.mediaKey == mediaKey)
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认不勾 → 删了视频，统计一行不动', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    await _seedVideoWithStats(db, repo, bookUid: 'video/a', title: 'A');

    await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: <String>['video/a'],
      decision: const DeleteDecision(scope: DeleteScope.keepLocalOnly),
      compactDatabase: false,
    );

    expect(await repo.getByBookUid('video/a'), isNull, reason: '条目确实删了');
    expect(
      await _segmentsOf(db, 'video/a'),
      hasLength(1),
      reason: '统计是另一类事实：没勾就一行都不能动',
    );
    expect(await db.select(db.videoWatchStatistics).get(), hasLength(1));
  });

  test('勾了 → 这条视频的三类统计都删掉，并立碑防同步复活', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    await _seedVideoWithStats(db, repo, bookUid: 'video/a', title: 'A');

    await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: <String>['video/a'],
      decision: const DeleteDecision(
        scope: DeleteScope.keepLocalOnly,
        deleteStatistics: true,
      ),
      compactDatabase: false,
    );

    expect(await _segmentsOf(db, 'video/a'), isEmpty);
    expect(await db.select(db.videoWatchStatistics).get(), isEmpty);
    expect(
      (await db.select(db.lookupMiningCounters).get())
          .where((LookupMiningCounterRow r) => r.bookKey == 'video/a'),
      isEmpty,
    );
    // 不立碑的话，下一轮聚合同步会把对端还留着的段整批灌回来（BUG-2215）。
    expect(
      (await db.select(db.studySegmentTombstones).get()).any(
        (StudySegmentTombstoneRow row) =>
            row.mediaKind == kActivityMediaVideo && row.mediaKey == 'video/a',
      ),
      isTrue,
      reason: '统计删除必须按媒体身份立碑',
    );
  });

  test('勾了只删被删那几条的统计，库里别的视频照旧', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    await _seedVideoWithStats(db, repo, bookUid: 'video/a', title: 'A');
    await _seedVideoWithStats(db, repo, bookUid: 'video/b', title: 'B');

    await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: <String>['video/a'],
      decision: const DeleteDecision(
        scope: DeleteScope.keepLocalOnly,
        deleteStatistics: true,
      ),
      compactDatabase: false,
    );

    expect(await _segmentsOf(db, 'video/a'), isEmpty);
    expect(await _segmentsOf(db, 'video/b'), hasLength(1));
    expect(await repo.getByBookUid('video/b'), isNotNull);
  });
}
