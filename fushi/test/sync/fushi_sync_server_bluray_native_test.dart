import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_remote_title.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

import '../media/video/bluray_fixture.dart';

// Opt-in end-to-end regression for interconnect Blu-ray playback: a real host
// serves a synthetic disc, and a real libmpv client (FUSHI_TEST_MPV = mpv
// executable) plays what /streamurl hands out — the clip EDL for direct play
// and the HLS playlist for transcoding. FUSHI_TEST_FFMPEG must be a full build
// (lavfi + libx264 make the fixture; it also runs the host transcoder), and
// FUSHI_FFPROBE an ffprobe (the host probes ordinary videos' duration with it).
class _DiscLibrary implements FushiLibraryHostService {
  _DiscLibrary(this.playlist, this.lateAudio);

  final File playlist;

  /// 普通视频，音轨比画面晚 0.1 s 开始。
  final File lateAudio;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      switch (id) {
        'disc' => playlist,
        'late' => lateAudio,
        _ => null,
      };

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async => null;

  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      const AggregateSnapshot();

  @override
  Future<CollectionManifest> getCollectionManifest() async =>
      CollectionManifest.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  final String? ffmpeg = Platform.environment['FUSHI_TEST_FFMPEG'];
  final String? mpv = Platform.environment['FUSHI_TEST_MPV'];
  final String? ffprobe = Platform.environment['FUSHI_FFPROBE'];
  const String token = 'native-bluray-token';

  test(
    'a real libmpv client plays a host Blu-ray title (EDL and transcoded HLS)',
    () async {
      final Directory root = await Directory.systemTemp.createTemp('bd-e2e-');
      final String? previousOverride = ffmpegPathOverride;
      ffmpegPathOverride = ffmpeg;
      setFfmpegBackendForTesting(null);
      setTranscodeSegmentRunnerForTesting(null);
      FushiSyncServer? server;
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
          final ProcessResult made = await Process.run(ffmpeg!, <String>[
            '-hide_banner', '-loglevel', 'error', '-y', //
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
        // Title: red [10.4, 11.6) then blue [11.2, 12.8) — seam at 1.2 s.
        final File playlist = File(p.join(lists.path, '00001.mpls'));
        await playlist.writeAsBytes(
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
        final File lateAudio = File(p.join(root.path, 'late.mkv'));
        final ProcessResult late = await Process.run(ffmpeg!, <String>[
          '-hide_banner', '-loglevel', 'error', '-y', //
          '-f', 'lavfi', '-i', 'color=c=green:s=64x64:r=25:d=4', //
          '-itsoffset', '0.1', '-f', 'lavfi',
          '-i', 'sine=frequency=440:sample_rate=48000:duration=3.9',
          '-c:v', 'libx264', '-g', '25', '-c:a', 'aac', lateAudio.path,
        ]);
        expect(late.exitCode, 0, reason: '${late.stderr}');
        server = FushiSyncServer(
          syncDataDir: (await root.createTemp('sync')).path,
          port: 0,
          token: token,
          libraryService: _DiscLibrary(playlist, lateAudio),
        );
        await server.start();
        final String base = 'http://127.0.0.1:${server.port}';
        final HttpClient http = HttpClient();
        Future<Map<String, dynamic>> streamUrl(
          String query, {
          String id = 'disc',
        }) async {
          final HttpClientRequest req = await http.getUrl(
            Uri.parse('$base/api/library/videos/$id/streamurl$query'),
          );
          req.headers.set(
            'authorization',
            'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
          );
          final HttpClientResponse res = await req.close();
          return jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
        }

        /// Plays [uri] from [startSeconds] and returns each frame's dominant
        /// channel ('r' / 'b').
        Future<List<String>> play(String uri, double startSeconds) async {
          final Directory frames = await root.createTemp('frames');
          final ProcessResult ran = await Process.run(mpv!, <String>[
            '--no-config',
            '--vo=image',
            '--vo-image-format=png',
            '--vo-image-outdir=${frames.path}',
            '--ao=null',
            '--untimed',
            '--framedrop=no',
            '--hr-seek=yes',
            '--start=$startSeconds',
            '--msg-level=all=warn',
            '--log-file=${frames.path}.log',
            uri,
          ]);
          expect(ran.exitCode, 0, reason: '${ran.stdout}\n${ran.stderr}');
          expect(
            frames.listSync(),
            isNotEmpty,
            reason:
                'mpv rendered nothing for $uri:\n'
                '${File('${frames.path}.log').readAsStringSync()}',
          );
          final List<File> images = frames.listSync().whereType<File>().toList()
            ..sort((File a, File b) => a.path.compareTo(b.path));
          final List<String> colors = <String>[];
          for (final File image in images) {
            final ProcessResult rgb = await Process.run(ffmpeg, <String>[
              '-hide_banner', '-loglevel', 'error', '-i', image.path, //
              '-vf', 'scale=1:1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-',
            ], stdoutEncoding: null);
            final Uint8List px = Uint8List.fromList(rgb.stdout as List<int>);
            colors.add(px[0] > px[2] ? 'r' : 'b');
          }
          return colors;
        }

        // Direct play: the client builds the clip EDL exactly like local discs.
        final BlurayRemoteTitle title = BlurayRemoteTitle.fromJson(
          (await streamUrl(''))['discTitle'],
        )!;
        final List<String> whole = await play(title.edlUri(), 0);
        expect(whole, isNotEmpty);
        expect(whole.first, 'r');
        expect(whole.last, 'b');
        final int seam = whole.indexOf('b');
        expect(whole.sublist(0, seam), everyElement('r'));
        expect(whole.sublist(seam), everyElement('b'));
        // ≈ 1.2 s : 1.6 s of the title (vo=image keeps every other frame).
        expect(seam / whole.length, closeTo(1.2 / 2.8, 0.06));
        final List<String> sought = await play(title.edlUri(), 1.5);
        expect(sought, isNotEmpty);
        expect(
          sought,
          everyElement('b'),
          reason: 'seek past the seam over HTTP',
        );

        // Transcoded HLS from the same title (host runs the Blu-ray rewrite).
        final Map<String, dynamic> hls = await streamUrl(
          '?maxWidth=64&maxBitrate=500000',
        );
        expect(hls['transcoded'], isTrue);
        final List<String> transcoded = await play(hls['url'] as String, 0);
        expect(transcoded.first, 'r');
        expect(transcoded.last, 'b');
        final List<String> transcodedSought = await play(
          hls['url'] as String,
          1.5,
        );
        expect(transcodedSought, everyElement('b'));

        // Not Blu-ray specific: an ordinary source whose audio starts after the
        // picture must stay seekable once transcoded (the HLS DTS gate).
        final Map<String, dynamic> lateHls = await streamUrl(
          '?maxWidth=64&maxBitrate=500000',
          id: 'late',
        );
        expect(lateHls['transcoded'], isTrue);
        expect(await play(lateHls['url'] as String, 1.5), isNotEmpty);
        http.close(force: true);
      } finally {
        await server?.stop();
        ffmpegPathOverride = previousOverride;
        setFfmpegBackendForTesting(null);
        await root.delete(recursive: true);
      }
    },
    skip: ffmpeg == null || mpv == null || ffprobe == null
        ? 'FUSHI_TEST_FFMPEG, FUSHI_TEST_MPV and FUSHI_FFPROBE are not set'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
