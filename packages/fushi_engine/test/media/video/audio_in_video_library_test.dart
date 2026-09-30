// 纯音频按「无画面的视频」进视频库：封面兜底（同目录专辑封面）与库对账枚举。
import 'dart:io';

import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show copyFolderCoverForAudio;
import 'package:fushi_engine/media/video/video_library_prune.dart'
    show enumerateLocalVideoPaths;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('audio_video_lib_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File writeTrack(String name) =>
      File(p.join(tmp.path, name))..writeAsStringSync('fake-flac');

  group('copyFolderCoverForAudio', () {
    test('copies the album cover.jpg next to the track as its cover', () async {
      final File track = writeTrack('01 - One more tea.flac');
      final List<int> png = img.encodePng(img.Image(width: 4, height: 4));
      File(p.join(tmp.path, 'cover.jpg')).writeAsBytesSync(png);
      final String out = p.join(tmp.path, 'covers', 'uid.jpg');

      final String? cover = await copyFolderCoverForAudio(
        audioPath: track.path,
        outputPath: out,
      );

      expect(cover, out);
      expect(File(out).readAsBytesSync(), png);
    });

    test('no folder cover -> null, nothing written', () async {
      final File track = writeTrack('01.flac');
      final String out = p.join(tmp.path, 'covers', 'uid.jpg');

      expect(
        await copyFolderCoverForAudio(audioPath: track.path, outputPath: out),
        isNull,
      );
      expect(File(out).existsSync(), isFalse);
    });

    test('undecodable folder cover -> null (never a broken cover)', () async {
      final File track = writeTrack('01.flac');
      File(p.join(tmp.path, 'folder.jpg')).writeAsStringSync('not an image');
      final String out = p.join(tmp.path, 'covers', 'uid.jpg');

      expect(
        await copyFolderCoverForAudio(audioPath: track.path, outputPath: out),
        isNull,
      );
      expect(File(out).existsSync(), isFalse);
    });
  });

  test(
    'library reconcile enumerates audio tracks (else they get pruned)',
    () async {
      final File track = writeTrack('01.flac');
      final File mkv = File(p.join(tmp.path, 'ep01.mkv'))
        ..writeAsStringSync('x');
      File(p.join(tmp.path, 'cover.jpg')).writeAsStringSync('x');

      final Set<String> found = await enumerateLocalVideoPaths(tmp);

      expect(found, <String>{
        normalizeVideoPath(track.path),
        normalizeVideoPath(mkv.path),
      });
    },
  );
}
