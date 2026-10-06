import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/aacs_configuration.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart';
import 'package:path/path.dart' as p;

void main() {
  final String? disc = Platform.environment['FUSHI_TEST_AACS_DISC'];
  final String? keyDb = Platform.environment['FUSHI_TEST_AACS_KEYDB'];
  test(
    'real encrypted disc supplies decoded frames, audio and a mined MP4',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'aacs-native-',
      );
      final String? previousKeyDb = aacsKeyDbPathOverride;
      final String? previousFfmpeg = ffmpegPathOverride;
      aacsKeyDbPathOverride = keyDb;
      ffmpegPathOverride = Platform.environment['FUSHI_TEST_FFMPEG'];
      setFfmpegBackendForTesting(null);
      try {
        final FfmpegBackend backend = resolveFfmpegBackend();
        final String stream = p.join(disc!, 'BDMV', 'STREAM', '00001.m2ts');
        final File image = File(p.join(temp.path, 'frame.jpg'));
        final FfmpegRunResult frame = await backend.run(<String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-i',
          stream,
          '-map',
          '0:v:0',
          '-frames:v',
          '1',
          '-an',
          image.path,
        ], const Duration(seconds: 60));
        expect(frame.isSuccess, isTrue, reason: frame.failureSummary);
        expect(await image.length(), greaterThan(100));

        final String playlist = p.join(disc, 'BDMV', 'PLAYLIST', '00001.mpls');
        final File card = File(p.join(temp.path, 'card.mp4'));
        final FfmpegRunResult result = await backend.run(
          buildSynchronizedVideoClipArgs(
            videoPath: playlist,
            startMs: 0,
            endMs: 1000,
            outputPath: card.path,
            maxWidth: 320,
            fps: 24,
          ),
          const Duration(seconds: 90),
        );
        expect(result.isSuccess, isTrue, reason: result.output);
        expect(await card.length(), greaterThan(1000));
        final File audio = File(p.join(temp.path, 'sound.aac'));
        final FfmpegRunResult sound = await backend.run(<String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-i',
          playlist,
          '-vn',
          '-t',
          '1',
          '-map',
          '0:a:0',
          '-c:a',
          'aac',
          '-f',
          'adts',
          audio.path,
        ], const Duration(seconds: 60));
        expect(sound.isSuccess, isTrue, reason: sound.failureSummary);
        expect(await audio.length(), greaterThan(100));
      } finally {
        aacsKeyDbPathOverride = previousKeyDb;
        ffmpegPathOverride = previousFfmpeg;
        setFfmpegBackendForTesting(null);
        await temp.delete(recursive: true);
      }
    },
    skip: disc == null || keyDb == null
        ? 'Requires a user-provided encrypted disc and private KEYDB configuration'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
