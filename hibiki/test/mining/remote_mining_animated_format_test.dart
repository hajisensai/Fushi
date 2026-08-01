import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/immersion_capture_channel.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// BUG-1330：浏览器扩展的远端制卡（YouTube / Netflix）过去完全不读动图格式偏好，恒出 GIF。
///
/// 本文件钉死三件事：
/// 1. 降级链是**格式自身**的属性（`MiningAnimatedFormat.encodeAttempts`），三条链路共用；
/// 2. 换格式重试时 **fps / 宽度 / 扩展名一并换**（只换格式不换参数 = BUG-1039 复发）；
/// 3. 两条远端链路（YouTube 经 `ImmersionMiningRequest.animatedFormat`、Netflix 经
///    `transcodeClipToCapture`）都真正跟随偏好，且 Netflix 不再硬编码 `.gif`。

/// 记录一次抽取调用的实参（用来断言「格式与参数成对」）。
typedef _Call = ({
  String outputPath,
  int fps,
  int width,
  MiningAnimatedFormat format,
  bool diagnosticOnly,
});

/// 假抽取器：[succeedOn] 里的格式才「成功」（并真写出文件），其余返回 null 模拟编码器缺失。
class _FakeGifExtractor {
  _FakeGifExtractor({required this.succeedOn, this.writeFile = false});

  final Set<MiningAnimatedFormat> succeedOn;
  final bool writeFile;
  final List<_Call> calls = <_Call>[];

  Future<String?> call({
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
  }) async {
    calls.add((
      outputPath: outputPath,
      fps: fps,
      width: width,
      format: format,
      diagnosticOnly: diagnosticOnly,
    ));
    if (!succeedOn.contains(format)) return null;
    if (writeFile) {
      await File(outputPath).writeAsBytes(<int>[1, 2, 3], flush: true);
    }
    return outputPath;
  }
}

/// 顶格档（imageTier 3）的压缩参数——顶格档才是格式分叉点，低档三种格式同值。
MiningMediaCompression _topTier(MiningAnimatedFormat format) =>
    MiningMediaCompression.resolve(
      imageTier: 3,
      audioTier: 0,
      format: format,
    );

void main() {
  group('MiningAnimatedFormat.encodeAttempts（降级链下沉到格式自身）', () {
    test('非 GIF 格式 → [自身, gif]；GIF → 只有自己', () {
      expect(MiningAnimatedFormat.avif.encodeAttempts, <MiningAnimatedFormat>[
        MiningAnimatedFormat.avif,
        MiningAnimatedFormat.gif
      ]);
      expect(MiningAnimatedFormat.webp.encodeAttempts, <MiningAnimatedFormat>[
        MiningAnimatedFormat.webp,
        MiningAnimatedFormat.gif
      ]);
      expect(MiningAnimatedFormat.gif.encodeAttempts,
          <MiningAnimatedFormat>[MiningAnimatedFormat.gif],
          reason: 'GIF 是链尾兜底，没有更低一级可降；重试同一格式只是白等一次。');
    });

    test('链尾恒为 GIF —— 它是唯一在所有 ffmpeg 构建上都可用的编码器', () {
      for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
        expect(f.encodeAttempts.last, MiningAnimatedFormat.gif,
            reason: '$f 的降级链必须以 GIF 收尾，否则移动端 ffmpeg-kit（永远没有 '
                'libsvtav1/libwebp）会制不出封面。');
      }
    });
  });

  group('extractAnimatedClipWithFallback（格式与编码参数成对）', () {
    test('首选格式成功：扩展名与参数都取自首选格式，不再尝试 GIF', () async {
      final _FakeGifExtractor fake =
          _FakeGifExtractor(succeedOn: {MiningAnimatedFormat.avif});
      final AnimatedClipExtraction? out = await extractAnimatedClipWithFallback(
        format: MiningAnimatedFormat.avif,
        inputPath: '/in.mp4',
        startMs: 0,
        endMs: 4000,
        outputPathStem: '/tmp/clip',
        compression: _topTier(MiningAnimatedFormat.avif),
        extractor: fake.call,
      );

      expect(out, isNotNull);
      expect(out!.format, MiningAnimatedFormat.avif);
      expect(out.path, '/tmp/clip.avif');
      expect(fake.calls, hasLength(1));
      expect(fake.calls.single.format, MiningAnimatedFormat.avif);
      expect(fake.calls.single.fps, MiningAnimatedFormat.avif.maxTierFps);
      expect(fake.calls.single.width, MiningAnimatedFormat.avif.maxTierWidth);
      // 首选格式后面还挂着 GIF 兜底 → 它这一次万一失败也只是能力探测，故 diagnosticOnly。
      // （本用例里它成功了，这个标记只影响失败时的日志分级。）
      expect(fake.calls.single.diagnosticOnly, isTrue);
    });

    test('BUG-1039 陷阱：AVIF 顶格档失败降级 GIF 时，fps/宽度必须一并换回 GIF 封顶值', () async {
      final _FakeGifExtractor fake =
          _FakeGifExtractor(succeedOn: {MiningAnimatedFormat.gif});
      // 用户选 AVIF → 顶格档解析出 24fps/1440px。
      final MiningMediaCompression compression =
          _topTier(MiningAnimatedFormat.avif);
      expect(compression.gifFps, 24);
      expect(compression.gifWidth, 1440);

      final AnimatedClipExtraction? out = await extractAnimatedClipWithFallback(
        format: MiningAnimatedFormat.avif,
        inputPath: '/in.mp4',
        startMs: 0,
        endMs: 4000,
        outputPathStem: '/tmp/clip',
        compression: compression,
        extractor: fake.call,
      );

      expect(out, isNotNull);
      expect(out!.format, MiningAnimatedFormat.gif,
          reason: '返回的必须是**实际产出**格式，不是用户所选。');
      expect(out.path, '/tmp/clip.gif');

      expect(fake.calls, hasLength(2));
      final _Call first = fake.calls[0];
      final _Call second = fake.calls[1];

      expect(first.format, MiningAnimatedFormat.avif);
      expect(first.fps, 24);
      expect(first.width, 1440);
      expect(first.outputPath, '/tmp/clip.avif');
      expect(first.diagnosticOnly, isTrue,
          reason: '还有降级尝试在后面 → 这次失败是预期内的能力探测，不该进用户可见错误日志。');

      // ★ 核心断言：换格式必须换参数。沿用 24fps/1440px 喂给无帧间压缩的 GIF，
      //   正是 BUG-1039 实测 48.9 秒 / 54 MB / 撞 120 秒超时的那组配置。
      expect(second.format, MiningAnimatedFormat.gif);
      expect(second.fps, MiningAnimatedFormat.gif.maxTierFps,
          reason: '降级到 GIF 后 fps 必须夹回 GIF 自己的封顶值（12），不能沿用 AVIF 的 24。');
      expect(second.width, MiningAnimatedFormat.gif.maxTierWidth,
          reason: '降级到 GIF 后宽度必须夹回 960，不能沿用 AVIF 的 1440。');
      expect(second.outputPath, '/tmp/clip.gif',
          reason: '扩展名必须跟着换 —— ffmpeg 按扩展名选 muxer。');
      expect(second.diagnosticOnly, isFalse);
    });

    test('全部尝试失败 → null（调用方走下一级单帧降级）', () async {
      final _FakeGifExtractor fake =
          _FakeGifExtractor(succeedOn: const <MiningAnimatedFormat>{});
      final AnimatedClipExtraction? out = await extractAnimatedClipWithFallback(
        format: MiningAnimatedFormat.webp,
        inputPath: '/in.mp4',
        startMs: 0,
        endMs: 4000,
        outputPathStem: '/tmp/clip',
        compression: _topTier(MiningAnimatedFormat.webp),
        extractor: fake.call,
      );
      expect(out, isNull);
      expect(fake.calls.map((_Call c) => c.format), <MiningAnimatedFormat>[
        MiningAnimatedFormat.webp,
        MiningAnimatedFormat.gif
      ]);
    });

    test('低清晰度档：三种格式的参数一致（不按格式分叉），扩展名仍跟随格式', () async {
      final _FakeGifExtractor fake =
          _FakeGifExtractor(succeedOn: {MiningAnimatedFormat.avif});
      // 档 1（标准）：8fps/480px，低于任何格式的上限 → capFps/capWidth 代入后不变。
      final MiningMediaCompression std = MiningMediaCompression.resolve(
        imageTier: 1,
        audioTier: 0,
        format: MiningAnimatedFormat.avif,
      );
      await extractAnimatedClipWithFallback(
        format: MiningAnimatedFormat.avif,
        inputPath: '/in.mp4',
        startMs: 0,
        endMs: 4000,
        outputPathStem: '/tmp/clip',
        compression: std,
        extractor: fake.call,
      );
      expect(fake.calls.single.fps, 8);
      expect(fake.calls.single.width, 480);
      expect(fake.calls.single.outputPath, '/tmp/clip.avif');
    });
  });

  group('transcodeClipToCapture（Netflix 录制片段：不再硬编码 .gif）', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('bug1330_');
    });

    tearDown(() async {
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
    });

    /// 音频侧不参与本测试，注入一个恒失败的假件（避免真跑 ffmpeg）。
    Future<String?> noAudio({
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
        null;

    test('format: avif → 产出 .avif，结果带回 avif', () async {
      final _FakeGifExtractor fake = _FakeGifExtractor(
          succeedOn: {MiningAnimatedFormat.avif}, writeFile: true);
      final ImmersionCaptureResult cap = await transcodeClipToCapture(
        Uint8List.fromList(<int>[1, 2, 3, 4]),
        durationMs: 4000,
        compression: _topTier(MiningAnimatedFormat.avif),
        tempDir: tempRoot.path,
        format: MiningAnimatedFormat.avif,
        gifExtractor: fake.call,
        audioExtractor: noAudio,
      );

      expect(cap.ok, isTrue);
      expect(cap.gifBytes, isNotNull);
      expect(cap.animatedFormat, MiningAnimatedFormat.avif);
      expect(fake.calls.first.format, MiningAnimatedFormat.avif);
      expect(fake.calls.first.outputPath, endsWith('.avif'),
          reason: '改动前这里硬编码 clip.gif —— 扩展制卡恒出 GIF 的根因之一。');
      expect(fake.calls.first.outputPath, isNot(endsWith('clip.gif')));
    });

    test('移动端场景：AVIF 编码器缺失 → 降级 GIF，参数与扩展名一并换回', () async {
      final _FakeGifExtractor fake = _FakeGifExtractor(
          succeedOn: {MiningAnimatedFormat.gif}, writeFile: true);
      final ImmersionCaptureResult cap = await transcodeClipToCapture(
        Uint8List.fromList(<int>[1, 2, 3, 4]),
        durationMs: 4000,
        compression: _topTier(MiningAnimatedFormat.avif),
        tempDir: tempRoot.path,
        format: MiningAnimatedFormat.avif,
        gifExtractor: fake.call,
        audioExtractor: noAudio,
      );

      expect(cap.ok, isTrue);
      expect(cap.animatedFormat, MiningAnimatedFormat.gif,
          reason: '带回的必须是实际产出格式，否则封面名会拼成 .avif 里装 GIF 字节。');
      expect(fake.calls, hasLength(2));
      expect(fake.calls[1].fps, MiningAnimatedFormat.gif.maxTierFps);
      expect(fake.calls[1].width, MiningAnimatedFormat.gif.maxTierWidth);
      expect(fake.calls[1].outputPath, endsWith('.gif'));
    });

    test('默认 format（未传）仍是 GIF —— 既有调用点/测试逐字节等价', () async {
      final _FakeGifExtractor fake = _FakeGifExtractor(
          succeedOn: {MiningAnimatedFormat.gif}, writeFile: true);
      final ImmersionCaptureResult cap = await transcodeClipToCapture(
        Uint8List.fromList(<int>[1, 2, 3, 4]),
        durationMs: 4000,
        compression: MiningMediaCompression.resolve(imageTier: 1, audioTier: 0),
        tempDir: tempRoot.path,
        gifExtractor: fake.call,
        audioExtractor: noAudio,
      );
      expect(cap.animatedFormat, MiningAnimatedFormat.gif);
      expect(fake.calls, hasLength(1));
      expect(fake.calls.single.outputPath, endsWith('.gif'));
    });
  });

  group('源码扫描守卫：远端制卡入口必须把格式偏好同时喂给三处', () {
    String libFile(String relative) => File(relative).readAsStringSync();

    /// 剥掉注释再扫「不得出现」的字面量。散文里为解释 bug 必然会写出 `clip.gif` 这类
    /// 触发词，让文档把守卫扫红是假阳性；判据只应落在真实代码上。
    String codeOnly(String src) => src.split('\n').map((String line) {
          final int i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        }).join('\n');

    test('mineImmersion 读 videoMiningAnimatedFormat 并成对下发', () {
      final String src = libFile('lib/src/models/app_model.dart');
      // 只看 mineImmersion 这一段，避免别处的同名符号把守卫拖成自洽废话。
      final int start = src.indexOf('Future<RemoteMineResult> mineImmersion(');
      expect(start, greaterThan(0), reason: 'mineImmersion 改名了？守卫锚点失效，请同步更新。');
      final int end = src.indexOf('void recordHistory(', start);
      expect(end, greaterThan(start));
      // 剥注释：否则「解释这个 bug」的散文就能把守卫喂绿。
      final String body = codeOnly(src.substring(start, end));

      expect(body, contains('_appModel.videoMiningAnimatedFormat'),
          reason: '远端制卡（YouTube/Netflix）必须读用户的动图格式偏好。BUG-1330。');
      expect(body, contains('format: animatedFormat'),
          reason: 'MiningMediaCompression.resolve 与 transcodeClipToCapture 都要收 '
              'format —— 不传则顶格档退回 GIF 封顶值。BUG-1330。');
      expect(body, contains('animatedFormat: animatedFormat'),
          reason: 'YouTube 的 ImmersionMiningRequest 必须收 animatedFormat，否则值对象 '
              '默认 gif → 引擎降级链只有 [gif]，AVIF/WebP 永不触发。BUG-1330。');
      // 「格式与参数成对」：resolve 与编码侧必须是同一个变量，不能只接一半。
      expect(RegExp(r'format:\s*animatedFormat').allMatches(body).length,
          greaterThanOrEqualTo(2),
          reason:
              'resolve(format:) 与 transcodeClipToCapture(format:) 两处都要传同一个值；'
              '只传其一 = 格式与编码参数不成对 = BUG-1039 复发。');
    });

    test('Netflix 捕获链路不得再出现 .gif 硬编码', () {
      final String src =
          libFile('lib/src/mining/immersion_capture_channel.dart');
      final String code = codeOnly(src);
      expect(code.contains('clip.gif'), isFalse,
          reason: '动图输出路径的扩展名必须由实际尝试的格式补上（ffmpeg 按扩展名选 '
              'muxer）。BUG-1330。');
      expect(code.contains('netflix_clip.gif'), isFalse,
          reason: '封面文件名必须跟随 cap.animatedFormat；写死 .gif 会让 Netflix 卡 '
              '永远是 GIF。BUG-1330。');
      expect(src, contains('extractAnimatedClipWithFallback'),
          reason: 'Netflix 录制片段必须与 app 内视频/YouTube 共用同一条降级链，'
              '不再直接调 extractClipGifViaFfmpeg（那样没有换格式换参数的收口）。BUG-1330。');
      expect(src, contains('cap.animatedFormat.fileExtension'),
          reason: '封面扩展名取自实际产出格式。BUG-1330。');
    });

    test('三条链路共用 encodeAttempts，不各写一份三元表达式', () {
      for (final String path in <String>[
        'lib/src/mining/immersion_mining_engine.dart',
        'lib/src/mining/galgame_window_gif.dart',
      ]) {
        // 剥注释：两个文件的文档里都引用了 [MiningAnimatedFormat.encodeAttempts]，
        // 不剥的话即使代码退回各写一份三元表达式，守卫也照样绿。
        final String src = codeOnly(libFile(path));
        expect(src, contains('encodeAttempts'),
            reason: '$path 必须从 MiningAnimatedFormat.encodeAttempts 取降级链；'
                '各持一份拷贝迟早漂开，Netflix 那条就是漂到了「没有链」。BUG-1330。');
      }
    });
  });
}
