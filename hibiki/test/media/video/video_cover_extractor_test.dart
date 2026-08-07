// 视频封面抽取器（media/video/video_cover_extractor.dart）：容器内嵌封面
// 抽取（args 纯函数 + 真 ffmpeg 集成）。审计 §1-A 从
// test/utils/desktop_audio_clipper_test.dart 随实现迁入，用例内容不变。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart'
    show resolveFfmpegExecutable;
import 'package:fushi/src/media/video/video_cover_extractor.dart';

void main() {
  group('buildFfmpegEmbeddedCoverArgs', () {
    test('maps only the attached_pic video stream (no trailing ? marker)', () {
      final List<String> args = buildFfmpegEmbeddedCoverArgs(
        inputPath: '/a/in.mkv',
        outputPath: '/a/cover.jpg',
      );
      expect(args, <String>[
        '-y',
        '-i',
        '/a/in.mkv',
        '-an',
        '-map',
        '0:v:disp:attached_pic',
        '-frames:v',
        '1',
        '-update',
        '1',
        '/a/cover.jpg',
      ]);
      // The disposition selector must NOT carry a trailing '?'. With '?' ffmpeg
      // silently falls through to the main video's first frame when there is no
      // cover, which would defeat the prefer-embedded-then-fall-back logic.
      expect(args, isNot(contains('0:v:disp:attached_pic?')));
    });
  });

  group('extractEmbeddedVideoCoverViaFfmpeg', () {
    test('returns null when the input file does not exist', () async {
      expect(
        await extractEmbeddedVideoCoverViaFfmpeg(
          inputPath: '/no/such/video.mkv',
          outputPath: 'x.jpg',
        ),
        isNull,
      );
    });

    test('extracts an attached cover and returns null for a cover-less mkv',
        () async {
      bool ffmpegPresent;
      try {
        final ProcessResult v =
            await Process.run(resolveFfmpegExecutable(), <String>['-version']);
        ffmpegPresent = v.exitCode == 0;
      } catch (_) {
        ffmpegPresent = false;
      }
      if (!ffmpegPresent) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping real embedded-cover test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_vcover_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String ff = resolveFfmpegExecutable();
      final String coverPng = '${dir.path}/cover.png';
      final String plainMkv = '${dir.path}/plain.mkv';
      final String withCoverMkv = '${dir.path}/withcover.mkv';

      // A distinct 200x200 red cover image.
      await Process.run(ff, <String>[
        '-y', '-f', 'lavfi', '-i', 'color=red:s=200x200:d=1', //
        '-frames:v', '1', coverPng,
      ]);
      // A plain 2s video with NO cover attachment.
      final ProcessResult genPlain = await Process.run(ff, <String>[
        '-y', '-f', 'lavfi', '-i', 'testsrc=duration=2:size=320x240:rate=10', //
        '-pix_fmt', 'yuv420p', plainMkv,
      ]);
      expect(genPlain.exitCode, 0, reason: genPlain.stderr.toString());
      // Mux the cover into the mkv as a real Matroska attachment (cover.*),
      // which ffmpeg surfaces as an (attached pic) video stream.
      final ProcessResult genCover = await Process.run(ff, <String>[
        '-y', '-i', plainMkv, '-attach', coverPng, //
        '-metadata:s:t', 'mimetype=image/png',
        '-metadata:s:t', 'filename=cover.png',
        '-c', 'copy', withCoverMkv,
      ]);
      expect(genCover.exitCode, 0, reason: genCover.stderr.toString());

      // ① mkv WITH an attached cover → extracts it.
      final String coverOut = '${dir.path}/extracted.jpg';
      final String? withResult = await extractEmbeddedVideoCoverViaFfmpeg(
        inputPath: withCoverMkv,
        outputPath: coverOut,
      );
      expect(withResult, coverOut,
          reason: 'mkv with a cover attachment must extract the cover');
      expect(File(coverOut).existsSync(), isTrue);
      expect(File(coverOut).lengthSync(), greaterThan(0));

      // ② mkv WITHOUT a cover → null, and writes no output file (so the import
      // flow knows to fall back to a frame grab).
      final String plainOut = '${dir.path}/plain.jpg';
      final String? plainResult = await extractEmbeddedVideoCoverViaFfmpeg(
        inputPath: plainMkv,
        outputPath: plainOut,
      );
      expect(plainResult, isNull,
          reason: 'a cover-less mkv must yield null, not the main video frame');
      expect(File(plainOut).existsSync(), isFalse,
          reason: 'no partial/main-frame file may be left behind');
    });
  });
}
