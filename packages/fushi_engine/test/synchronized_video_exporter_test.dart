import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
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
    expect(args[args.indexOf('-vf') + 1], contains('crop=320:240:0:0,scale='));
  });

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
  _Backend(this.execute);
  final Future<FfmpegRunResult> Function(List<String>) execute;
  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      execute(args);
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}
