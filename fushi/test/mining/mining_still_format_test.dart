import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:image/image.dart' as img;

import 'package:fushi/src/mining/immersion_capture_channel.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';
import 'package:fushi/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';

/// 制卡封面**静图格式**（`video_mining_still_format`）：用户选「制卡时截图 / 字幕开头截图」
/// 后，那张图过去被硬编码成 JPEG（`immersion_frame.jpg` / `immersion_shot.jpg` /
/// `clip_frame.jpg`），设置里也没有任何入口。
///
/// 本文件钉死五件事：
/// 1. 偏好解析：未设过 / 未知历史值 → jpg（现状零破坏）；
/// 2. 两条静图产出链（ffmpeg 抽帧、Dart 截图降采样）的**扩展名跟随偏好**；
/// 3. 首选格式失败时按 [MiningStillFormat.encodeAttempts] 退回 JPEG，而不是丢掉整张封面；
/// 4. 扩展名跟随**实际字节**而非所选格式（不写出 `.png` 里装 JPEG 的卡）；
/// 5. 不传 stillFormat 的调用点（含所有旧测试）逐字节等价于改动前。
class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;

  @override
  Future<MineOutcome> mineEntry(
      {required String rawPayloadJson,
      required AnkiMiningContext context}) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 只接受 [accept] 这一种扩展名的假抽取器（模拟「捆绑 ffmpeg 没有 png 编码器」）。
class _FakeFrameExtractor {
  _FakeFrameExtractor({this.accept});

  /// null = 什么扩展名都成功。
  final String? accept;
  final List<String> outputs = <String>[];

  Future<String?> call({
    required String inputPath,
    required String outputPath,
    double atSeconds = 10.0,
    bool decodeFromStart = false,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
  }) async {
    outputs.add(outputPath);
    if (accept != null && !outputPath.endsWith(accept!)) return null;
    final File out = File(outputPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(<int>[1, 2, 3, 4]);
    return outputPath;
  }
}

Future<String?> _okAudio({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  FfmpegFailureReporter? onFailure,
  int audioChannels = 1,
  String audioBitrate = '64k',
  String? tlsPinSha256,
}) async =>
    outputPath;

/// Netflix 那条链会把产物 `readAsBytes` 回来，故假件必须真落盘（引擎那条只传路径）。
Future<String?> _okAudioOnDisk({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  FfmpegFailureReporter? onFailure,
  int audioChannels = 1,
  String audioBitrate = '64k',
  String? tlsPinSha256,
}) async {
  final File out = File(outputPath);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(<int>[9, 9, 9]);
  return outputPath;
}

Future<String?> _nullGif({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int fps = 8,
  int width = 320,
  MiningAnimatedFormat format = MiningAnimatedFormat.gif,
  bool diagnosticOnly = false,
  FfmpegFailureReporter? onFailure,
  String? tlsPinSha256,
}) async =>
    null;

/// 一张真 JPEG（media_kit 的 `controller.screenshot` 给的就是 `image/jpeg`）。尺寸刻意小于
/// 降采样长边阈值 —— 「不需要缩放」正是旧实现原样返回入参、把 JPEG 写进 `.png` 的那条路。
Uint8List _smallJpegBytes() =>
    Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));

void main() {
  group('MiningStillFormat（偏好解析与降级链）', () {
    test('未设过 / 未知历史值 → jpg（现状零破坏）', () {
      expect(MiningStillFormat.fromWireName(null), MiningStillFormat.jpg);
      expect(MiningStillFormat.fromWireName('avif'), MiningStillFormat.jpg);
      expect(MiningStillFormat.fromWireName(''), MiningStillFormat.jpg);
    });

    test('wireName 是持久化契约，解析可逆', () {
      for (final MiningStillFormat f in MiningStillFormat.values) {
        expect(MiningStillFormat.fromWireName(f.wireName), f);
      }
      expect(MiningStillFormat.jpg.wireName, 'jpg');
      expect(MiningStillFormat.png.wireName, 'png');
    });

    test('encodeAttempts：png 退 jpg，jpg 是链尾（不自我重试）', () {
      expect(MiningStillFormat.png.encodeAttempts,
          <MiningStillFormat>[MiningStillFormat.png, MiningStillFormat.jpg]);
      expect(MiningStillFormat.jpg.encodeAttempts,
          <MiningStillFormat>[MiningStillFormat.jpg]);
    });
  });

  group('引擎：ffmpeg 抽帧扩展名跟随偏好', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('still_format');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<AnkiMiningContext> mine({
      MiningStillFormat? stillFormat,
      required _FakeFrameExtractor frame,
    }) async {
      final _FakeRepo repo = _FakeRepo();
      await ImmersionMiningEngine(
        gifExtractor: _nullGif,
        audioExtractor: _okAudio,
        frameExtractor: frame.call,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.video,
          fields: const <String, String>{'expression': '走る'},
          mediaSource: '/fake/video.mp4',
          clipStartMs: 1000,
          clipEndMs: 3000,
          sentence: '走り出した。',
          imageMode: VideoMiningImageMode.subtitleStart,
          stillFormat: stillFormat ?? MiningStillFormat.jpg,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo,
      );
      return repo.minedContext!;
    }

    test('默认（不传）→ .jpg，与改动前逐字等价', () async {
      final _FakeFrameExtractor frame = _FakeFrameExtractor();
      final AnkiMiningContext ctx = await mine(frame: frame);
      expect(ctx.coverPath, endsWith('immersion_frame.jpg'));
      expect(frame.outputs.length, 1, reason: 'jpg 是链尾，不该有第二次尝试');
    });

    test('选 png → .png（ffmpeg 按扩展名选编码器）', () async {
      final _FakeFrameExtractor frame = _FakeFrameExtractor();
      final AnkiMiningContext ctx =
          await mine(stillFormat: MiningStillFormat.png, frame: frame);
      expect(ctx.coverPath, endsWith('immersion_frame.png'));
      expect(frame.outputs.single, endsWith('.png'));
    });

    test('png 编码器缺失 → 退回 .jpg，封面不丢', () async {
      final _FakeFrameExtractor frame = _FakeFrameExtractor(accept: '.jpg');
      final AnkiMiningContext ctx =
          await mine(stillFormat: MiningStillFormat.png, frame: frame);
      expect(ctx.coverPath, endsWith('immersion_frame.jpg'),
          reason: '降级后扩展名必须跟随实际产出，不能还写 .png');
      expect(frame.outputs, hasLength(2));
      expect(frame.outputs.first, endsWith('.png'));
      expect(frame.outputs.last, endsWith('.jpg'));
    });
  });

  group('引擎：当前解码帧（Dart 降采样链）扩展名与字节格式一致', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('still_format_shot');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<AnkiMiningContext> mineShot(MiningStillFormat format) async {
      final _FakeRepo repo = _FakeRepo();
      await ImmersionMiningEngine(
        gifExtractor: _nullGif,
        audioExtractor: _okAudio,
        // 无 mediaSource → 只剩当前解码帧这一条封面来源。
        frameExtractor: _FakeFrameExtractor().call,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.video,
          fields: const <String, String>{'expression': '走る'},
          clipStartMs: 1000,
          clipEndMs: 3000,
          sentence: '走り出した。',
          requireAudio: false,
          imageMode: VideoMiningImageMode.currentFrame,
          stillFormat: format,
          stillFallback: () async => _smallJpegBytes(),
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo,
      );
      return repo.minedContext!;
    }

    test('默认 jpg → immersion_shot.jpg 且字节是 JPEG', () async {
      final AnkiMiningContext ctx = await mineShot(MiningStillFormat.jpg);
      expect(ctx.coverPath, endsWith('immersion_shot.jpg'));
      expect(img.findFormatForData(File(ctx.coverPath!).readAsBytesSync()),
          img.ImageFormat.jpg);
    });

    test('选 png → immersion_shot.png 且字节真是 PNG（不是改名的 JPEG）', () async {
      final AnkiMiningContext ctx = await mineShot(MiningStillFormat.png);
      expect(ctx.coverPath, endsWith('immersion_shot.png'));
      expect(img.findFormatForData(File(ctx.coverPath!).readAsBytesSync()),
          img.ImageFormat.png,
          reason: 'Anki 按扩展名判 MIME：.png 里装 JPEG 字节会显示不出封面');
    });
  });

  group('降采样器：目标格式与「只缩不放」捷径的相互作用', () {
    test('尺寸不超限 + 目标 jpeg + 入参 jpeg → 原样返回（旧行为逐字节不变）', () {
      final Uint8List src = _smallJpegBytes();
      final Uint8List out = downsampleCardScreenshot(src);
      expect(identical(out, src), isTrue);
    });

    test('尺寸不超限 + 目标 png + 入参 jpeg → 仍然重编码成 PNG', () {
      final Uint8List src = _smallJpegBytes();
      final Uint8List out = downsampleCardScreenshot(
        src,
        encoding: CardScreenshotEncoding.png,
      );
      expect(img.findFormatForData(out), img.ImageFormat.png);
    });

    test('需要缩放 + 目标 png → 既缩了也编成 PNG', () {
      final Uint8List src =
          Uint8List.fromList(img.encodeJpg(img.Image(width: 2400, height: 600)));
      final Uint8List out = downsampleCardScreenshot(
        src,
        maxLongEdge: 1000,
        encoding: CardScreenshotEncoding.png,
      );
      expect(img.findFormatForData(out), img.ImageFormat.png);
      expect(img.decodeImage(out)!.width, 1000);
    });

    test('cardScreenshotEncodingOf：认得 jpeg/png，其余（含 GIF）返 null', () {
      expect(cardScreenshotEncodingOf(_smallJpegBytes()),
          CardScreenshotEncoding.jpeg);
      expect(
          cardScreenshotEncodingOf(Uint8List.fromList(
              img.encodePng(img.Image(width: 4, height: 4)))),
          CardScreenshotEncoding.png);
      expect(
          cardScreenshotEncodingOf(Uint8List.fromList(
              img.encodeGif(img.Image(width: 4, height: 4)))),
          isNull);
    });

    test('stillFormatOfBytes：无法识别的字节按 jpg 落地（与改动前同名）', () {
      expect(stillFormatOfBytes(Uint8List.fromList(<int>[0, 1, 2])),
          MiningStillFormat.jpg);
    });
  });

  group('Netflix 录制片段：静图格式随结果带回并决定文件名', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('still_format_nf');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<ImmersionCaptureResult> transcode({
      required MiningStillFormat stillFormat,
      required _FakeFrameExtractor frame,
    }) =>
        transcodeClipToCapture(
          Uint8List.fromList(<int>[1, 2, 3]),
          durationMs: 4000,
          compression: MiningMediaCompression.compressed,
          tempDir: tmp.path,
          stillFormat: stillFormat,
          stillTarget: (offsetMs: 2000, exact: true),
          audioExtractor: _okAudioOnDisk,
          frameExtractor: frame.call,
        );

    test('选 png → clip_frame.png，结果带回 png', () async {
      final _FakeFrameExtractor frame = _FakeFrameExtractor();
      final ImmersionCaptureResult cap =
          await transcode(stillFormat: MiningStillFormat.png, frame: frame);
      expect(cap.coverIsStill, isTrue);
      expect(cap.stillFormat, MiningStillFormat.png);
      expect(frame.outputs.single, endsWith('clip_frame.png'));
    });

    test('png 失败 → 退 jpg，结果带回的是**实际**格式', () async {
      final _FakeFrameExtractor frame = _FakeFrameExtractor(accept: '.jpg');
      final ImmersionCaptureResult cap =
          await transcode(stillFormat: MiningStillFormat.png, frame: frame);
      expect(cap.coverIsStill, isTrue);
      expect(cap.stillFormat, MiningStillFormat.jpg);
      expect(frame.outputs, hasLength(2));
    });

    test('buildImmersionRequest：静态帧封面名跟随 cap.stillFormat', () {
      final ImmersionMinePayload payload = ImmersionMinePayload(
        fields: const <String, String>{'word': 'x'},
        sentence: 's',
        clipBytes: Uint8List.fromList(<int>[1]),
      );
      final ImmersionMiningRequest png = buildImmersionRequest(
        payload,
        ImmersionCaptureResult(
          gifBytes: Uint8List.fromList(<int>[0x89, 0x50]),
          audioBytes: Uint8List.fromList(<int>[1]),
          coverIsStill: true,
          stillFormat: MiningStillFormat.png,
        ),
        audioExpected: true,
      );
      expect(png.providedCoverName, 'netflix_frame.png');

      final ImmersionMiningRequest jpg = buildImmersionRequest(
        payload,
        ImmersionCaptureResult(
          gifBytes: Uint8List.fromList(<int>[0xFF, 0xD8]),
          audioBytes: Uint8List.fromList(<int>[1]),
          coverIsStill: true,
        ),
        audioExpected: true,
      );
      expect(jpg.providedCoverName, 'netflix_frame.jpg',
          reason: '默认档必须与改动前逐字一致');
    });
  });

  group('请求值对象', () {
    test('frozen() 保留 stillFormat（入队后不得丢偏好）', () {
      const ImmersionMiningRequest req = ImmersionMiningRequest(
        source: AnkiMiningSource.video,
        fields: <String, String>{'expression': 'x'},
        clipStartMs: 0,
        clipEndMs: 1000,
        sentence: 's',
        stillFormat: MiningStillFormat.png,
      );
      expect(req.frozen().stillFormat, MiningStillFormat.png);
    });

    test('默认值是 jpg（没显式指定的调用点/测试等价于改动前）', () {
      const ImmersionMiningRequest req = ImmersionMiningRequest(
        source: AnkiMiningSource.video,
        fields: <String, String>{'expression': 'x'},
        clipStartMs: 0,
        clipEndMs: 1000,
        sentence: 's',
      );
      expect(req.stillFormat, MiningStillFormat.jpg);
    });
  });
}
