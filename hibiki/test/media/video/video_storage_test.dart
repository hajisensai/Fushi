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

  group('deleteBookAssets (per-book precise delete, BUG-276)', () {
    test('deletes the deleted book\'s own cover + subtitle', () async {
      final File cover = writeFile(covers, 'video__del.jpg');
      final File sub = writeFile(subs, 'del.ass');

      final int removed = await VideoStorage.deleteBookAssets(
        deletedCoverPath: cover.path,
        deletedSubtitlePath: sub.path,
        stillReferencedCoverPaths: const <String>[],
        stillReferencedSubtitlePaths: const <String>[],
        coversDirectory: covers,
        subtitlesDirectory: subs,
      );

      expect(removed, 2);
      expect(cover.existsSync(), isFalse);
      expect(sub.existsSync(), isFalse);
    });

    // The High data-loss defect: deleting video A must NOT touch playlist B's
    // per-episode subtitle copies that live in the same flat video_subtitles/
    // pool but are unknown to the DB (only B's last-selected episode is in
    // subtitleSource). Precise delete only ever touches A's own path.
    test('deleting A never touches playlist B\'s other-episode subtitle copies',
        () async {
      // A's own subtitle copy (the one being deleted).
      final File aSub = writeFile(subs, 'A_ep01.ja.srt');
      // Playlist B copied 3 episodes' subtitles into the flat pool. Only the
      // last-selected one (ep03) is recorded in B.subtitleSource; ep01/ep02 are
      // NOT in any DB reference set — under the old full-dir sweep they'd be
      // wiped as "orphans" when A is deleted.
      final File bEp1 = writeFile(subs, 'B_ep01.ja.srt');
      final File bEp2 = writeFile(subs, 'B_ep02.ja.srt');
      final File bEp3 = writeFile(subs, 'B_ep03.ja.srt');

      final int removed = await VideoStorage.deleteBookAssets(
        deletedCoverPath: null,
        deletedSubtitlePath: aSub.path,
        // Still-referenced set after deleting A: only B's recorded episode.
        stillReferencedCoverPaths: const <String>[],
        stillReferencedSubtitlePaths: <String>[bEp3.path],
        coversDirectory: covers,
        subtitlesDirectory: subs,
      );

      expect(removed, 1, reason: 'only A\'s own subtitle copy is removed');
      expect(aSub.existsSync(), isFalse);
      // All of B's copies survive — including the ones the DB does not know
      // about. This is the regression guard for the data-loss defect.
      expect(bEp1.existsSync(), isTrue, reason: 'B ep01 copy must survive');
      expect(bEp2.existsSync(), isTrue, reason: 'B ep02 copy must survive');
      expect(bEp3.existsSync(), isTrue, reason: 'B ep03 copy must survive');
    });

    test('keeps a file still referenced by another book (shared/reused name)',
        () async {
      final File shared = writeFile(subs, 'shared.ja.srt');

      final int removed = await VideoStorage.deleteBookAssets(
        deletedCoverPath: null,
        deletedSubtitlePath: shared.path,
        stillReferencedCoverPaths: const <String>[],
        // Another book still points at the same file → must be kept.
        stillReferencedSubtitlePaths: <String>[shared.path],
        coversDirectory: covers,
        subtitlesDirectory: subs,
      );

      expect(removed, 0);
      expect(shared.existsSync(), isTrue);
    });

    test('never deletes a path outside the app-owned dirs (user video)',
        () async {
      final Directory external = Directory(p.join(tmp.path, 'movies'))
        ..createSync();
      final File userVideo = File(p.join(external.path, 'movie.mkv'))
        ..writeAsStringSync('video');

      // Even if a (corrupt) DB row pointed videoPath-like values at it, the
      // out-of-dir guard refuses to delete it.
      final int removed = await VideoStorage.deleteBookAssets(
        deletedCoverPath: null,
        deletedSubtitlePath: userVideo.path,
        stillReferencedCoverPaths: const <String>[],
        stillReferencedSubtitlePaths: const <String>[],
        coversDirectory: covers,
        subtitlesDirectory: subs,
      );

      expect(removed, 0);
      expect(userVideo.existsSync(), isTrue);
    });

    test('null / missing paths are no-ops', () async {
      final int removed = await VideoStorage.deleteBookAssets(
        deletedCoverPath: null,
        deletedSubtitlePath: p.join(subs.path, 'does_not_exist.srt'),
        stillReferencedCoverPaths: const <String>[],
        stillReferencedSubtitlePaths: const <String>[],
        coversDirectory: covers,
        subtitlesDirectory: subs,
      );
      expect(removed, 0);
    });

    test('path matching is normalized (mixed separators)', () async {
      final File sub = writeFile(subs, 'norm.ass');
      // Reference the same file via a messy path → guard keeps it.
      // 平台无关:冗余 '.' 段构造等价异格式路径(canonicalize 各平台归一);不能用反斜杠
      // 替换 — Linux 上反斜杠是合法文件名字符非分隔符,不归一致 CI 误删红。
      final String messy = p.join(p.dirname(sub.path), '.', p.basename(sub.path));

      final int removed = await VideoStorage.deleteBookAssets(
        deletedCoverPath: null,
        deletedSubtitlePath: sub.path,
        stillReferencedCoverPaths: const <String>[],
        stillReferencedSubtitlePaths: <String>[messy],
        coversDirectory: covers,
        subtitlesDirectory: subs,
      );

      expect(removed, 0);
      expect(sub.existsSync(), isTrue);
    });
  });

  group('gcOrphanCovers (safe cover-only history GC, BUG-276)', () {
    test('removes covers not referenced by the DB, keeps referenced ones',
        () async {
      final File keep = writeFile(covers, 'video__keep.jpg');
      final File orphan = writeFile(covers, 'video__gone.jpg');

      final int removed = await VideoStorage.gcOrphanCovers(
        referencedCoverPaths: <String>[keep.path],
        coversDirectory: covers,
      );

      expect(removed, 1);
      expect(keep.existsSync(), isTrue);
      expect(orphan.existsSync(), isFalse);
    });

    test('removes ALL covers when nothing is referenced (full purge)',
        () async {
      writeFile(covers, 'a.jpg');
      writeFile(covers, 'b.jpg');

      final int removed = await VideoStorage.gcOrphanCovers(
        referencedCoverPaths: const <String>[],
        coversDirectory: covers,
      );

      expect(removed, 2);
      expect(covers.listSync(), isEmpty);
    });

    test('tolerates a missing covers directory', () async {
      await covers.delete(recursive: true);
      final int removed = await VideoStorage.gcOrphanCovers(
        referencedCoverPaths: const <String>[],
        coversDirectory: covers,
      );
      expect(removed, 0);
    });
  });
}
