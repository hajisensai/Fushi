import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

/// 数落到 video_books 上的 SELECT：只读 `book_uid` 的 vs 整行读的。
class _UidSelectCounter extends QueryInterceptor {
  int uidSelects = 0;
  int fullRowSelects = 0;

  void reset() {
    uidSelects = 0;
    fullRowSelects = 0;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('FROM "video_books"')) {
      if (statement.contains('video_path')) {
        fullRowSelects++;
      } else {
        uidSelects++;
      }
    }
    return executor.runSelect(statement, args);
  }
}

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
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
      await db.updateVideoBookPosition('video/1', 12345, playedAt: 1700);
      final row = await db.getVideoBookByBookUid('video/1');
      expect(row!.lastPositionMs, 12345);
    });

    test(
      'upsert with same bookUid updates in place (no duplicate row)',
      () async {
        final db = await _openDb();
        await db.upsertVideoBook(_book());
        await db.upsertVideoBook(
          const VideoBooksCompanion(
            bookUid: Value('video/1'),
            title: Value('Updated'),
            videoPath: Value('/abs/sample2.mp4'),
            lastPositionMs: Value(999),
          ),
        );
        final row = await db.getVideoBookByBookUid('video/1');
        expect(row!.title, 'Updated');
        expect(row.videoPath, '/abs/sample2.mp4');
        expect(row.lastPositionMs, 999);
        final all = await db.select(db.videoBooks).get();
        expect(all, hasLength(1));
      },
    );
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
      expect(
        emissions.last,
        contains('video/1'),
        reason: '插入后集合应含新导入的 uid（库页据此刷新）',
      );
    });

    test(
      'membership unchanged on position-only update (dedup source)',
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
        await db.updateVideoBookPosition('video/1', 5000, playedAt: 1700);
        await pumpEventQueue();
        expect(
          emissions.every(
            (List<String> e) => e.length == 1 && e.first == 'video/1',
          ),
          isTrue,
          reason: '进度更新不改变 uid 集合',
        );
      },
    );

    test(
      'notifyVideoLibraryChanged emits without changing business columns',
      () async {
        final db = await _openDb();
        await db.upsertVideoBook(_book());
        final emissions = <List<String>>[];
        final sub = db.watchVideoBookUids().listen(emissions.add);
        addTearDown(sub.cancel);
        await pumpEventQueue();
        expect(emissions, hasLength(1));

        final before = await db.getVideoBookByBookUid('video/1');
        db.notifyVideoLibraryChanged();
        await pumpEventQueue();

        expect(emissions, hasLength(2));
        expect(emissions.last, <String>['video/1']);
        final after = await db.getVideoBookByBookUid('video/1');
        expect(after, before, reason: '显式刷新只能发表级通知，不能借机改业务列');
      },
    );

    // gap-scanner-4：首次扫描逐条提交，每条一发表级通知；旧实现每条通知各整表读
    // 一次 video_books（N 条 = N 次整表读，且结果可能乱序到达）。
    test('连发的表级通知合并在途重查，且只选 book_uid 一列', () async {
      final _UidSelectCounter counter = _UidSelectCounter();
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory().interceptWith(counter),
      );
      addTearDown(db.close);
      final List<List<String>> emissions = <List<String>>[];
      final StreamSubscription<List<String>> sub = db
          .watchVideoBookUids()
          .listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emissions.single, isEmpty);
      counter.reset();

      const int n = 40;
      await Future.wait(<Future<void>>[
        for (int i = 0; i < n; i++)
          db.upsertVideoBook(
            VideoBooksCompanion.insert(
              bookUid: 'video/$i',
              title: 'T$i',
              videoPath: 'D:/v/$i.mkv',
            ),
          ),
      ]);
      await pumpEventQueue();

      expect(
        counter.uidSelects,
        lessThan(n ~/ 4),
        reason: '在途期间的通知应合并（旧实现 = 每条通知一次）',
      );
      expect(counter.fullRowSelects, 0, reason: 'uid 流不该整行读 video_books');
      expect(emissions.last, hasLength(n), reason: '最后一次发出的是最终集合');
    });
  });
  // BUG-3610：库页按「观看进度变了」重读列表——uid 流刻意不管纯列更新，进度要
  // 单独的信号；封面等其余列的回写不能触发（否则自愈写回会让库页重刷成环）。
  group('watchVideoWatchProgressChanged', () {
    test(
      'baseline does not emit; position / completion / episode emit',
      () async {
        final db = await _openDb();
        await db.upsertVideoBook(_book());
        int emissions = 0;
        final sub = db.watchVideoWatchProgressChanged().listen((_) {
          emissions++;
        });
        addTearDown(sub.cancel);
        await pumpEventQueue();
        expect(emissions, 0, reason: '首次查询只登记基线，库页进页已首载');

        await db.updateVideoBookPosition('video/1', 5000, playedAt: 1700);
        await pumpEventQueue();
        expect(emissions, 1, reason: '断点变了 = 进度变了');

        await db.markVideoCompleted('video/1', DateTime(2026, 10, 19));
        await pumpEventQueue();
        expect(emissions, 2, reason: '看完标记变了');

        await db.updateVideoBookEpisode('video/1', 3);
        await pumpEventQueue();
        expect(emissions, 3, reason: '单行多集的集指针变了');
      },
    );

    test(
      'cover / subtitle writes and no-op notifications do not emit',
      () async {
        final db = await _openDb();
        await db.upsertVideoBook(_book());
        int emissions = 0;
        final sub = db.watchVideoWatchProgressChanged().listen((_) {
          emissions++;
        });
        addTearDown(sub.cancel);
        await pumpEventQueue();

        await db.updateVideoBookCover('video/1', '/abs/cover.jpg');
        await db.updateVideoBookSubtitleSource('video/1', 'embedded:0');
        db.notifyVideoLibraryChanged();
        await pumpEventQueue();
        expect(emissions, 0, reason: '非进度列的写入不改签名');

        await db.updateVideoBookPosition('video/1', 5000, playedAt: 1700);
        await db.updateVideoBookPosition('video/1', 5000, playedAt: 1700);
        await pumpEventQueue();
        expect(emissions, 1, reason: '同值重写不算变化');
      },
    );
  });
}
