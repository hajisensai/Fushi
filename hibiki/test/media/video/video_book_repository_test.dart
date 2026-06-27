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
      ..bookKey = 'video/1'
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

  test('saveCues with an empty list clears persisted cues (BUG-081 off path)',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/off'),
      title: Value('Off'),
      videoPath: Value('/off.mp4'),
    ));
    final cue = AudioCue()
      ..bookKey = 'video/off'
      ..chapterHref = 'video://default'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'hi'
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    await repo.saveCues(bookUid: 'video/off', cues: [cue]);
    expect(await repo.loadCues('video/off'), hasLength(1));

    // Turning subtitles off persists an empty cue list; re-open must read none.
    await repo.saveCues(bookUid: 'video/off', cues: const []);
    expect(await repo.loadCues('video/off'), isEmpty);
  });

  test('saveSubtitleSelection writes cues + source atomically (BUG-081/W1)',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/sel'),
      title: Value('Sel'),
      videoPath: Value('/sel.mp4'),
    ));
    final cue = AudioCue()
      ..bookKey = 'video/sel'
      ..chapterHref = 'video://default'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'yo'
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;

    await repo.saveSubtitleSelection(
      bookUid: 'video/sel',
      subtitleSource: '/subs/sel.ass',
      cues: [cue],
    );
    expect(await repo.loadCues('video/sel'), hasLength(1));
    expect((await repo.getByBookUid('video/sel'))!.subtitleSource,
        '/subs/sel.ass');

    // Turning off clears both in one transaction.
    await repo.saveSubtitleSelection(
      bookUid: 'video/sel',
      subtitleSource: null,
      cues: const [],
    );
    expect(await repo.loadCues('video/sel'), isEmpty);
    expect((await repo.getByBookUid('video/sel'))!.subtitleSource, isNull);
  });

  test(
      'updateSecondarySubtitleSource round-trips independently of '
      'primary subtitle (TODO-857)', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/dual'),
      title: Value('Dual'),
      videoPath: Value('/dual.mp4'),
    ));

    // Fresh row: secondary subtitle defaults to NULL (no secondary subtitle).
    expect((await repo.getByBookUid('video/dual'))!.secondarySubtitleSource,
        isNull);

    // Set primary + secondary to different sources; both persist independently.
    await repo.updateSubtitleSource('video/dual', 'embedded:0');
    await repo.updateSecondarySubtitleSource('video/dual', 'embedded:1');
    final row = (await repo.getByBookUid('video/dual'))!;
    expect(row.subtitleSource, 'embedded:0');
    expect(row.secondarySubtitleSource, 'embedded:1');

    // Clearing secondary (null) leaves primary untouched.
    await repo.updateSecondarySubtitleSource('video/dual', null);
    final row2 = (await repo.getByBookUid('video/dual'))!;
    expect(row2.subtitleSource, 'embedded:0');
    expect(row2.secondarySubtitleSource, isNull);
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

  test('deleteVideoBook removes the row AND its subtitle cue rows (BUG-276)',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/del'),
      title: Value('Del'),
      videoPath: Value('/del.mp4'),
    ));
    final cue = AudioCue()
      ..bookKey = 'video/del'
      ..chapterHref = 'video://default'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'bye'
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    await repo.saveCues(bookUid: 'video/del', cues: [cue]);
    // A second, unrelated video's cues must NOT be collaterally deleted.
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/other'),
      title: Value('Other'),
      videoPath: Value('/other.mp4'),
    ));
    final otherCue = AudioCue()
      ..bookKey = 'video/other'
      ..chapterHref = 'video://default'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'stay'
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    await repo.saveCues(bookUid: 'video/other', cues: [otherCue]);

    expect(await repo.loadCues('video/del'), hasLength(1));

    await repo.deleteVideoBook('video/del');

    expect(await repo.getByBookUid('video/del'), isNull);
    expect(await repo.loadCues('video/del'), isEmpty,
        reason: 'cue rows must be cleared, not orphaned');
    // Sibling video untouched.
    expect((await repo.getByBookUid('video/other'))!.title, 'Other');
    expect(await repo.loadCues('video/other'), hasLength(1));
  });

  test(
      'collectReferencedAssetPaths gathers covers + subtitles (BUG-276 GC set)',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/a'),
      title: Value('A'),
      videoPath: Value('/a.mp4'),
      coverPath: Value('/docs/video_covers/a.jpg'),
      subtitleSource: Value('/docs/video_subtitles/a.ass'),
    ));
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/b'),
      title: Value('B'),
      videoPath: Value('/b.mp4'),
      coverPath: Value('/docs/video_covers/b.jpg'),
      // No subtitle source (embedded track only).
    ));

    final refs = await repo.collectReferencedAssetPaths();
    expect(
      refs.covers,
      containsAll(<String>[
        '/docs/video_covers/a.jpg',
        '/docs/video_covers/b.jpg',
      ]),
    );
    expect(refs.subtitles, contains('/docs/video_subtitles/a.ass'));
    // null/empty values are not included.
    expect(refs.subtitles, hasLength(1));
  });

  test(
      'collectReferencedAssetPaths(excludeBookUid) drops the deleted book\'s own '
      'refs (BUG-276 delete guard set)', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/keep'),
      title: Value('Keep'),
      videoPath: Value('/keep.mp4'),
      coverPath: Value('/docs/video_covers/keep.jpg'),
      subtitleSource: Value('/docs/video_subtitles/keep.ass'),
    ));
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/del'),
      title: Value('Del'),
      videoPath: Value('/del.mp4'),
      coverPath: Value('/docs/video_covers/del.jpg'),
      subtitleSource: Value('/docs/video_subtitles/del.ass'),
    ));

    // The delete path collects the "all OTHER books" reference set so the
    // deleted book's own paths don't accidentally protect themselves.
    final refs =
        await repo.collectReferencedAssetPaths(excludeBookUid: 'video/del');
    expect(refs.covers, contains('/docs/video_covers/keep.jpg'));
    expect(refs.covers, isNot(contains('/docs/video_covers/del.jpg')));
    expect(refs.subtitles, contains('/docs/video_subtitles/keep.ass'));
    expect(refs.subtitles, isNot(contains('/docs/video_subtitles/del.ass')));
  });

  test('database VACUUM after delete runs without error (BUG-276)', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/vac'),
      title: Value('Vac'),
      videoPath: Value('/vac.mp4'),
    ));
    await repo.deleteVideoBook('video/vac');
    // The reclaim path calls VACUUM outside any transaction; assert it is a
    // valid statement against the real schema (catches "VACUUM inside
    // transaction" / syntax regressions).
    await db.customStatement('VACUUM');
    expect(await repo.listAll(), isEmpty);
  });

  test('updateTitle round-trips the playlist/video title (C 重命名)', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/rename'),
      title: Value('Old Episode Filename'),
      videoPath: Value('/e0.mkv'),
    ));

    await repo.updateTitle('video/rename', '我的番剧系列');
    expect((await repo.getByBookUid('video/rename'))!.title, '我的番剧系列');

    // 其它列不被改名波及（只动 title）。
    expect((await repo.getByBookUid('video/rename'))!.videoPath, '/e0.mkv');
  });
  test(
      'findByVideoPath returns the row referencing a physical file; '
      'isVideoPathReferenced delegates to it (TODO-903 dedup source)',
      () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);

    // 库内导入的身份是 video/<basename>。
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/movie.mkv'),
      title: Value('Movie'),
      videoPath: Value('/library/movie.mkv'),
    ));

    // 按 videoPath 命中已导入行（外部「打开方式」据此复用旧 bookUid，不插第二行）。
    final hit = await repo.findByVideoPath('/library/movie.mkv');
    expect(hit, isNotNull);
    expect(hit!.bookUid, 'video/movie.mkv');
    expect(await repo.isVideoPathReferenced('/library/movie.mkv'), isTrue);

    // 未入库路径无匹配。
    expect(await repo.findByVideoPath('/elsewhere/other.mkv'), isNull);
    expect(await repo.isVideoPathReferenced('/elsewhere/other.mkv'), isFalse);

    // 空路径不匹配（守卫提前返回）。
    expect(await repo.findByVideoPath(''), isNull);
    expect(await repo.isVideoPathReferenced(''), isFalse);

    // excludeBookUid 跳过自身：删除/自比对时该行不护住自己。
    expect(
      await repo.findByVideoPath('/library/movie.mkv',
          excludeBookUid: 'video/movie.mkv'),
      isNull,
    );
  });
}
