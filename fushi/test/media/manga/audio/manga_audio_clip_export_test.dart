// 漫画有声书「导出片段视频」（反馈 pZhONQTAap）：页图 + 句子音频走小说有声书同一条
// 合成管线（synthAudiobookClipVideoViaFfmpeg），这里钉住尺寸规则、ffmpeg 参数与每一步
// 失败的出口；ffmpeg 用假后端，不依赖本机可执行。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_clip_export.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_mining.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 记下参数、按要求写出产物并回 ffmpeg 收尾统计行的假后端。
class _FakeFfmpeg implements FfmpegBackend {
  _FakeFfmpeg({this.writeOutput = true, this.returnCode = 0});

  final bool writeOutput;
  final int returnCode;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    if (writeOutput) File(args.last).writeAsBytesSync(<int>[1, 2, 3]);
    return FfmpegRunResult(
      returnCode: returnCode,
      output: 'video:12kB audio:4kB subtitle:0kB',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _png(int width, int height) =>
    Uint8List.fromList(img.encodePng(img.Image(width: width, height: height)));

MangaMiningAudioClip _clip(String inputPath) => MangaMiningAudioClip(
  line: const MangaRenderedLine(
    lineId: 'p3b0',
    page: 3,
    blocks: <int>[0],
    speaker: 'A',
    kind: CastLineKind.spoken,
    beatMs: 0,
    file: 'p3b0.wav',
    durationMs: 1500,
    text: 'こんにちは',
  ),
  inputPath: inputPath,
  range: const AudioPlaybackRange(audioFileIndex: 7, startMs: 0, endMs: 1800),
);

String _arg(List<String> args, String flag) => args[args.indexOf(flag) + 1];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mangaClipVideoSize', () {
    test('保持页图比例、长边封顶 1920、两边取偶数', () {
      expect(mangaClipVideoSize(imageWidth: 1400, imageHeight: 2000), (
        width: 1344,
        height: 1920,
      ));
      expect(mangaClipVideoSize(imageWidth: 3001, imageHeight: 2001), (
        width: 1920,
        height: 1280,
      ));
    });

    test('小图不放大，奇数边向下取偶', () {
      expect(mangaClipVideoSize(imageWidth: 801, imageHeight: 1199), (
        width: 800,
        height: 1198,
      ));
    });

    test('极端长条与非法尺寸', () {
      expect(mangaClipVideoSize(imageWidth: 10, imageHeight: 20000).width, 2);
      expect(mangaClipVideoSize(imageWidth: 0, imageHeight: 100), (
        width: 1080,
        height: 1920,
      ));
    });
  });

  group('synthMangaAudioClipVideo', () {
    late Directory root;
    late Directory work;

    setUp(() {
      root = Directory.systemTemp.createTempSync('manga_clip_test_');
      work = Directory(p.join(root.path, 'work'));
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('页图 + 句子音频合成 mp4：区间、尺寸、JPEG 输入与显式双路映射', () async {
      final List<({String input, int start, int end})> extracted =
          <({String input, int start, int end})>[];
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
      final MangaAudioClipExportResult result = await synthMangaAudioClipVideo(
        pageBytes: _png(700, 1000),
        clip: _clip('/books/vol/p3b0.wav'),
        workDir: work,
        backend: ffmpeg,
        extractAudio:
            ({
              required String inputPath,
              required int startMs,
              required int endMs,
              required String outputPath,
            }) async {
              extracted.add((input: inputPath, start: startMs, end: endMs));
              File(outputPath).writeAsBytesSync(<int>[9]);
              return outputPath;
            },
      );

      expect(result.isSuccess, isTrue, reason: '${result.failure}');
      expect(result.videoPath, p.join(work.path, 'clip.mp4'));
      expect(File(result.videoPath!).existsSync(), isTrue);
      expect(extracted, <({String input, int start, int end})>[
        (input: '/books/vol/p3b0.wav', start: 0, end: 1800),
      ]);

      expect(ffmpeg.calls, hasLength(1));
      final List<String> args = ffmpeg.calls.single;
      expect(_arg(args, '-loop'), '1');
      expect(p.extension(_arg(args, '-i')), '.jpg');
      expect(
        args,
        containsAllInOrder(<String>['-map', '0:v:0', '-map', '1:a:0']),
      );
      expect(_arg(args, '-c:v'), 'libx264');
      expect(_arg(args, '-t'), '1.800');
      // 700×1000 小于上限，原尺寸（偶数）输出。
      expect(_arg(args, '-vf'), startsWith('scale=700:1000:'));

      // 中间产物（页图 JPEG / 裁出的音频）清掉，只留成品。
      expect(File(p.join(work.path, 'page.jpg')).existsSync(), isFalse);
      expect(File(p.join(work.path, 'clip.aac')).existsSync(), isFalse);
    });

    test('裁音频失败：不跑合成，报 audioClip', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
      final MangaAudioClipExportResult result = await synthMangaAudioClipVideo(
        pageBytes: _png(64, 96),
        clip: _clip('/missing.wav'),
        workDir: work,
        backend: ffmpeg,
        extractAudio:
            ({
              required String inputPath,
              required int startMs,
              required int endMs,
              required String outputPath,
            }) async => null,
      );
      expect(result.failure, MangaAudioClipExportFailure.audioClip);
      expect(ffmpeg.calls, isEmpty);
      expect(File(p.join(work.path, 'page.jpg')).existsSync(), isFalse);
    });

    test('页图解不开：不裁音频也不合成，报 pageImage', () async {
      bool extractCalled = false;
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
      final MangaAudioClipExportResult result = await synthMangaAudioClipVideo(
        pageBytes: Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5]),
        clip: _clip('/books/vol/p3b0.wav'),
        workDir: work,
        backend: ffmpeg,
        extractAudio:
            ({
              required String inputPath,
              required int startMs,
              required int endMs,
              required String outputPath,
            }) async {
              extractCalled = true;
              return outputPath;
            },
      );
      expect(result.failure, MangaAudioClipExportFailure.pageImage);
      expect(extractCalled, isFalse);
      expect(ffmpeg.calls, isEmpty);
    });

    test('ffmpeg 失败：报 synth 并带合成层的失败原因，不留半成品', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg(writeOutput: false, returnCode: 1);
      final MangaAudioClipExportResult result = await synthMangaAudioClipVideo(
        pageBytes: _png(64, 96),
        clip: _clip('/books/vol/p3b0.wav'),
        workDir: work,
        backend: ffmpeg,
        extractAudio:
            ({
              required String inputPath,
              required int startMs,
              required int endMs,
              required String outputPath,
            }) async {
              File(outputPath).writeAsBytesSync(<int>[9]);
              return outputPath;
            },
      );
      expect(result.failure, MangaAudioClipExportFailure.synth);
      expect(result.synthFailure, isNotNull);
      expect(File(p.join(work.path, 'clip.mp4')).existsSync(), isFalse);
      expect(File(p.join(work.path, 'clip.aac')).existsSync(), isFalse);
    });
  });
}
