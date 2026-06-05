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

  test('listAll returns all video books', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
        bookUid: Value('video/a'),
        title: Value('A'),
        videoPath: Value('/a.mp4')));
    await repo.saveVideoBook(const VideoBooksCompanion(
        bookUid: Value('video/b'),
        title: Value('B'),
        videoPath: Value('/b.mp4')));
    final all = await repo.listAll();
    expect(all, hasLength(2));
    expect(all.map((e) => e.bookUid), containsAll(['video/a', 'video/b']));
  });

  test('updatePlaylistJson round-trips per-episode positions', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/playlist/x'),
      title: Value('PL'),
      videoPath: Value('/e0.mkv'),
      playlistJson: Value('[]'),
    ));

    const String updated = '[{"title":"e0","path":"/e0.mkv","positionMs":8000},'
        '{"title":"e1","path":"/e1.mkv","positionMs":3000}]';
    await repo.updatePlaylistJson('video/playlist/x', updated);

    final row = await repo.getByBookUid('video/playlist/x');
    expect(row!.playlistJson, updated);
  });

  test('delete removes the video book and its cues (idempotent)', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);

    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/del'),
      title: Value('Del'),
      videoPath: Value('/del.mkv'),
    ));
    final cue = AudioCue()
      ..bookUid = 'video/del'
      ..chapterHref = 'video://default'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'x'
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    await repo.saveCues(bookUid: 'video/del', cues: [cue]);

    // A second book must survive the targeted delete.
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/keep'),
      title: Value('Keep'),
      videoPath: Value('/keep.mkv'),
    ));

    await repo.delete('video/del');

    expect(await repo.getByBookUid('video/del'), isNull);
    expect(await repo.loadCues('video/del'), isEmpty);
    expect((await repo.getByBookUid('video/keep'))!.title, 'Keep');

    // Idempotent: deleting again (and an unknown uid) does not throw.
    await repo.delete('video/del');
    await repo.delete('video/never-existed');
    expect(await repo.listAll(), hasLength(1));
  });

  test('per-episode position survives a playlistJson round-trip via repo',
      () async {
    // Mirrors the exit-flush path: VideoHibikiPage._persistPosition encodes the
    // updated _episodes back to playlistJson; on re-open _init reads
    // entry.positionMs and seeks there. This locks the persistence half.
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/playlist/p'),
      title: Value('PL'),
      videoPath: Value('/e0.mkv'),
      playlistJson: Value('[{"title":"e0","path":"/e0.mkv","positionMs":0},'
          '{"title":"e1","path":"/e1.mkv","positionMs":0}]'),
    ));

    // Simulate the exit flush of episode 1 at 42_500ms.
    const String flushed = '[{"title":"e0","path":"/e0.mkv","positionMs":0},'
        '{"title":"e1","path":"/e1.mkv","positionMs":42500}]';
    await repo.updatePlaylistJson('video/playlist/p', flushed);

    expect(
        (await repo.getByBookUid('video/playlist/p'))!.playlistJson, flushed);
  });

  test('updateDelayMs round-trips the A/V delay', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/d'),
      title: Value('D'),
      videoPath: Value('/d.mp4'),
    ));

    // Default is 0; negative and positive both persist.
    final row0 = await repo.getByBookUid('video/d');
    expect(row0!.delayMs, 0);

    await repo.updateDelayMs('video/d', -350);
    expect((await repo.getByBookUid('video/d'))!.delayMs, -350);

    await repo.updateDelayMs('video/d', 1200);
    expect((await repo.getByBookUid('video/d'))!.delayMs, 1200);
  });
}
