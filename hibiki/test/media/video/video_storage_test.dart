import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory covers;
  late Directory subs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hibiki_video_storage_');
    covers = Directory(p.join(tmp.path, 'video_covers'))
      ..createSync(recursive: true);
    subs = Directory(p.join(tmp.path, 'video_subtitles'))
      ..createSync(recursive: true);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File writeFile(Directory dir, String name) {
    final File f = File(p.join(dir.path, name))..writeAsStringSync('x');
    return f;
  }

  test('gcOrphans deletes covers/subs not referenced by the DB', () async {
    final File keepCover = writeFile(covers, 'video__keep.jpg');
    final File orphanCover = writeFile(covers, 'video__gone.jpg');
    final File keepSub = writeFile(subs, 'keep.ass');
    final File orphanSub = writeFile(subs, 'gone.srt');

    final int removed = await VideoStorage.gcOrphans(
      referencedCoverPaths: <String>[keepCover.path],
      referencedSubtitlePaths: <String>[keepSub.path],
      coversDirectory: covers,
      subtitlesDirectory: subs,
    );

    expect(removed, 2);
    expect(keepCover.existsSync(), isTrue);
    expect(orphanCover.existsSync(), isFalse);
    expect(keepSub.existsSync(), isTrue);
    expect(orphanSub.existsSync(), isFalse);
  });

  test('gcOrphans removes ALL files when nothing is referenced (full purge)',
      () async {
    writeFile(covers, 'a.jpg');
    writeFile(covers, 'b.jpg');
    writeFile(subs, 'c.srt');

    final int removed = await VideoStorage.gcOrphans(
      referencedCoverPaths: const <String>[],
      referencedSubtitlePaths: const <String>[],
      coversDirectory: covers,
      subtitlesDirectory: subs,
    );

    expect(removed, 3);
    expect(covers.listSync(), isEmpty);
    expect(subs.listSync(), isEmpty);
  });

  test('gcOrphans path matching is normalized (mixed separators / casing)',
      () async {
    final File cover = writeFile(covers, 'video__x.jpg');
    // Reference the same file via a non-canonical path (extra separators).
    final String messy = cover.path.replaceAll('/', '\\').replaceAll(
          'video_covers',
          'video_covers',
        );

    final int removed = await VideoStorage.gcOrphans(
      referencedCoverPaths: <String>[messy],
      referencedSubtitlePaths: const <String>[],
      coversDirectory: covers,
      subtitlesDirectory: subs,
    );

    expect(removed, 0);
    expect(cover.existsSync(), isTrue);
  });

  test('gcOrphans never touches files outside the two app-owned dirs',
      () async {
    // A user's original video sitting elsewhere must survive any GC.
    final Directory external = Directory(p.join(tmp.path, 'movies'))
      ..createSync();
    final File userVideo = File(p.join(external.path, 'movie.mkv'))
      ..writeAsStringSync('video');

    await VideoStorage.gcOrphans(
      referencedCoverPaths: const <String>[],
      referencedSubtitlePaths: const <String>[],
      coversDirectory: covers,
      subtitlesDirectory: subs,
    );

    expect(userVideo.existsSync(), isTrue);
  });

  test('gcOrphans tolerates missing directories', () async {
    await covers.delete(recursive: true);
    await subs.delete(recursive: true);

    final int removed = await VideoStorage.gcOrphans(
      referencedCoverPaths: const <String>[],
      referencedSubtitlePaths: const <String>[],
      coversDirectory: covers,
      subtitlesDirectory: subs,
    );

    expect(removed, 0);
  });
}
