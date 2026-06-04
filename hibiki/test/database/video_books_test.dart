import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
}
