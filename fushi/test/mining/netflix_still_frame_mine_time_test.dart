import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_capture_channel.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';

/// BUG-1416：Netflix（沉浸捕获）选「静态帧」时，取的必须是**制卡那一刻**对应时间点的帧。
///
/// 用户拍板：「肯定是按制卡时候的时间来，不要后续点击再回来制卡」。这否掉了「取录制片段
/// 首帧」这个看着合理的做法 —— 片段是回放录制的，t=0 是句首（还带 200ms 提前量 + 起播推进
/// 量），离用户按下制卡键那一刻可以差好几秒。
///
/// 本文件钉死五件事：
/// 1. 静态帧偏好下产出的是**单帧**，根本不进动图编码链；
/// 2. 取的帧按**制卡时刻**定位，不是片段首帧；
/// 3. 片段时间基锚点与句首**有偏移**时仍取对（锚点是实测下发的，不是假设等于句首）；
/// 4. 动图偏好（默认档）逐字节不受影响；
/// 5. 取帧走 `decodeFromStart`（录制片段是无 Cues 索引的 MediaRecorder webm，输入定位会
///    落到最近关键帧 —— 那正是「不许默默拿最近的关键帧糊弄」禁止的做法）。

/// 记录一次单帧抽取调用的实参。
typedef _FrameCall = ({
  String inputPath,
  String outputPath,
  double atSeconds,
  bool decodeFromStart,
});

class _FakeFrameExtractor {
  _FakeFrameExtractor({this.succeed = true});

  final bool succeed;
  final List<_FrameCall> calls = <_FrameCall>[];

  Future<String?> call({
    required String inputPath,
    required String outputPath,
    double atSeconds = 10.0,
    bool decodeFromStart = false,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
  }) async {
    calls.add((
      inputPath: inputPath,
      outputPath: outputPath,
      atSeconds: atSeconds,
      decodeFromStart: decodeFromStart,
    ));
    if (!succeed) return null;
    final File out = File(outputPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 0xE0]);
    return outputPath;
  }
}

class _FakeGifExtractor {
  final List<String> outputs = <String>[];

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
    outputs.add(outputPath);
    final File out = File(outputPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6]);
    return outputPath;
  }
}

/// 音频侧不参与取帧断言，但必须照抽（静态帧模式不该把音频一起砍掉）。
class _FakeAudioExtractor {
  int calls = 0;

  Future<String?> call({
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
    calls++;
    final File out = File(outputPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(<int>[9, 9, 9]);
    return outputPath;
  }
}

void main() {
  group('resolveClipStillTarget（纯函数：视频时间 → 片段内偏移）', () {
    test('currentFrame：按制卡那一刻定位，不是片段起点', () {
      final ClipStillTarget? t = resolveClipStillTarget(
        imageMode: VideoMiningImageMode.currentFrame,
        clipAnchorMs: 10000,
        cueStartMs: 10200,
        mineAtMs: 12500,
        durationMs: 6000,
      );
      expect(t, isNotNull);
      expect(t!.offsetMs, 2500,
          reason: '制卡时刻 12500 − 片段锚点 10000 = 2500ms。取 0（首帧）就是用户否掉的做法。');
      expect(t.exact, isTrue);
    });

    test('subtitleStart：按真句首定位（句首≠片段起点，录制带 200ms 提前量）', () {
      final ClipStillTarget? t = resolveClipStillTarget(
        imageMode: VideoMiningImageMode.subtitleStart,
        clipAnchorMs: 10000,
        cueStartMs: 10200,
        mineAtMs: 12500,
        durationMs: 6000,
      );
      expect(t!.offsetMs, 200);
      expect(t.exact, isTrue);
    });

    test('gif（默认档）→ null，调用方走既有动图链', () {
      expect(
        resolveClipStillTarget(
          imageMode: VideoMiningImageMode.gif,
          clipAnchorMs: 10000,
          cueStartMs: 10200,
          mineAtMs: 12500,
          durationMs: 6000,
        ),
        isNull,
      );
    });

    test('老版扩展没发时间信息 → 仍出静态帧（用户选的就是静态帧），但标记 exact=false', () {
      final ClipStillTarget? t = resolveClipStillTarget(
        imageMode: VideoMiningImageMode.currentFrame,
        clipAnchorMs: null,
        cueStartMs: null,
        mineAtMs: null,
        durationMs: 6000,
      );
      expect(t, isNotNull);
      expect(t!.offsetMs, 0);
      expect(t.exact, isFalse,
          reason: '拿不到时刻就退片段起点，但必须标出来 —— 调用方据此写诊断日志，不静默糊弄。');
    });

    test('脏输入夹到 [0, durationMs]，不产生负偏移/越界偏移', () {
      expect(
        resolveClipStillTarget(
          imageMode: VideoMiningImageMode.currentFrame,
          clipAnchorMs: 10000,
          cueStartMs: 10200,
          mineAtMs: 9000,
          durationMs: 6000,
        )!
            .offsetMs,
        0,
      );
      expect(
        resolveClipStillTarget(
          imageMode: VideoMiningImageMode.currentFrame,
          clipAnchorMs: 10000,
          cueStartMs: 10200,
          mineAtMs: 99000,
          durationMs: 6000,
        )!
            .offsetMs,
        6000,
      );
    });
  });

  group('transcodeClipToCapture：静态帧模式', () {
    late Directory tempRoot;
    late _FakeFrameExtractor frame;
    late _FakeGifExtractor gif;
    late _FakeAudioExtractor audio;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('bug1415_');
      frame = _FakeFrameExtractor();
      gif = _FakeGifExtractor();
      audio = _FakeAudioExtractor();
    });

    tearDown(() async {
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
    });

    Future<ImmersionCaptureResult> run(ClipStillTarget? target) =>
        transcodeClipToCapture(
          Uint8List.fromList(<int>[1, 2, 3, 4]),
          durationMs: 6000,
          compression:
              MiningMediaCompression.resolve(imageTier: 1, audioTier: 0),
          tempDir: tempRoot.path,
          format: MiningAnimatedFormat.avif,
          stillTarget: target,
          gifExtractor: gif.call,
          audioExtractor: audio.call,
          frameExtractor: frame.call,
        );

    test('① 选静态帧 → 产出单帧，完全不进动图编码链', () async {
      final ImmersionCaptureResult cap =
          await run((offsetMs: 2500, exact: true));

      expect(cap.ok, isTrue);
      expect(cap.coverIsStill, isTrue);
      expect(cap.gifBytes, isNotNull);
      expect(gif.outputs, isEmpty,
          reason: '静态帧不该编动图 —— 既是行为正确性，也是不触发顶格档大体积编码的原因。');
      expect(frame.calls, hasLength(1));
      expect(frame.calls.single.outputPath, endsWith('.jpg'));
      expect(audio.calls, 1, reason: '静态帧模式不该把音频一起砍掉。');
    });

    test('② 取的帧对应制卡时刻，不是片段首帧', () async {
      await run((offsetMs: 2500, exact: true));
      expect(frame.calls.single.atSeconds, closeTo(2.5, 1e-9));
      expect(frame.calls.single.atSeconds, isNot(0.0),
          reason: '取首帧正是用户否掉的做法：片段 t=0 是句首，离制卡那一刻可以差好几秒。');
    });

    test('③ 片段起点与句首有偏移时仍取对（锚点实测，不假设等于句首）', () async {
      // 扩展 seek 到 cueStart-200=10000，但等 seek 落定/缓冲/起播推进后才真正开录：
      // 实测锚点 10480。制卡时刻 12500 → 片段内 2020ms。
      final ClipStillTarget? t = resolveClipStillTarget(
        imageMode: VideoMiningImageMode.currentFrame,
        clipAnchorMs: 10480,
        cueStartMs: 10200,
        mineAtMs: 12500,
        durationMs: 6000,
      );
      await run(t);
      expect(frame.calls.single.atSeconds, closeTo(2.02, 1e-9),
          reason: '若把锚点当成 seek 目标 10000，这里会算成 2.5s —— 差 480ms、约 6 个采集帧。');
    });

    test('④ 动图偏好（stillTarget=null）逐字节不受影响', () async {
      final ImmersionCaptureResult cap = await run(null);

      expect(cap.coverIsStill, isFalse);
      expect(frame.calls, isEmpty, reason: '动图档不该去抽单帧。');
      expect(gif.outputs, hasLength(1));
      expect(gif.outputs.single, endsWith('.avif'));
      expect(cap.animatedFormat, MiningAnimatedFormat.avif);
    });

    test('⑤ 取帧走 decodeFromStart（录制片段无 Cues 索引，输入定位会落到最近关键帧）', () async {
      await run((offsetMs: 2500, exact: true));
      expect(frame.calls.single.decodeFromStart, isTrue,
          reason: 'MediaRecorder webm 没有 Cues；输入定位取到的是最近关键帧而不是那一刻的帧。');
    });

    test('抽帧失败但有音频 → 与动图失败同形降级（无封面有音频），不整卡失败', () async {
      frame = _FakeFrameExtractor(succeed: false);
      final ImmersionCaptureResult cap =
          await run((offsetMs: 2500, exact: true));
      expect(cap.ok, isTrue);
      expect(cap.gifBytes, isNull);
      expect(cap.coverIsStill, isFalse);
      expect(cap.audioBytes, isNotNull);
    });
  });

  group('buildImmersionRequest：静态帧封面的文件名', () {
    ImmersionMinePayload payload() => ImmersionMinePayload(
          fields: const <String, String>{'word': 'x'},
          sentence: 's',
          clipBytes: Uint8List.fromList(<int>[1]),
        );

    test('静态帧 → .jpg（Anki 按扩展名判 MIME；给 .avif 会显示不出封面）', () {
      final ImmersionMiningRequest req = buildImmersionRequest(
        payload(),
        ImmersionCaptureResult(
          gifBytes: Uint8List.fromList(<int>[0xFF, 0xD8]),
          audioBytes: Uint8List.fromList(<int>[1]),
          animatedFormat: MiningAnimatedFormat.avif,
          coverIsStill: true,
        ),
        audioExpected: true,
      );
      expect(req.providedCoverName, 'netflix_frame.jpg');
    });

    test('动图 → 跟随实际产出格式（老行为不变）', () {
      final ImmersionMiningRequest req = buildImmersionRequest(
        payload(),
        ImmersionCaptureResult(
          gifBytes: Uint8List.fromList(<int>[1, 2]),
          audioBytes: Uint8List.fromList(<int>[1]),
          animatedFormat: MiningAnimatedFormat.avif,
        ),
        audioExpected: true,
      );
      expect(req.providedCoverName, 'netflix_clip.avif');
    });
  });

  group('wire：扩展下发的三个视频时间被解析', () {
    test('ImmersionMinePayload 解析 clipAnchorMs / cueStartMs / mineAtMs', () {
      final ImmersionMinePayload p =
          ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'word': 'x'},
        'sentence': 's',
        'clipDurationMs': 6000,
        'clipAnchorMs': 10480,
        'clipAnchorUncertaintyMs': 12,
        'cueStartMs': 10200,
        'mineAtMs': 12500,
      });
      expect(p.clipAnchorMs, 10480);
      expect(p.clipAnchorUncertaintyMs, 12);
      expect(p.cueStartMs, 10200);
      expect(p.mineAtMs, 12500);
    });

    test('老版扩展不发这些字段 → 全 null，不报错（向后兼容）', () {
      final ImmersionMinePayload p =
          ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'word': 'x'},
        'sentence': 's',
      });
      expect(p.clipAnchorMs, isNull);
      expect(p.cueStartMs, isNull);
      expect(p.mineAtMs, isNull);
    });
  });

  group('buildFfmpegFrameArgs：定位方式', () {
    test('decodeFromStart=true → -ss 在 -i 之后（输出定位，逐帧解码到目标时刻）', () {
      final List<String> args = buildFfmpegFrameArgs(
        inputPath: '/tmp/clip.webm',
        outputPath: '/tmp/f.jpg',
        atSeconds: 2.5,
        decodeFromStart: true,
      );
      expect(args.indexOf('-ss'), greaterThan(args.indexOf('-i')));
      expect(args[args.indexOf('-ss') + 1], '2.500');
    });

    test('默认（长视频/书架封面）仍是输入定位 —— 绝不能从 0 解码多 GB 剧集', () {
      final List<String> args = buildFfmpegFrameArgs(
        inputPath: '/tmp/ep.mkv',
        outputPath: '/tmp/f.jpg',
        atSeconds: 10,
      );
      expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
    });
  });

  group('源码扫描守卫：这条路不能再被结构性吞掉', () {
    /// 剥掉注释再扫：散文里为解释这条断链必然写出同样的符号名，让文档喂绿守卫是假阳性。
    String codeOnly(String src) => src.split('\n').map((String line) {
          final int i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        }).join('\n');

    test('mineImmersion 的 Netflix 段必须把静态帧目标下发给 transcodeClipToCapture', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final int start = src.indexOf('Future<RemoteMineResult> mineImmersion(');
      expect(start, greaterThan(0), reason: 'mineImmersion 改名了？守卫锚点失效，请同步更新。');
      final int end = src.indexOf('void recordHistory(', start);
      expect(end, greaterThan(start));
      final String body = codeOnly(src.substring(start, end));
      final int netflix = body.indexOf('ImmersionCaptureResult cap =');
      expect(netflix, greaterThan(0),
          reason: 'YouTube/Netflix 分界锚点失效，请同步更新守卫。');
      final String nf = body.substring(netflix);

      expect(nf, contains('resolveClipStillTarget('),
          reason: 'Netflix 段必须按 videoMiningImageMode 解析静态帧目标；'
              '不解析就等于用户选的「制卡时截图」在这条链路上恒被吞成动图（BUG-1416）。');
      expect(nf, contains('imageMode: _appModel.videoMiningImageMode'),
          reason: '偏好必须真读 AppModel，不能写死。');
      expect(nf, contains('stillTarget: stillTarget'),
          reason: '解析出来还得真传给 transcodeClipToCapture，否则解析了也白解析。');
    });

    test('浏览器扩展在制卡入口就地采样制卡时刻，并随 mineClip 发出', () {
      final String content = codeOnly(
          File('../tools/browser-extension/content.js').readAsStringSync());
      expect(content, contains('mineAtV'),
          reason: '入队时不采样「制卡那一刻」的视频时间，之后的回放录制就永远拿不回它。');
      expect(content, contains('mineAtMs:'), reason: 'mineClip 必须把制卡时刻发给服务端。');
      expect(content, contains('clipAnchorMs:'),
          reason: '片段时间基锚点必须实测下发 —— 假设它等于 seek 目标就是几百毫秒的系统性偏差。');

      final String background = codeOnly(
          File('../tools/browser-extension/background.js').readAsStringSync());
      expect(background, contains('clipAnchorMs'),
          reason: 'background 的 mineClip 转发漏掉字段 = content 采了也白采。');
      expect(background, contains('mineAtMs'));
    });
  });
}
