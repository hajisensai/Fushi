import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart' as host;

/// ASR 的 PCM 解码搬进 `fushi_asr_core` 之后，本仓与包之间隔着一个
/// [FushiAsrFfmpegBackend]。它转的是两套**同源但不同类型**的 `Ffmpeg*`，字段错位
/// 或语义走样都不会编译错——只会表现成「能转录但每次都慢一档」这种没人查得动的事。
/// 这组用例就是那道验收门。
class _RecordingBackend implements host.FfmpegBackend {
  _RecordingBackend({required this.runResult, required this.probeResult});

  final host.FfmpegRunResult runResult;
  final host.FfmpegRunResult probeResult;
  final List<({String kind, List<String> args, Duration timeout})> calls =
      <({String kind, List<String> args, Duration timeout})>[];

  @override
  Future<host.FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add((kind: 'run', args: args, timeout: timeout));
    return runResult;
  }

  @override
  Future<host.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async {
    calls.add((kind: 'probe', args: args, timeout: timeout));
    return probeResult;
  }
}

class _ThrowingBackend implements host.FfmpegBackend {
  @override
  Future<host.FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      throw ProcessException('ffmpeg', args, '找不到可执行文件', 2);

  @override
  Future<host.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async =>
      throw ProcessException('ffprobe', args, '找不到可执行文件', 2);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const FushiAsrFfmpegBackend adapter = FushiAsrFfmpegBackend();

  test('声学调轴默认关：转录本身就产出完整 SRT，调轴是精修不是必需', () {
    // 曾经默认开，代价是：日语包是 transducer 架构，调轴要另下 Omnilingual 1B
    // （int8 约 985 MB），而识别模型才约 150 MB —— 于是「选个小模型」被要求先下
    // 近 1 GB，不下就不让转录。转录出来的时间取自 VAD 段边界与 RNN-T 发射时刻，
    // 已经是一份可用的 SRT；调轴只是把每个 token 的时间再按声学定位一遍。
    expect(createAsrTranscriptionService().alignGeneratedSubtitles, isFalse);
    // 能力还在，一个参数就能打开。
    expect(
      createAsrTranscriptionService(alignGeneratedSubtitles: true)
          .alignGeneratedSubtitles,
      isTrue,
    );
  });

  test('有声书路径显式声明素材是干净朗读', () {
    // 能量门限是带前提的优化（语音与静默双模态可分），上游已把这个前提改成必填
    // 声明。有声书成立；混音素材（动画/影视）必须换 mixedAudio。
    expect(createAsrTranscriptionService().audioProfile,
        asr.AsrAudioProfile.cleanSpeech);
  });

  tearDown(() => host.setFfmpegBackendForTesting(null));

  test('run / runProbe 的参数与超时原样穿过去', () async {
    final _RecordingBackend backend = _RecordingBackend(
      runResult: const host.FfmpegRunResult(returnCode: 0, output: 'stderr 文本'),
      probeResult:
          const host.FfmpegRunResult(returnCode: 0, output: '{"format":{}}'),
    );
    host.setFfmpegBackendForTesting(backend);

    await adapter.run(<String>['-i', 'a.mp3'], const Duration(seconds: 7));
    await adapter
        .runProbe(<String>['-show_entries'], const Duration(seconds: 3));

    expect(backend.calls, hasLength(2));
    expect(backend.calls[0].kind, 'run');
    expect(backend.calls[0].args, <String>['-i', 'a.mp3']);
    expect(backend.calls[0].timeout, const Duration(seconds: 7));
    expect(backend.calls[1].kind, 'probe');
    expect(backend.calls[1].timeout, const Duration(seconds: 3));
  });

  test('输出流方向不能颠倒：run 带回 stderr，runProbe 带回 stdout', () async {
    // 判据是两条各自的**内容**，不是「都非空」。颠倒之后：
    // `isMissingS16leMuxerFailure` 恒 false（认不出没有 s16le muxer，走不到 mov
    // 回退），ffprobe 的时长恒 null（进度条永远不准、桶预热按未知走）。两样都不报错。
    host.setFfmpegBackendForTesting(_RecordingBackend(
      runResult: const host.FfmpegRunResult(
        // libavformat 的固定措辞；判据还要求 returnCode 非 0 非 null。
        returnCode: 1,
        output: "Requested output format 's16le' is not known",
      ),
      probeResult: const host.FfmpegRunResult(
        returnCode: 0,
        output: '{"format":{"duration":"12.500000"}}',
      ),
    ));
    final asr.FfmpegRunResult run =
        await adapter.run(<String>[], const Duration(seconds: 1));
    final asr.FfmpegRunResult probe =
        await adapter.runProbe(<String>[], const Duration(seconds: 1));
    expect(asr.isMissingS16leMuxerFailure(run), isTrue);
    expect(probe.output, contains('duration'));
  });

  test('超时是 returnCode == null，不是抛异常', () async {
    // 包里的解码循环按 `returnCode == null` 判超时并报「ffmpeg timed out」。
    // 适配器要是把它转成异常，那条分支永远走不到，用户看到的会是另一句错。
    host.setFfmpegBackendForTesting(_RecordingBackend(
      runResult: const host.FfmpegRunResult(returnCode: null, output: ''),
      probeResult: const host.FfmpegRunResult(returnCode: null, output: ''),
    ));
    final asr.FfmpegRunResult r =
        await adapter.run(<String>[], const Duration(milliseconds: 1));
    expect(r.returnCode, isNull);
    expect(r.isSuccess, isFalse);
  });

  test('可执行文件缺失是 ProcessException 穿透，不被吞成失败结果', () async {
    // 包里靠捕获 ProcessException 来区分「ffprobe 不在」与「ffprobe 跑了但失败」，
    // 前者按未知时长继续、后者才是真错。吞掉就分不出来了。
    host.setFfmpegBackendForTesting(_ThrowingBackend());
    await expectLater(
      adapter.run(<String>[], const Duration(seconds: 1)),
      throwsA(isA<ProcessException>()),
    );
    await expectLater(
      adapter.runProbe(<String>[], const Duration(seconds: 1)),
      throwsA(isA<ProcessException>()),
    );
  });

  test('executable 与诊断字段一起带过去（失败摘要要能读）', () async {
    host.setFfmpegBackendForTesting(_RecordingBackend(
      runResult: const host.FfmpegRunResult(
        returnCode: 1,
        output: 'boom',
        executable: r'C:\tools\ffmpeg.exe',
        attemptedExecutables: <String>[r'C:\bundled\ffmpeg.exe', 'ffmpeg'],
        fallbackReason: '捆绑的那个跑不起来',
      ),
      probeResult: const host.FfmpegRunResult(returnCode: 0, output: '{}'),
    ));
    final asr.FfmpegRunResult r =
        await adapter.run(<String>[], const Duration(seconds: 1));
    expect(r.executable, r'C:\tools\ffmpeg.exe');
    expect(r.failureSummary, contains('ffmpeg.exe'));
    expect(r.failureSummary, contains('boom'));
  });

  test('每次取用都重新解析后端（测试替换才生效）', () async {
    // 构造时固化后端会让 `setFfmpegBackendForTesting` 失效——那会让本文件其余
    // 用例全部悄悄测的是真 ffmpeg。
    final _RecordingBackend first = _RecordingBackend(
      runResult: const host.FfmpegRunResult(returnCode: 0, output: 'first'),
      probeResult: const host.FfmpegRunResult(returnCode: 0, output: '{}'),
    );
    final _RecordingBackend second = _RecordingBackend(
      runResult: const host.FfmpegRunResult(returnCode: 0, output: 'second'),
      probeResult: const host.FfmpegRunResult(returnCode: 0, output: '{}'),
    );
    host.setFfmpegBackendForTesting(first);
    expect((await adapter.run(<String>[], const Duration(seconds: 1))).output,
        'first');
    host.setFfmpegBackendForTesting(second);
    expect((await adapter.run(<String>[], const Duration(seconds: 1))).output,
        'second');
  });
}
