import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
