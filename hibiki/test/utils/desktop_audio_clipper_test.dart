import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart' as ffmpeg;
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

void main() {
  group('buildFfmpegClipArgs', () {
    test('formats seek/duration in seconds and orders flags', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.m4b',
        startMs: 1000,
        endMs: 2500,
        outputPath: '/a/out.aac',
      );
      expect(args, <String>[
        '-y',
        '-ss',
        '1.000',
        '-t',
        '1.500',
        '-i',
        '/a/in.m4b',
        '-vn',
        '-c:a',
        'aac',
        '/a/out.aac',
      ]);
    });

    test('no -map when audioStreamIndex is null (default audio selection)', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
        audioStreamIndex: null,
      );
      expect(args.contains('-map'), isFalse);
    });

    test('no -map when audioStreamIndex is negative', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
        audioStreamIndex: -1,
      );
      expect(args.contains('-map'), isFalse);
    });

    test('maps 0:a:<idx> for the selected audio track', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 1000,
        endMs: 2500,
        outputPath: '/a/out.aac',
        audioStreamIndex: 1,
      );
      expect(args, <String>[
        '-y',
        '-ss',
        '1.000',
        '-t',
        '1.500',
        '-i',
        '/a/in.mkv',
        '-vn',
        '-map',
        '0:a:1',
        '-c:a',
        'aac',
        '/a/out.aac',
      ]);
    });
  });

  group('extractAudioSegmentViaFfmpeg', () {
    tearDown(() {
      ffmpeg.setFfmpegBackendForTesting(null);
    });

    test('returns null for a non-positive range without running ffmpeg',
        () async {
      expect(
        await extractAudioSegmentViaFfmpeg(
          inputPath: 'whatever',
          startMs: 1000,
          endMs: 1000,
          outputPath: 'x.aac',
        ),
        isNull,
      );
    });

    test('returns null when the input file does not exist', () async {
      expect(
        await extractAudioSegmentViaFfmpeg(
          inputPath: '/no/such/input.m4b',
          startMs: 0,
          endMs: 1000,
          outputPath: 'x.aac',
        ),
        isNull,
      );
    });

    test('cuts a real clip when ffmpeg is available', () async {
      // Environment-dependent: skip cleanly if ffmpeg is not installed.
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
        print('ffmpeg not present; skipping real-clip extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.m4a';
      final String output = '${dir.path}/out.aac';

      // Generate a 3s tone to cut from.
      final ProcessResult gen =
          await Process.run(resolveFfmpegExecutable(), <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=3',
        '-c:a',
        'aac',
        input,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final String? result = await extractAudioSegmentViaFfmpeg(
        inputPath: input,
        startMs: 1000,
        endMs: 2000,
        outputPath: output,
      );

      expect(result, output);
      expect(File(output).existsSync(), isTrue);
      expect(File(output).lengthSync(), greaterThan(0));
    });

    test('reports invalid-image diagnostics when audio clipping fails',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_fail_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.mkv';
      final String output = '${dir.path}/out.aac';
      File(input).writeAsBytesSync(<int>[0, 1, 2, 3]);
      final List<String> failures = <String>[];

      ffmpeg.setFfmpegBackendForTesting(_FakeFfmpegBackend(
        const ffmpeg.FfmpegRunResult(
          returnCode: -1073741701,
          output: 'The application was unable to start correctly.',
          executable: r'C:\Hibiki\ffmpeg.exe',
          attemptedExecutables: <String>[
            r'C:\Hibiki\ffmpeg.exe',
            'ffmpeg',
          ],
          fallbackReason: 'bundled ffmpeg produced STATUS_INVALID_IMAGE_FORMAT',
        ),
      ));

      final String? result = await extractAudioSegmentViaFfmpeg(
        inputPath: input,
        startMs: 1000,
        endMs: 2000,
        outputPath: output,
        onFailure: failures.add,
      );

      expect(result, isNull);
      expect(File(output).existsSync(), isFalse);
      expect(failures, hasLength(1));
      expect(failures.single, contains('0xC000007B'));
      expect(failures.single, contains('STATUS_INVALID_IMAGE_FORMAT'));
      expect(failures.single, contains(r'C:\Hibiki\ffmpeg.exe -> ffmpeg'));
      expect(failures.single, contains('The application was unable'));
    });
  });

  group('extractClipGifViaFfmpeg', () {
    tearDown(() {
      ffmpeg.setFfmpegBackendForTesting(null);
    });

    test('reports invalid-image diagnostics when GIF clipping fails', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_gif_fail_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.mkv';
      final String output = '${dir.path}/out.gif';
      File(input).writeAsBytesSync(<int>[0, 1, 2, 3]);
      final List<String> failures = <String>[];

      ffmpeg.setFfmpegBackendForTesting(_FakeFfmpegBackend(
        const ffmpeg.FfmpegRunResult(
          returnCode: -1073741701,
          output: '',
          executable: r'C:\Hibiki\ffmpeg.exe',
          attemptedExecutables: <String>[
            r'C:\Hibiki\ffmpeg.exe',
            'ffmpeg',
          ],
          fallbackReason: 'bundled ffmpeg produced STATUS_INVALID_IMAGE_FORMAT',
        ),
      ));

      final String? result = await extractClipGifViaFfmpeg(
        inputPath: input,
        startMs: 1000,
        endMs: 2000,
        outputPath: output,
        onFailure: failures.add,
      );

      expect(result, isNull);
      expect(File(output).existsSync(), isFalse);
      expect(failures, hasLength(1));
      expect(failures.single, contains('0xC000007B'));
      expect(failures.single, contains(r'C:\Hibiki\ffmpeg.exe -> ffmpeg'));
    });
  });

  group('buildFfmpegCoverArgs', () {
    test('extracts a single video frame with audio dropped', () {
      expect(
        buildFfmpegCoverArgs(inputPath: '/a/in.m4b', outputPath: '/a/c.jpg'),
        <String>[
          '-y',
          '-i',
          '/a/in.m4b',
          '-an',
          '-frames:v',
          '1',
          '-update',
          '1',
          '/a/c.jpg',
        ],
      );
    });
  });

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

  group('buildFfmpegFrameArgs', () {
    test('grabs one frame at the given second with audio dropped', () {
      expect(
        buildFfmpegFrameArgs(
          inputPath: '/a/in.mkv',
          outputPath: '/a/thumb.jpg',
          atSeconds: 10,
        ),
        <String>[
          '-y',
          '-ss',
          '10.000',
          '-i',
          '/a/in.mkv',
          '-an',
          '-frames:v',
          '1',
          '-update',
          '1',
          '/a/thumb.jpg',
        ],
      );
    });

    test('defaults to t=0 and clamps a negative seek to 0', () {
      expect(
        buildFfmpegFrameArgs(inputPath: '/a/in.mp4', outputPath: '/a/t.jpg'),
        <String>[
          '-y', '-ss', '0.000', '-i', '/a/in.mp4', //
          '-an', '-frames:v', '1', '-update', '1', '/a/t.jpg',
        ],
      );
      expect(
        buildFfmpegFrameArgs(
          inputPath: '/a/in.mp4',
          outputPath: '/a/t.jpg',
          atSeconds: -5,
        ),
        contains('0.000'),
      );
    });
  });

  group('extractVideoFrameViaFfmpeg', () {
    test('returns null when the input file does not exist', () async {
      expect(
        await extractVideoFrameViaFfmpeg(
          inputPath: '/no/such/video.mkv',
          outputPath: 'x.jpg',
        ),
        isNull,
      );
    });

    test('grabs a real frame when ffmpeg is available', () async {
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
        print('ffmpeg not present; skipping real-frame extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_frame_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String video = '${dir.path}/clip.mp4';
      final String out = '${dir.path}/thumb.jpg';
      final String ff = resolveFfmpegExecutable();

      // 生成一段 5s 彩色测试视频。
      final ProcessResult gen = await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc=duration=5:size=64x64:rate=10',
        '-pix_fmt',
        'yuv420p',
        video,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final String? result = await extractVideoFrameViaFfmpeg(
        inputPath: video,
        outputPath: out,
        atSeconds: 2,
      );

      expect(result, out);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), greaterThan(0));
    });
  });

  group('buildFfmpegSubtitleArgs', () {
    test('maps the Nth subtitle stream to the output path', () {
      expect(
        buildFfmpegSubtitleArgs(
          inputPath: '/a/in.mkv',
          streamIndex: 0,
          outputPath: '/a/sub.ass',
        ),
        <String>['-y', '-i', '/a/in.mkv', '-map', '0:s:0', '/a/sub.ass'],
      );
    });

    test('uses the requested stream index', () {
      expect(
        buildFfmpegSubtitleArgs(
          inputPath: '/a/in.mkv',
          streamIndex: 2,
          outputPath: '/a/sub.ass',
        ),
        <String>['-y', '-i', '/a/in.mkv', '-map', '0:s:2', '/a/sub.ass'],
      );
    });
  });

  group('extractEmbeddedSubtitleViaFfmpeg', () {
    test('returns null when the input file does not exist', () async {
      expect(
        await extractEmbeddedSubtitleViaFfmpeg(
          inputPath: '/no/such/input.mkv',
          streamIndex: 0,
          outputPath: 'x.ass',
        ),
        isNull,
      );
    });

    test('extracts an embedded subtitle track when ffmpeg is available',
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
        print('ffmpeg not present; skipping real-subtitle extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_sub_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String srt = '${dir.path}/src.srt';
      final String video = '${dir.path}/withsub.mkv';
      final String out = '${dir.path}/extracted.ass';
      final String ff = resolveFfmpegExecutable();

      // 写一条最小 SRT，再 mux 进 mkv 的字幕轨（ffmpeg 转成 ASS）。
      File(srt).writeAsStringSync(
        '1\n00:00:00,500 --> 00:00:02,000\n吾輩は猫である。\n\n'
        '2\n00:00:02,500 --> 00:00:04,000\n名前はまだない。\n',
      );
      final ProcessResult mux = await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=black:s=64x64:d=5',
        '-i',
        srt,
        '-map',
        '0:v',
        '-map',
        '1',
        '-c:v',
        'libx264',
        '-c:s',
        'ass',
        video,
      ]);
      expect(mux.exitCode, 0, reason: mux.stderr.toString());

      final String? result = await extractEmbeddedSubtitleViaFfmpeg(
        inputPath: video,
        streamIndex: 0,
        outputPath: out,
      );

      expect(result, out);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), greaterThan(0));
    });
  });

  group('buildFfmpegMultiSubtitleArgs (BUG-104 单趟多轨)', () {
    test('单 -i + 每轨一对 -map 0:s:N out，按 streamIndex 升序', () {
      final List<String> args = buildFfmpegMultiSubtitleArgs(
        inputPath: '/v/movie.mkv',
        outputs: <int, String>{
          3: '/c/sub_3.srt',
          0: '/c/sub_0.srt',
          1: '/c/sub_1.ass',
        },
      );
      expect(args, <String>[
        '-y',
        '-i',
        '/v/movie.mkv',
        '-map',
        '0:s:0',
        '/c/sub_0.srt',
        '-map',
        '0:s:1',
        '/c/sub_1.ass',
        '-map',
        '0:s:3',
        '/c/sub_3.srt',
      ]);
      // 关键：整批只有一个 -i（单次 demux 读穿容器），不是每轨一个输入。
      expect(args.where((String a) => a == '-i').length, 1);
    });

    test('空 outputs → 只剩 -y -i（无 -map）', () {
      final List<String> args = buildFfmpegMultiSubtitleArgs(
        inputPath: '/v/x.mkv',
        outputs: const <int, String>{},
      );
      expect(args, <String>['-y', '-i', '/v/x.mkv']);
    });
  });

  group('extractEmbeddedSubtitlesViaFfmpeg (BUG-104 单趟全轨缓存)', () {
    test('returns empty when the input file does not exist', () async {
      expect(
        await extractEmbeddedSubtitlesViaFfmpeg(
          inputPath: '/no/such/input.mkv',
          outputs: <int, String>{0: 'x.srt'},
        ),
        isEmpty,
      );
    });

    test('returns empty when no outputs requested', () async {
      expect(
        await extractEmbeddedSubtitlesViaFfmpeg(
          inputPath: '/no/such/input.mkv',
          outputs: const <int, String>{},
        ),
        isEmpty,
      );
    });

    test('extracts MULTIPLE embedded tracks in one pass when ffmpeg available',
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
        print('ffmpeg not present; skipping multi-subtitle extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_multisub_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String srtA = '${dir.path}/a.srt';
      final String srtB = '${dir.path}/b.srt';
      final String video = '${dir.path}/twosubs.mkv';
      final String ff = resolveFfmpegExecutable();

      File(srtA).writeAsStringSync(
        '1\n00:00:00,500 --> 00:00:02,000\n吾輩は猫である。\n',
      );
      File(srtB).writeAsStringSync(
        '1\n00:00:00,500 --> 00:00:02,000\n名前はまだない。\n',
      );
      // 一个视频 + 两条字幕轨（相对序号 0/1）。
      final ProcessResult mux = await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=black:s=64x64:d=5',
        '-i',
        srtA,
        '-i',
        srtB,
        '-map',
        '0:v',
        '-map',
        '1',
        '-map',
        '2',
        '-c:v',
        'libx264',
        '-c:s',
        'srt',
        video,
      ]);
      expect(mux.exitCode, 0, reason: mux.stderr.toString());

      final String out0 = '${dir.path}/sub_0.srt';
      final String out1 = '${dir.path}/sub_1.srt';
      final Map<int, String> written = await extractEmbeddedSubtitlesViaFfmpeg(
        inputPath: video,
        outputs: <int, String>{0: out0, 1: out1},
      );

      // 单趟抽出两条轨，二者都落盘且非空。
      expect(written.keys.toSet(), <int>{0, 1});
      expect(File(out0).existsSync(), isTrue);
      expect(File(out0).lengthSync(), greaterThan(0));
      expect(File(out1).existsSync(), isTrue);
      expect(File(out1).lengthSync(), greaterThan(0));
    });
  });

  group('extractEmbeddedCoverViaFfmpeg', () {
    test('returns null when the audio file does not exist', () async {
      expect(
        await extractEmbeddedCoverViaFfmpeg(
          audioPath: '/no/such/input.m4b',
          outputPath: 'x.jpg',
        ),
        isNull,
      );
    });

    test('extracts an embedded cover when ffmpeg is available', () async {
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
        print('ffmpeg not present; skipping real-cover extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_cover_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String cover = '${dir.path}/cover.png';
      final String audio = '${dir.path}/withcover.m4a';
      final String out = '${dir.path}/extracted.jpg';
      final String ff = resolveFfmpegExecutable();

      await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=red:s=48x48',
        '-frames:v',
        '1',
        cover,
      ]);
      await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=d=1',
        '-i',
        cover,
        '-map',
        '0:a',
        '-map',
        '1:v',
        '-c:a',
        'aac',
        '-c:v',
        'mjpeg',
        '-disposition:v',
        'attached_pic',
        audio,
      ]);

      final String? result = await extractEmbeddedCoverViaFfmpeg(
        audioPath: audio,
        outputPath: out,
      );

      expect(result, out);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), greaterThan(0));
    });
  });
}

class _FakeFfmpegBackend implements ffmpeg.FfmpegBackend {
  const _FakeFfmpegBackend(this.result);

  final ffmpeg.FfmpegRunResult result;

  @override
  Future<ffmpeg.FfmpegRunResult> run(
    List<String> args,
    Duration timeout,
  ) async =>
      result;
}
