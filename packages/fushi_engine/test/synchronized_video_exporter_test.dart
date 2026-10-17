import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show MiningClipFormat;
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart';
import 'package:test/test.dart';

void main() {
  test('same-source streams retain their original relative timestamps', () {
    final List<String> args = buildSynchronizedVideoClipArgs(
      videoPath: 'capture.mp4',
      startMs: 0,
      endMs: 2000,
      outputPath: 'card.mp4',
      maxWidth: 961,
    );
    expect(args[args.indexOf('-af') + 1], 'asetpts=PTS');
    expect(args[args.indexOf('-vf') + 1], startsWith('setpts=PTS,'));
    expect(args.where((arg) => arg == '-i'), hasLength(1));
    expect(args, contains('0:a:0'));
    expect(args, containsAllInOrder(['-map_chapters', '-1']));
    expect(
      args[args.indexOf('-vf') + 1],
      contains("scale=w='trunc(min(961,iw)/2)*2':h=-2"),
    );
  });

  test(
    'trimmed sentence audio starts at zero while picture uses source offset',
    () {
      final List<String> args = buildSynchronizedVideoClipArgs(
        videoPath: 'source.mkv',
        startMs: 4250,
        endMs: 7250,
        audioPath: 'sentence.mp3',
        audioStartMs: 0,
        outputPath: 'card.mp4',
      );
      expect(args.sublist(2, 10), <String>[
        '-ss',
        '4.250',
        '-t',
        '3.000',
        '-i',
        'source.mkv',
        '-ss',
        '0.000',
      ]);
      expect(args[args.indexOf('-af') + 1], 'asetpts=PTS-STARTPTS');
      expect(args[args.indexOf('-vf') + 1], startsWith('setpts=PTS-STARTPTS,'));
      expect(args, contains('1:a:0'));
      expect(args, isNot(contains('copy')));
      expect(args, isNot(contains('-an')));
      // #1951: FFmpeg 6.0 (mobile ffmpeg-kit) drops every frame of the raw ADTS
      // sentence audio under `-shortest`; both inputs are already `-t` bounded.
      expect(args, isNot(contains('-shortest')));
      expect(args.where((String a) => a == '-t'), hasLength(3));
      expect(
        args,
        containsAll(<String>['libx264', 'aac', 'yuv420p', '+faststart']),
      );
    },
  );

  test('remote input options belong to their own source', () {
    final List<String> args = buildSynchronizedVideoClipArgs(
      videoPath: 'https://video.test/movie',
      startMs: 1000,
      endMs: 2000,
      audioPath: 'https://audio.test/sound',
      outputPath: 'card.mp4',
      headers: <String, String>{'Authorization': 'video'},
      audioHeaders: <String, String>{'Authorization': 'audio'},
    );
    expect(
      args.indexOf('Authorization: video\r\n'),
      lessThan(args.indexOf('https://video.test/movie')),
    );
    expect(
      args.indexOf('Authorization: audio\r\n'),
      greaterThan(args.indexOf('https://video.test/movie')),
    );
    expect(
      args.indexOf('Authorization: audio\r\n'),
      lessThan(args.indexOf('https://audio.test/sound')),
    );
  });

  test('cue-less capture has no input seeks and crops before scaling', () {
    final List<String> args = buildSynchronizedVideoClipArgs(
      videoPath: 'capture.webm',
      startMs: 0,
      endMs: 3000,
      outputPath: 'card.mp4',
      decodeFromStart: true,
      cropFilter: 'crop=320:240:0:0',
    );
    expect(args, isNot(contains('-ss')));
    expect(
      args[args.indexOf('-vf') + 1],
      contains('crop=320:240:0:0,fps=24,scale='),
    );
  });

  test(
    'same-source input reuse preserves seek, selected track and downmix',
    () {
      final args = buildSynchronizedVideoClipArgs(
        videoPath: 'movie.mkv',
        audioPath: 'movie.mkv',
        startMs: 4321,
        endMs: 7321,
        outputPath: 'out.mp4',
        audioStreamIndex: 2,
        audioChannels: 1,
      );
      expect(args.where((arg) => arg == '-i'), hasLength(1));
      expect(args, containsAllInOrder(['-ss', '4.321', '-t', '3.000']));
      expect(args, contains('0:a:2'));
      expect(args, containsAllInOrder(['-ac', '1']));
      final filter = args[args.indexOf('-vf') + 1];
      expect(filter.indexOf('fps='), lessThan(filter.indexOf('scale=')));
    },
  );

  test(
    'same URL with a different seek or credentials keeps separate inputs',
    () {
      for (final args in [
        buildSynchronizedVideoClipArgs(
          videoPath: 'https://test/movie',
          audioPath: 'https://test/movie',
          startMs: 1000,
          endMs: 2000,
          audioStartMs: 0,
          outputPath: 'out.mp4',
        ),
        buildSynchronizedVideoClipArgs(
          videoPath: 'https://test/movie',
          audioPath: 'https://test/movie',
          startMs: 1000,
          endMs: 2000,
          headers: {'Authorization': 'video'},
          audioHeaders: {'Authorization': 'audio'},
          outputPath: 'out.mp4',
        ),
        buildSynchronizedVideoClipArgs(
          videoPath: 'https://test/movie',
          audioPath: 'https://test/movie',
          startMs: 1000,
          endMs: 2000,
          tlsPinSha256: 'video',
          audioTlsPinSha256: 'audio',
          outputPath: 'out.mp4',
        ),
      ]) {
        expect(args.where((arg) => arg == '-i'), hasLength(2));
        expect(args, contains('1:a:0'));
      }
    },
  );

  late Directory temp;
  late File source;
  late String output;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sync_video_test_');
    source = await File('${temp.path}/source').writeAsString('source');
    output = '${temp.path}/out.mp4';
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'encoder failure removes partial file and returns actual failure',
    () async {
      final _Backend backend = _Backend((List<String> args) async {
        await File(args.last).writeAsString('partial');
        return const FfmpegRunResult(
          returnCode: 1,
          output: 'Unknown encoder libx264',
        );
      });
      final VideoClipExportResult result = await exportSynchronizedVideoClip(
        videoPath: source.path,
        startMs: 0,
        endMs: 1000,
        outputPath: output,
        backend: backend,
      );
      expect(result.failure, VideoClipExportFailure.ffmpegFailed);
      expect(result.detail, contains('Unknown encoder libx264'));
      expect(File(output).existsSync(), isFalse);
    },
  );

  test('successful exit without media is not successful export', () async {
    final VideoClipExportResult result = await exportSynchronizedVideoClip(
      videoPath: source.path,
      startMs: 0,
      endMs: 1000,
      outputPath: output,
      backend: _Backend(
        (List<String> _) async =>
            const FfmpegRunResult(returnCode: 0, output: ''),
      ),
    );
    expect(result.failure, VideoClipExportFailure.outputMissing);
  });

  group('#1951 export must actually carry both streams', () {
    // ffmpeg-kit 6.0 (Android) prints the stats line without a prefix and in kB.
    const String ffmpeg6Stats =
        'frame=   76 fps=0.0 q=0.0 Lsize=      86kB time=00:00:03.16\n'
        'video:84kB audio:0kB subtitle:0kB other streams:0kB '
        'global headers:0kB muxing overhead: 2.1%\n';
    // 7.x prefixes the output and switched to KiB.
    const String ffmpeg7Stats =
        '[out#0/webm @ 000001d2] video:84KiB audio:25KiB subtitle:0KiB '
        'other streams:0KiB global headers:0KiB muxing overhead: 1.8%\n';

    Future<VideoClipExportResult> exportWithLog(String log) =>
        exportSynchronizedVideoClip(
          videoPath: source.path,
          startMs: 0,
          endMs: 1000,
          outputPath: output,
          backend: _Backend((List<String> args) async {
            // A real webm header alone is tens of KB; non-empty proves nothing.
            await File(args.last).writeAsString('webm header');
            return FfmpegRunResult(returnCode: 0, output: log);
          }),
        );

    test('parses both stats formats and ignores stream info lines', () {
      expect(parseFfmpegMuxedBytes(ffmpeg6Stats), (
        videoKiB: 84.0,
        audioKiB: 0.0,
      ));
      expect(parseFfmpegMuxedBytes(ffmpeg7Stats), (
        videoKiB: 84.0,
        audioKiB: 25.0,
      ));
      expect(
        parseFfmpegMuxedBytes('  Stream #1:0: Audio: aac (LC), 48000 Hz\n'),
        isNull,
      );
    });

    test(
      'declared audio track without audio data is a failed export',
      () async {
        final VideoClipExportResult result = await exportWithLog(ffmpeg6Stats);
        expect(result.isSuccess, isFalse);
        expect(result.failure, VideoClipExportFailure.outputMissing);
        expect(result.detail, contains('no audio data muxed'));
        expect(File(output).existsSync(), isFalse);
      },
    );

    test('missing video data is a failed export', () async {
      final VideoClipExportResult result = await exportWithLog(
        'video:0kB audio:25kB subtitle:0kB other streams:0kB\n',
      );
      expect(result.detail, contains('no video data muxed'));
      expect(File(output).existsSync(), isFalse);
    });

    test('no final stats means no evidence, not success', () async {
      final VideoClipExportResult result = await exportWithLog('');
      expect(result.failure, VideoClipExportFailure.outputMissing);
      expect(result.detail, contains('ffmpeg final stats missing'));
    });

    test('both streams muxed is success', () async {
      final VideoClipExportResult result = await exportWithLog(ffmpeg7Stats);
      expect(result.isSuccess, isTrue);
      expect(result.outputPath, output);
      expect(File(output).existsSync(), isTrue);
    });
  });

  group('#1951 real ffmpeg: ADTS sentence audio reaches the clip', () {
    final bool hasFfmpeg = () {
      try {
        return Process.runSync(resolveFfmpegExecutable(), <String>[
              '-version',
            ]).exitCode ==
            0;
      } on ProcessException {
        return false;
      }
    }();

    for (final MiningClipFormat format in <MiningClipFormat>[
      MiningClipFormat.webmVp9,
      MiningClipFormat.mp4H264,
    ]) {
      test(format.wireName, () async {
        final String ffmpeg = resolveFfmpegExecutable();
        final String video = '${temp.path}/source.mkv';
        // The production sentence audio on Android: a pre-trimmed raw ADTS file.
        final String audio = '${temp.path}/sentence.aac';
        expect(
          Process.runSync(ffmpeg, <String>[
            '-hide_banner', '-y', //
            '-f', 'lavfi', '-i', 'testsrc2=duration=12:size=320x240:rate=24',
            '-f', 'lavfi', '-i', 'sine=frequency=440:duration=12',
            '-c:v', 'libx264', '-g', '120', '-c:a', 'aac', video,
          ]).exitCode,
          0,
        );
        expect(
          Process.runSync(ffmpeg, <String>[
            '-hide_banner', '-y', '-ss', '6', '-t', '3', '-i', video, //
            '-vn', '-c:a', 'aac', '-f', 'adts', audio,
          ]).exitCode,
          0,
        );
        final String clip = '${temp.path}/clip.${format.fileExtension}';
        final VideoClipExportResult result = await exportSynchronizedVideoClip(
          videoPath: video,
          startMs: 6000,
          endMs: 9000,
          audioPath: audio,
          audioStartMs: 0,
          outputPath: clip,
          format: format,
        );
        expect(result.isSuccess, isTrue, reason: result.detail);
        final ProcessResult probe = Process.runSync(ffmpeg, <String>[
          '-hide_banner', '-i', clip, '-map', '0:a:0', //
          '-c', 'copy', '-f', 'framecrc', '-',
        ]);
        final int audioPackets = (probe.stdout as String)
            .split('\n')
            .where((String l) => l.trim().isNotEmpty && !l.startsWith('#'))
            .length;
        expect(audioPackets, greaterThan(0));
      }, skip: hasFfmpeg ? false : 'ffmpeg unavailable');
    }
  });

  test(
    'existing file cannot be overwritten or cleaned as partial output',
    () async {
      final VideoClipExportResult result = await exportSynchronizedVideoClip(
        videoPath: source.path,
        startMs: 0,
        endMs: 1000,
        outputPath: source.path,
        backend: _Backend(
          (List<String> _) async => throw StateError('must not run'),
        ),
      );
      expect(result.isSuccess, isFalse);
      expect(source.readAsStringSync(), 'source');
    },
  );
}

class _Backend implements FfmpegBackend {
  /// 查询类命令（BUG-2938 新增原语）：本假件不区分，交给 [run]。
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  _Backend(this.execute);
  final Future<FfmpegRunResult> Function(List<String>) execute;
  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      execute(args);
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}
