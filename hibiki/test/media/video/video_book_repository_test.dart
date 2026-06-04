import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  test('saveVideoBook + saveCues + getByBookUid + loadCues round-trips',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);

    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('T'),
      videoPath: Value('/v.mp4'),
    ));
    final cue = AudioCue()
      ..bookUid = 'video/1'
      ..chapterHref = 'video://default'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'hello'
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    await repo.saveCues(bookUid: 'video/1', cues: [cue]);

    final row = await repo.getByBookUid('video/1');
    expect(row!.title, 'T');
    final cues = await repo.loadCues('video/1');
    expect(cues, hasLength(1));
    expect(cues.first.text, 'hello');

    await repo.updatePosition('video/1', 5000);
    final row2 = await repo.getByBookUid('video/1');
    expect(row2!.lastPositionMs, 5000);
  });
}
