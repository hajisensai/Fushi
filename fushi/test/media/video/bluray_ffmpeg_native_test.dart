import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

// Opt-in native regression: FUSHI_TEST_FFMPEG must name a full FFmpeg build
// (lavfi is used only to generate fixtures, not by the production pipeline).
void main() {
  final String? executable = Platform.environment['FUSHI_TEST_FFMPEG'];
  test(
    'native MPLS seeking, seam frames, audio and synchronized card',
    () async {
      final String? evidencePath =
          Platform.environment['FUSHI_BLURAY_FIXTURE_ROOT'];
      final Directory root = evidencePath == null
          ? await Directory.systemTemp.createTemp('bd-native-')
          : await Directory(evidencePath).create(recursive: true);
      final String? previousOverride = ffmpegPathOverride;
      ffmpegPathOverride = executable;
      setFfmpegBackendForTesting(null);
      final FfmpegBackend backend = resolveFfmpegBackend();
      Future<void> run(List<String> args) async {
        // Fixture generation and raw-pixel inspection need the full build;
        // optionally exercise card creation using the actual bundled runtime.
        final String? cardExecutable =
            Platform.environment['FUSHI_TEST_CARD_FFMPEG'];
        ffmpegPathOverride =
            cardExecutable != null &&
                (args.last.endsWith('.mp4') || args.last.endsWith('.aac'))
            ? cardExecutable
            : executable;
        final FfmpegRunResult result = await backend.run(<String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          ...args,
        ], const Duration(seconds: 30));
        expect(result.isSuccess, isTrue, reason: result.failureSummary);
      }

      try {
        final Directory streams = Directory(
          p.join(root.path, 'BDMV', 'STREAM'),
        );
        final Directory lists = Directory(
          p.join(root.path, 'BDMV', 'PLAYLIST'),
        );
        await streams.create(recursive: true);
        await lists.create(recursive: true);
        for (final (String id, String color, int hz) in <(String, String, int)>[
          ('00001', 'red', 440),
          ('00002', 'blue', 880),
        ]) {
          await run(<String>[
            '-f',
            'lavfi',
            '-i',
            'color=c=$color:s=64x64:r=25:d=4',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=$hz:sample_rate=48000:duration=4',
            '-c:v',
            'libx264',
            '-g',
            '25',
            '-bf',
            '2',
            '-c:a',
            'mp2',
            '-b:a',
            '128k',
            '-muxdelay',
            '0',
            '-muxpreload',
            '0',
            '-output_ts_offset',
            '10',
            '-f',
            'mpegts',
            p.join(streams.path, '$id.m2ts'),
          ]);
        }
        final String playlist = p.join(lists.path, '00001.mpls');
        await File(playlist).writeAsBytes(
          buildMplsFixture(
            playItems: const <FixturePlayItem>[
              FixturePlayItem(
                clipId: '00001',
                inTimeTicks: 468000,
                outTimeTicks: 522000,
              ),
              FixturePlayItem(
                clipId: '00002',
                inTimeTicks: 504000,
                outTimeTicks: 576000,
              ),
            ],
          ),
        );
        final String frames = p.join(root.path, 'seam.rgb');
        await run(<String>[
          '-ss',
          '0.8',
          '-t',
          '0.8',
          '-i',
          playlist,
          '-an',
          '-vf',
          'scale=1:1',
          '-pix_fmt',
          'rgb24',
          '-f',
          'rawvideo',
          frames,
        ]);
        final Uint8List pixels = await File(frames).readAsBytes();
        expect(pixels.length, 20 * 3, reason: '0.8 seconds at 25 fps');
        for (int frame = 0; frame < 20; frame++) {
          expect(
            pixels[frame * 3 + (frame < 10 ? 0 : 2)],
            greaterThan(200),
            reason: 'frame $frame must follow the MPLS seam at 1.2 s',
          );
        }
        final String audio = p.join(root.path, 'title.pcm');
        await run(<String>[
          '-i',
          playlist,
          '-vn',
          '-map',
          '0:a:0',
          '-ar',
          '48000',
          '-ac',
          '1',
          '-c:a',
          'pcm_s16le',
          '-f',
          's16le',
          audio,
        ]);
        expect(
          (await File(audio).length()) / 2 / 48000,
          closeTo(2.8, 0.025),
          reason: 'ASR must consume the complete title',
        );
        final String card = p.join(root.path, 'card.mp4');
        await run(
          buildSynchronizedVideoClipArgs(
            videoPath: playlist,
            startMs: 800,
            endMs: 1600,
            outputPath: card,
            maxWidth: 64,
            fps: 25,
          ),
        );
        final String cardFrames = p.join(root.path, 'card.rgb');
        await run(<String>[
          '-i',
          card,
          '-an',
          '-vf',
          'scale=1:1',
          '-pix_fmt',
          'rgb24',
          '-f',
          'rawvideo',
          cardFrames,
        ]);
        final Uint8List cardPixels = await File(cardFrames).readAsBytes();
        expect(cardPixels.length, 20 * 3);
        expect(cardPixels[0], greaterThan(200));
        expect(cardPixels[cardPixels.length - 1], greaterThan(200));
        final String cardAudio = p.join(root.path, 'card.pcm');
        await run(<String>[
          '-i',
          card,
          '-vn',
          '-ar',
          '48000',
          '-ac',
          '1',
          '-c:a',
          'pcm_s16le',
          '-f',
          's16le',
          cardAudio,
        ]);
        expect(
          (await File(cardAudio).length()) / 2 / 48000,
          closeTo(0.8, 0.03),
        );

        // ImmersionMiningEngine actually renders AAC first and then passes
        // audioPath/audioStartMs=0 while retaining the original MPLS video.
        final String sentence = p.join(root.path, 'sentence.aac');
        await run(
          buildFfmpegClipArgs(
            inputPath: playlist,
            startMs: 800,
            endMs: 1600,
            outputPath: sentence,
          ),
        );
        final String minedCard = p.join(root.path, 'mined-card.mp4');
        await run(
          buildSynchronizedVideoClipArgs(
            videoPath: playlist,
            audioPath: sentence,
            audioStartMs: 0,
            startMs: 800,
            endMs: 1600,
            outputPath: minedCard,
            maxWidth: 64,
            fps: 25,
          ),
        );
        final String minedFrames = p.join(root.path, 'mined-card.rgb');
        await run(<String>[
          '-i',
          minedCard,
          '-an',
          '-vf',
          'scale=1:1',
          '-pix_fmt',
          'rgb24',
          '-f',
          'rawvideo',
          minedFrames,
        ]);
        final Uint8List minedPixels = await File(minedFrames).readAsBytes();
        expect(minedPixels.length, 20 * 3);
        for (int frame = 0; frame < 20; frame++) {
          expect(
            minedPixels[frame * 3 + (frame < 10 ? 0 : 2)],
            greaterThan(200),
          );
        }
        final String minedAudio = p.join(root.path, 'mined-card.pcm');
        await run(<String>[
          '-i',
          minedCard,
          '-vn',
          '-ar',
          '48000',
          '-ac',
          '1',
          '-c:a',
          'pcm_s16le',
          '-f',
          's16le',
          minedAudio,
        ]);
        expect(
          (await File(minedAudio).length()) / 2 / 48000,
          closeTo(0.8, 0.03),
        );
      } finally {
        ffmpegPathOverride = previousOverride;
        setFfmpegBackendForTesting(null);
        if (evidencePath == null) await root.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set FUSHI_TEST_FFMPEG for native media verification'
        : false,
  );
}
