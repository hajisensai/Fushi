import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

VideoBooksCompanion _book() => const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('Sample'),
      videoPath: Value('/abs/sample.mp4'),
      subtitleFormat: Value('srt'),
    );

void main() {
  group('VideoBooks table', () {
    test('upsert and retrieve by bookUid', () async {
      final db = await _openDb();
      await db.upsertVideoBook(_book());
      final row = await db.getVideoBookByBookUid('video/1');
      expect(row, isNotNull);
      expect(row!.title, 'Sample');
      expect(row.lastPositionMs, 0);
    });

    test('updateVideoBookPosition writes through', () async {
      final db = await _openDb();
      await db.upsertVideoBook(_book());
      await db.updateVideoBookPosition('video/1', 12345);
      final row = await db.getVideoBookByBookUid('video/1');
      expect(row!.lastPositionMs, 12345);
    });

    test('upsert with same bookUid updates in place (no duplicate row)',
        () async {
      final db = await _openDb();
      await db.upsertVideoBook(_book());
      await db.upsertVideoBook(const VideoBooksCompanion(
        bookUid: Value('video/1'),
        title: Value('Updated'),
        videoPath: Value('/abs/sample2.mp4'),
        lastPositionMs: Value(999),
      ));
      final row = await db.getVideoBookByBookUid('video/1');
      expect(row!.title, 'Updated');
      expect(row.videoPath, '/abs/sample2.mp4');
      expect(row.lastPositionMs, 999);
      final all = await db.select(db.videoBooks).get();
      expect(all, hasLength(1));
    });
  });

  // BUG-793：视频库页据此 Drift `.watch()` 流在任意导入路径落库后自动刷新。
  group('watchVideoBookUids', () {
    test('emits inserted uid when a video is added', () async {
      final db = await _openDb();
      final emissions = <List<String>>[];
      final sub = db.watchVideoBookUids().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emissions.last, isEmpty, reason: '初始快照：空库');

      await db.upsertVideoBook(_book());
      await pumpEventQueue();
      expect(emissions.last, contains('video/1'),
          reason: '插入后集合应含新导入的 uid（库页据此刷新）');
    });

    test('membership unchanged on position-only update (dedup source)',
        () async {
      final db = await _openDb();
      await db.upsertVideoBook(_book());
      final emissions = <List<String>>[];
      final sub = db.watchVideoBookUids().listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emissions.last, <String>['video/1']);

      // 纯列更新（进度回写）：即便 Drift 表级失效再发流，集合仍是 {video/1}，
      // 消费方据此去重不触发无谓刷新（避免自愈写回→重刷环）。
      await db.updateVideoBookPosition('video/1', 5000);
      await pumpEventQueue();
      expect(
        emissions
            .every((List<String> e) => e.length == 1 && e.first == 'video/1'),
        isTrue,
        reason: '进度更新不改变 uid 集合',
      );
    });
  });
}
