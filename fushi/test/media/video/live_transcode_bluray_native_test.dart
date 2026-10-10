import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

// Opt-in native regression: FUSHI_TEST_FFMPEG must name a full FFmpeg build
// (lavfi + libx264 generate the fixture). The interconnect host transcodes a
// Blu-ray title from its `.mpls`; each segment must go through the shared
// Blu-ray input rewrite and land on the title's absolute timeline.
void main() {
  final String? executable = Platform.environment['FUSHI_TEST_FFMPEG'];
  test(
    'transcoded HLS segment of an MPLS title follows the playlist timeline',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'bd-transcode-',
      );
      final String? previousOverride = ffmpegPathOverride;
      ffmpegPathOverride = executable;
      setFfmpegBackendForTesting(null);
      setTranscodeSegmentRunnerForTesting(null);
      Future<ProcessResult> ffmpeg(List<String> args) => Process.run(
        executable!,
        <String>['-hide_banner', '-loglevel', 'error', '-y', ...args],
        stdoutEncoding: null,
      );
      try {
        final Directory streams = await Directory(
          p.join(root.path, 'BDMV', 'STREAM'),
        ).create(recursive: true);
        final Directory lists = await Directory(
          p.join(root.path, 'BDMV', 'PLAYLIST'),
        ).create(recursive: true);
        for (final (String id, String color, int hz) in <(String, String, int)>[
          ('00001', 'red', 440),
          ('00002', 'blue', 880),
        ]) {
          final ProcessResult made = await ffmpeg(<String>[
            '-f', 'lavfi', '-i', 'color=c=$color:s=64x64:r=25:d=4', //
            '-f', 'lavfi',
            '-i', 'sine=frequency=$hz:sample_rate=48000:duration=4',
            '-c:v', 'libx264', '-g', '25', '-bf', '2', //
            '-c:a', 'mp2', '-b:a', '128k', //
            '-muxdelay', '0', '-muxpreload', '0', //
            '-output_ts_offset', '10', //
            '-f', 'mpegts', p.join(streams.path, '$id.m2ts'),
          ]);
          expect(made.exitCode, 0, reason: '${made.stderr}');
        }
        // Title = clip 1 [10.4, 11.6) + clip 2 [11.2, 12.8): 2.8 s, seam at 1.2 s.
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

        // Segment 1 of 1-second segments straddles the seam.
        final Uint8List segment = await transcodeSegment(
          inputPath: playlist,
          profile: const VideoTranscodeProfile(maxWidth: 64, maxBitrate: 0),
          index: 1,
          durationMs: 2800,
          segmentSeconds: 1,
        );
        expect(segment, isNotEmpty);
        final String ts = p.join(root.path, 'seg1.ts');
        await File(ts).writeAsBytes(segment);

        final ProcessResult info = await Process.run(executable!, <String>[
          '-hide_banner',
          '-copyts',
          '-i',
          ts,
          '-an',
          '-vf',
          'showinfo',
          '-f',
          'null',
          '-',
        ]);
        final List<double> pts = <double>[
          for (final Match m in RegExp(
            r'pts_time:([0-9.]+)',
          ).allMatches('${info.stderr}'))
            double.parse(m.group(1)!),
        ];
        expect(pts, hasLength(25), reason: '1 second at 25 fps');
        // `-output_ts_offset` places the segment at its absolute title position
        // (HLS seek relies on it); the rewrite must not shift it again.
        expect(pts.first, closeTo(1.0, 0.02));
        expect(pts.last, closeTo(1.96, 0.02));

        final ProcessResult pixels = await ffmpeg(<String>[
          '-i', ts, '-an', '-vf', 'scale=1:1', '-pix_fmt', 'rgb24', //
          '-f', 'rawvideo', '-',
        ]);
        final List<int> rgb = pixels.stdout as List<int>;
        expect(rgb.length, 25 * 3);
        for (int frame = 0; frame < 25; frame++) {
          expect(
            rgb[frame * 3 + (frame < 5 ? 0 : 2)],
            greaterThan(200),
            reason: 'frame $frame must follow the MPLS seam at 1.2 s',
          );
        }
      } finally {
        ffmpegPathOverride = previousOverride;
        setFfmpegBackendForTesting(null);
        await root.delete(recursive: true);
      }
    },
    skip: executable == null ? 'FUSHI_TEST_FFMPEG is not set' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
