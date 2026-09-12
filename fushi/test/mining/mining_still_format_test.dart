import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:image/image.dart' as img;

import 'package:fushi/src/mining/immersion_capture_channel.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

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

  /// BUG-2366：每次尝试收到的 `diagnosticOnly`，与 [outputs] 同序。
  /// 非末次尝试必须是 true——那次失败是编码器能力探测，不是 app 出错。
  final List<bool> diagnosticFlags = <bool>[];

  /// BUG-2366（审查补）：每次尝试**有没有拿到 reporter**，与 [outputs] 同序。
  /// 只压 `diagnosticOnly` 不够：`_reportFfmpegFailure` 是先无条件
  /// `onFailure?.call(summary)` 再看 diagnosticOnly，于是能力探测的摘要照样会经
  /// `firstCoverFailure` 变成「封面已降级」toast 的理由与中止根因。非末次尝试
  /// 必须**收不到** reporter。
  final List<bool> hadReporter = <bool>[];

  Future<String?> call({
    required String inputPath,
    required String outputPath,
    double atSeconds = 10.0,
    bool decodeFromStart = false,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
    bool diagnosticOnly = false,
  }) async {
    outputs.add(outputPath);
    diagnosticFlags.add(diagnosticOnly);
    hadReporter.add(onFailure != null);
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
      // BUG-2366：移动端 ffmpeg-kit 是 --disable-zlib 构建，png 编码器根本不存在，
      // 所以上面那次 .png 失败在 Android/iOS 上是**每张卡都会发生**的常态，不是异常。
      // 它必须走诊断分节，不能计进用户可见错误日志（同 BUG-1867 的形态）。
      expect(frame.diagnosticFlags, <bool>[true, false],
          reason: '非末次编码尝试必须 diagnosticOnly=true、链尾必须 false；'
              '这条一旦反了，选 PNG 的移动端用户每制一张卡就多一条假错误');
      // 光有 diagnosticOnly 不够：reporter 也必须掐掉，否则摘要经 firstCoverFailure
      // 变成「封面已降级」toast 的理由与中止根因，用户照样看到 Unknown encoder 'png'。
      expect(frame.hadReporter, <bool>[false, true],
          reason: '能力探测那次不得拿到 onFailure reporter；链尾那次必须拿到');
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

    test('尺寸不超限 + 目标 jpeg + 入参 png → 重编码成 JPEG（gal 抓图那条链）', () {
      final Uint8List src =
          Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));
      final Uint8List out = downsampleCardScreenshot(src);
      expect(img.findFormatForData(out), img.ImageFormat.jpg,
          reason: 'gal 窗口抓图恒为 PNG；选 JPG 就必须真转码，不能靠改扩展名糊弄');
    });

    test('需要缩放 + 目标 png → 既缩了也编成 PNG', () {
      final Uint8List src = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 2400, height: 600)));
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

    // 认不出格式时的兜底**方向由调用点定**：视频侧入参是 media_kit 的 JPEG，gal 侧是
    // 窗口抓图的 PNG。给一个统一默认就会在其中一条链上写出「扩展名与字节不符」的卡，
    // 而且只在降采样解码失败时才现形。
    test('stillFormatOfBytes：认得的按字节走，认不出的按调用点声明的兜底走', () {
      final Uint8List junk = Uint8List.fromList(<int>[0, 1, 2]);
      expect(stillFormatOfBytes(junk, fallback: MiningStillFormat.jpg),
          MiningStillFormat.jpg);
      expect(stillFormatOfBytes(junk, fallback: MiningStillFormat.png),
          MiningStillFormat.png);
      expect(
          stillFormatOfBytes(_smallJpegBytes(),
              fallback: MiningStillFormat.png),
          MiningStillFormat.jpg,
          reason: '认得出就以字节为准，兜底不该越过真实格式');
      expect(
          stillFormatOfBytes(
              Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
              fallback: MiningStillFormat.jpg),
          MiningStillFormat.png);
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
      // BUG-2366：两条静图链共用 extractStillWithFallback，语义必须逐字一致——
      // 这条链（浏览器扩展录制片段）以前连 diagnosticOnly 这个参数都传不了。
      expect(frame.diagnosticFlags, <bool>[true, false],
          reason: '片段链与引擎链的降级语义必须同一份，不得再各写一遍循环');
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

  group('外部给定封面字节（gal 窗口抓图 / 浏览器扩展截图 / Netflix 2A 截图）', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('still_format_provided');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<AnkiMiningContext> mineProvided({
      required Uint8List cover,
      required String coverName,
      required MiningStillFormat stillFormat,
    }) async {
      final _FakeRepo repo = _FakeRepo();
      await ImmersionMiningEngine(
        gifExtractor: _nullGif,
        audioExtractor: _okAudio,
        frameExtractor: _FakeFrameExtractor().call,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.game,
          fields: const <String, String>{'expression': '走る'},
          clipStartMs: 0,
          clipEndMs: 0,
          sentence: 'テスト',
          requireAudio: false,
          providedCoverBytes: cover,
          providedCoverName: coverName,
          stillFormat: stillFormat,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo,
      );
      return repo.minedContext!;
    }

    test('gal 抓图是 PNG，用户选 JPG → 落盘转成 JPEG 且改名 .jpg', () async {
      final AnkiMiningContext ctx = await mineProvided(
        cover:
            Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
        coverName: 'external_window.png',
        stillFormat: MiningStillFormat.jpg,
      );
      expect(ctx.coverPath, endsWith('external_window.jpg'));
      expect(img.findFormatForData(File(ctx.coverPath!).readAsBytesSync()),
          img.ImageFormat.jpg);
    });

    test('用户选 PNG，扩展给的是 JPEG → 转成 PNG 且改名 .png', () async {
      final AnkiMiningContext ctx = await mineProvided(
        cover: _smallJpegBytes(),
        coverName: 'netflix_shot.jpg',
        stillFormat: MiningStillFormat.png,
      );
      expect(ctx.coverPath, endsWith('netflix_shot.png'),
          reason: '名字前缀是「这张图哪来的」的线索，只换扩展名');
      expect(img.findFormatForData(File(ctx.coverPath!).readAsBytesSync()),
          img.ImageFormat.png);
    });

    test('动图字节（GIF）绝不被当成静图转码', () async {
      final Uint8List gif =
          Uint8List.fromList(img.encodeGif(img.Image(width: 8, height: 8)));
      final AnkiMiningContext ctx = await mineProvided(
        cover: gif,
        coverName: 'external_window.gif',
        stillFormat: MiningStillFormat.png,
      );
      expect(ctx.coverPath, endsWith('external_window.gif'));
      expect(File(ctx.coverPath!).readAsBytesSync(), gif,
          reason: '动图格式由另一根轴负责，静图轴不得插手');
    });

    test('默认档（不传 stillFormat）→ 字节与文件名逐字不变', () async {
      final Uint8List png =
          Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));
      final _FakeRepo repo = _FakeRepo();
      await ImmersionMiningEngine(
        gifExtractor: _nullGif,
        audioExtractor: _okAudio,
        frameExtractor: _FakeFrameExtractor().call,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.game,
          fields: const <String, String>{'expression': 'x'},
          clipStartMs: 0,
          clipEndMs: 0,
          sentence: 's',
          requireAudio: false,
          providedCoverBytes: png,
          providedCoverName: 'external_window.png',
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo,
      );
      // 默认 jpg 会把 PNG 转成 JPEG —— 这正是 BUG-1473 之后 gal 静图的既有行为
      // （降采样重编码 JPEG），此处钉住的是「名字必须跟着变」。
      expect(repo.minedContext!.coverPath, endsWith('.jpg'));
    });

    test('providedCoverFileName：只换扩展名，动图/无名走历史默认', () {
      final Uint8List jpeg = _smallJpegBytes();
      expect(providedCoverFileName('netflix_frame.png', jpeg),
          'netflix_frame.jpg');
      expect(providedCoverFileName('external_window', jpeg),
          'external_window.jpg');
      expect(
          providedCoverFileName(
              'external_window.gif',
              Uint8List.fromList(
                  img.encodeGif(img.Image(width: 4, height: 4)))),
          'external_window.gif');
      expect(providedCoverFileName(null, Uint8List(0)), 'immersion_cover.gif');
    });

    test('transcodeCardScreenshot：目标一致 / 认不出 → 原样返回，不重编码', () {
      final Uint8List jpeg = _smallJpegBytes();
      expect(
          identical(
              transcodeCardScreenshot(jpeg,
                  encoding: CardScreenshotEncoding.jpeg),
              jpeg),
          isTrue);
      final Uint8List junk = Uint8List.fromList(<int>[1, 2, 3]);
      expect(
          identical(
              transcodeCardScreenshot(junk,
                  encoding: CardScreenshotEncoding.png),
              junk),
          isTrue);
    });
  });

  group('请求值对象', () {
    test('frozen() 保留 secondaryCueSentence（入队后不得丢副字幕例句）', () {
      const ImmersionMiningRequest req = ImmersionMiningRequest(
        source: AnkiMiningSource.video,
        fields: <String, String>{'expression': 'x'},
        clipStartMs: 0,
        clipEndMs: 1000,
        sentence: 's',
        secondaryCueSentence: 'translated',
      );
      expect(req.frozen().secondaryCueSentence, 'translated');
    });

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

  // BUG-2366 的根因是「同一条降级控制流被抄了两份，其中一份漏了规矩」。上面的行为
  // 断言只能证明**现有**两条链是对的，挡不住第三条链路明天再抄一遍。这条源码守卫
  // 直接钉死收口点：`MiningStillFormat.encodeAttempts` 在 lib/ 下只许被
  // `extractStillWithFallback` 消费。
  group('BUG-2366：静图降级链只有一个执行点', () {
    // 判据刻意**不区分**静图/动图两个枚举，也不看类型名：新链路完全可以写成
    // `final attempts = format.encodeAttempts;`（无类型名、无 `stillFormat` 字样），
    // 那正是本守卫要拦的形状，按类型名筛就会放它过去。改为「所有 encodeAttempts
    // 消费点必须落在钉死的文件白名单里」——换写法、换变量名、换枚举都逃不掉，
    // 新文件里出现一处就红。
    const Set<String> allowedConsumerFiles = <String>{
      // 两个收口原语（extractStillWithFallback / extractAnimatedClipWithFallback）
      'immersion_mining_engine.dart',
      // 既有状态：galgame 动图链自持一份循环（不在 BUG-2366 范围，但它是已知的
      // 第二个动图消费点，白名单显式记住它，而不是让判据默默放行一整类）。
      'galgame_window_gif.dart',
    };

    test('lib/ 下 encodeAttempts 的消费点不超出钉死的文件白名单', () {
      final Directory libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue,
          reason: '本守卫必须从 fushi/ 目录跑（相对路径 lib/）');

      final List<String> sites = <String>[];
      for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final List<String> lines = entity.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          // 只看真正的**执行**，不看注释里的 `[…encodeAttempts]` 交叉引用。
          final String code = lines[i].split('//').first;
          if (!code.contains('encodeAttempts')) continue;
          // 枚举自身的 getter 定义不是消费点。
          if (code.contains('get encodeAttempts')) continue;
          sites.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }

      // 反证：判据本身没有失真。一个都扫不到只能说明扫描写坏了。
      expect(sites, isNotEmpty,
          reason: 'lib/ 下一个 encodeAttempts 消费点都没扫到，扫描逻辑失真');

      final List<String> offenders = sites
          .where((String s) => !allowedConsumerFiles
              .any((String f) => s.contains('$f:')))
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'encodeAttempts 出现在白名单之外的文件里：\n${offenders.join('\n')}\n'
            '降级链必须走 extractStillWithFallback / extractAnimatedClipWithFallback ——'
            '各写一遍循环正是 BUG-2366：有一份漏了 diagnosticOnly 与 onFailure 掐断，'
            '移动端用户每制一张卡就多一条假错误。确有正当理由新增消费点，'
            '就在 allowedConsumerFiles 里显式登记，别把断言删掉。',
      );
    });

    test('静图那条链的唯一消费点在收口原语所在文件', () {
      final List<String> stillSites = File(
        'lib/src/mining/immersion_mining_engine.dart',
      )
          .readAsLinesSync()
          .where((String l) =>
              l.split('//').first.contains('MiningStillFormat> attempts'))
          .toList();
      expect(stillSites, hasLength(1),
          reason: 'MiningStillFormat.encodeAttempts 的展开只应出现在 '
              'extractStillWithFallback 里一次');
    });
  });
}
