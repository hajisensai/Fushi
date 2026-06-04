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
  });
}
