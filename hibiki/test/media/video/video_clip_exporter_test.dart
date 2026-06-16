import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/media/video/video_clip_exporter.dart';

void main() {
  group('buildFfmpegVideoClipExportArgs', () {
    test(
        'maps video and the selected audio stream without subtitle/data streams',
        () {
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 1234,
        endMs: 6234,
        outputPath: '/video/clip.mkv',
        audioStreamIndex: 1,
      );

      expect(args, <String>[
        '-hide_banner',
        '-y',
        '-ss',
        '1.234',
        '-t',
        '5.000',
        '-i',
        '/video/source.mkv',
        '-map',
        '0:v:0',
        '-map',
        '0:a:1',
        '-sn',
        '-dn',
        '-c',
        'copy',
        '-avoid_negative_ts',
        'make_zero',
        '/video/clip.mkv',
      ]);
    });

    test('uses ffmpeg default audio selection when no explicit track is set',
        () {
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mp4',
        startMs: 0,
        endMs: 2000,
        outputPath: '/video/clip.mp4',
        audioStreamIndex: null,
      );

      expect(args.contains('-map'), isFalse);
      expect(args, contains('-sn'));
      expect(args, contains('-dn'));
      expect(args, isNot(contains('-filter_complex')));
      expect(args, isNot(contains('-vf')));
    });
  });

  group('exportVideoClipViaFfmpeg', () {
    test('rejects invalid ranges without running ffmpeg and removes leftovers',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_invalid');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mp4')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend();

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 5000,
        endMs: 5000,
        outputPath: output.path,
        backend: backend,
      );

      expect(result.failure, VideoClipExportFailure.invalidRange);
      expect(result.outputPath, isNull);
      expect(backend.calls, isEmpty);
      expect(output.existsSync(), isFalse);
    });

    test('runs ffmpeg and returns the output path on success', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_success');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mkv');
      late List<String> observedArgs;
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          observedArgs = args;
          output.writeAsBytesSync(<int>[9, 8, 7]);
          return const FfmpegRunResult(returnCode: 0, output: 'ok');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 1000,
        endMs: 2500,
        outputPath: output.path,
        audioStreamIndex: 2,
        backend: backend,
      );

      expect(result.isSuccess, isTrue);
      expect(result.outputPath, output.path);
      expect(
          observedArgs,
          containsAllInOrder(<String>[
            '-map',
            '0:v:0',
            '-map',
            '0:a:2',
            '-sn',
            '-dn',
            '-c',
            'copy',
          ]));
      expect(output.existsSync(), isTrue);
    });

    test('cleans partial output after ffmpeg failure', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_fail');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mkv');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          output.writeAsBytesSync(<int>[1, 2, 3]);
          return const FfmpegRunResult(returnCode: 1, output: 'boom');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 1000,
        outputPath: output.path,
        backend: backend,
      );

      expect(result.failure, VideoClipExportFailure.ffmpegFailed);
      expect(result.outputPath, isNull);
      expect(output.existsSync(), isFalse);
    });
  });
}

typedef _RunHandler = FutureOr<FfmpegRunResult> Function(List<String> args);

class _FakeFfmpegBackend implements FfmpegBackend {
  _FakeFfmpegBackend({this.onRun});

  final _RunHandler? onRun;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(List<String>.from(args));
    final _RunHandler? handler = onRun;
    if (handler == null) {
      return const FfmpegRunResult(returnCode: 0, output: '');
    }
    return Future<FfmpegRunResult>.value(handler(args));
  }
}
