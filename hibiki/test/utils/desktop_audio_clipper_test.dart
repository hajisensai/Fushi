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
}
