/// Apple 系统语音转录：平台契约解析、cue 拼装、引擎选项、以及服务产出的任务目录
/// 与 ONNX 后端同构。
///
/// 原生侧一行 Dart 测试都碰不到（那是 Swift），所以这里守的是**两边约定的形状**：
/// Swift 改一个字段名，这里立刻红，而不是等到真机上转出一份空字幕——那种失败在
/// 设备上看起来和「这段没人说话」一模一样。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';

import 'package:fushi/src/asr_host/apple_speech_channel.dart';
import 'package:fushi/src/asr_host/apple_speech_transcription_service.dart';
import 'package:fushi/src/asr_host/asr_engine_options.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';

/// 可编程的假平台：不碰 method channel。
class _FakePlatform implements AppleSpeechPlatform {
  _FakePlatform({this.installed = const <String>['ja-JP']});

  bool available = true;
  List<String> installed;
  List<String> supported = const <String>['ja-JP', 'en-US'];

  int prepareCalls = 0;
  int cancelCalls = 0;
  final List<String> transcribedPaths = <String>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<String>> installedLocales() async => installed;

  @override
  Future<List<String>> supportedLocales() async => supported;

  @override
  Future<void> prepare(String locale) async {
    prepareCalls++;
    installed = <String>[...installed, locale];
  }

  @override
  Future<AppleSpeechResult> transcribe({
    required String path,
    required String locale,
    void Function(int processedMs, int totalMs)? onProgress,
  }) async {
    transcribedPaths.add(path);
    onProgress?.call(500, 1000);
    return const AppleSpeechResult(
      durationMs: 1000,
      segments: <AppleSpeechSegment>[
        AppleSpeechSegment(
          text: '今日はいい天気。',
          startMs: 100,
          endMs: 900,
          tokens: <String>['今日', 'は', 'いい', '天気'],
          tokenStartsMs: <int>[100, 300, 500, 700],
        ),
      ],
    );
  }

  @override
  Future<void> cancel() async => cancelCalls++;
}

/// 停在半路的假平台：转录**不返回**，直到 [cancel] 把它以原生的 `CANCELLED`
/// 抛回来——这正是真机上按下暂停时发生的事。
///
/// [_FakePlatform] 的 transcribe 立刻返回，`requestPause()` 只能在 `run()` 之前调，
/// 于是循环在第一行就 break、根本走不到「有一次转录正在飞」的那条路径。
class _CancellingPlatform implements AppleSpeechPlatform {
  final Completer<AppleSpeechResult> _inFlight = Completer<AppleSpeechResult>();

  /// 原生已经开转（用来确保暂停发生在转录中途，而不是开跑之前）。
  final Completer<void> started = Completer<void>();

  int cancelCalls = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<String>> installedLocales() async => const <String>['ja-JP'];

  @override
  Future<List<String>> supportedLocales() async => const <String>['ja-JP'];

  @override
  Future<void> prepare(String locale) async {}

  @override
  Future<AppleSpeechResult> transcribe({
    required String path,
    required String locale,
    void Function(int processedMs, int totalMs)? onProgress,
  }) {
    onProgress?.call(300, 1000);
    if (!started.isCompleted) started.complete();
    return _inFlight.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (!_inFlight.isCompleted) {
      _inFlight.completeError(
        PlatformException(code: 'CANCELLED', message: 'cancelled'),
      );
    }
  }
}

void main() {
  group('parseAppleSpeechPayload', () {
    test('正常载荷：字段名与时间原样落地', () {
      final AppleSpeechResult result =
          parseAppleSpeechPayload(<Object?, Object?>{
        'durationMs': 5000,
        'segments': <Object?>[
          <Object?, Object?>{
            'text': 'hello',
            'startMs': 100,
            'endMs': 900,
            'tokens': <Object?>[
              <Object?, Object?>{'text': 'hel', 'startMs': 100},
              <Object?, Object?>{'text': 'lo', 'startMs': 400},
            ],
          },
        ],
      });
      expect(result.durationMs, 5000);
      expect(result.segments.single.text, 'hello');
      expect(result.segments.single.startMs, 100);
      expect(result.segments.single.endMs, 900);
      expect(result.segments.single.tokens, <String>['hel', 'lo']);
      expect(result.segments.single.tokenStartsMs, <int>[100, 400]);
    });

    test('空文本与退化区间逐条丢弃，不毁掉整份', () {
      final AppleSpeechResult result =
          parseAppleSpeechPayload(<Object?, Object?>{
        'durationMs': 1000,
        'segments': <Object?>[
          <Object?, Object?>{'text': '   ', 'startMs': 0, 'endMs': 100},
          <Object?, Object?>{'text': 'bad', 'startMs': 500, 'endMs': 500},
          <Object?, Object?>{'text': 'ok', 'startMs': 0, 'endMs': 100},
        ],
      });
      expect(result.segments.map((AppleSpeechSegment s) => s.text), <String>[
        'ok',
      ]);
    });

    test('缺时长要抛：没有分母，进度和结尾都算不出来', () {
      expect(
        () => parseAppleSpeechPayload(
            <Object?, Object?>{'segments': <Object?>[]}),
        throwsA(isA<AppleSpeechUnavailable>()),
      );
    });

    test('零段落是合法结果（整段没人说话），不抛', () {
      final AppleSpeechResult result = parseAppleSpeechPayload(
        <Object?, Object?>{'durationMs': 1000},
      );
      expect(result.segments, isEmpty);
    });
  });

  group('appleSpeechCues', () {
    test('cue 时间按拼接时间轴平移，逐词偏移改以 cue 起点为基准', () {
      final List<AsrCue> cues = appleSpeechCues(
        const <AppleSpeechSegment>[
          AppleSpeechSegment(
            text: 'second file',
            startMs: 100,
            endMs: 400,
            tokens: <String>['second', 'file'],
            tokenStartsMs: <int>[100, 250],
          ),
        ],
        fileIndex: 1,
        offsetMs: 60000,
      );
      final AsrCue cue = cues.single;
      expect(cue.startMs, 60100);
      expect(cue.endMs, 60400);
      expect(cue.audioFileIndex, 1);
      // 上游 sidecar 的 `o` 是**相对 cue 起点**的偏移，消费端一律按
      // `cue.startMs + o` 还原。塞绝对时间（60100/60250）会让每个词多算一整个
      // cue 起点，而 SRT 与行数全对得上——静默偏移，只有跳播看得出来。
      expect(cue.tokenOffsetsMs, <int>[0, 150]);
      // 下游 attachAsrCueTokenTiming 要求两者等长，不等长时一条都不挂。
      expect(cue.tokens.length, cue.tokenOffsetsMs.length);
    });

    test('词起点早于句起点时夹到 0，不丢词（丢了就长度不等，一条都挂不上）', () {
      final List<AsrCue> cues = appleSpeechCues(
        const <AppleSpeechSegment>[
          AppleSpeechSegment(
            text: 'early token',
            startMs: 500,
            endMs: 900,
            tokens: <String>['early', 'token'],
            tokenStartsMs: <int>[480, 700],
          ),
        ],
        fileIndex: 0,
        offsetMs: 0,
      );
      expect(cues.single.tokenOffsetsMs, <int>[0, 200]);
      expect(cues.single.tokens.length, cues.single.tokenOffsetsMs.length);
    });
  });

  group('asrEngineOptions', () {
    final AsrModelRegistry registry =
        buildAsrModelRegistry(AsrModelCatalog.empty);

    test('系统语音不可用时那一项整个不出现', () {
      final List<AsrEngineOption> options = asrEngineOptions(
        language: AsrLanguage.japanese,
        registry: registry,
        systemSpeechAvailable: false,
        systemSpeechLabel: '系统语音',
      );
      expect(
        options.map((AsrEngineOption o) => o.id),
        isNot(contains(kAppleSpeechEngineId)),
      );
    });

    test('可用时排在 ONNX 包之后——默认不能变', () {
      final List<AsrEngineOption> options = asrEngineOptions(
        language: AsrLanguage.japanese,
        registry: registry,
        systemSpeechAvailable: true,
        systemSpeechLabel: '系统语音',
      );
      expect(options.first.id, kAsrJapanesePack.id);
      expect(options.last.id, kAppleSpeechEngineId);
      expect(options.last.isSystemSpeech, isTrue);
      expect(options.first.isSystemSpeech, isFalse);
    });

    test('选中值：没记录取第一项，有记录取记录的', () {
      final List<AsrEngineOption> options = asrEngineOptions(
        language: AsrLanguage.japanese,
        registry: registry,
        systemSpeechAvailable: true,
        systemSpeechLabel: '系统语音',
      );
      expect(
        selectedAsrEngineId(
          language: AsrLanguage.japanese,
          catalog: AsrModelCatalog.empty,
          options: options,
        ),
        kAsrJapanesePack.id,
      );
      expect(
        selectedAsrEngineId(
          language: AsrLanguage.japanese,
          catalog: AsrModelCatalog.empty
              .withChoice(AsrLanguage.japanese, kAppleSpeechEngineId),
          options: options,
        ),
        kAppleSpeechEngineId,
      );
    });

    test('记录的那项已经不在列表里（换了台没系统语音的机器）→ 回落第一项', () {
      final List<AsrEngineOption> options = asrEngineOptions(
        language: AsrLanguage.japanese,
        registry: registry,
        systemSpeechAvailable: false,
        systemSpeechLabel: '系统语音',
      );
      expect(
        selectedAsrEngineId(
          language: AsrLanguage.japanese,
          catalog: AsrModelCatalog.empty
              .withChoice(AsrLanguage.japanese, kAppleSpeechEngineId),
          options: options,
        ),
        kAsrJapanesePack.id,
      );
    });

    test('保留 id 落进目录也不会污染 ONNX 注册表', () {
      // buildAsrModelRegistry 找不到这个 id 就忽略这条选择——日语的默认包不变。
      final AsrModelRegistry polluted = buildAsrModelRegistry(
        AsrModelCatalog.empty
            .withChoice(AsrLanguage.japanese, kAppleSpeechEngineId),
      );
      expect(
        polluted.packForLanguage(AsrLanguage.japanese)?.id,
        kAsrJapanesePack.id,
      );
    });
  });

  group('AppleSpeechTranscriptionService', () {
    late Directory jobs;
    late Directory audioDir;
    late List<String> audioPaths;

    setUp(() async {
      jobs = await Directory.systemTemp.createTemp('apple_speech_jobs_');
      audioDir = await Directory.systemTemp.createTemp('apple_speech_audio_');
      audioPaths = <String>[
        '${audioDir.path}${Platform.pathSeparator}a.m4a',
        '${audioDir.path}${Platform.pathSeparator}b.m4a',
      ];
      for (final String path in audioPaths) {
        File(path).writeAsBytesSync(<int>[1, 2, 3, 4]);
      }
    });
    tearDown(() async {
      if (jobs.existsSync()) await jobs.delete(recursive: true);
      if (audioDir.existsSync()) await audioDir.delete(recursive: true);
    });

    AppleSpeechTranscriptionService build(AppleSpeechPlatform platform) =>
        AppleSpeechTranscriptionService(
          platform: platform,
          jobsRoot: () async => jobs,
        );

    test('plan：语言资产装了才算就绪', () async {
      final _FakePlatform platform = _FakePlatform(installed: <String>[]);
      final AppleSpeechTranscriptionService service = build(platform);
      AsrTranscribePlan plan = await service.plan(
        language: AsrLanguage.japanese,
        preference: AsrAccelerationPreference.auto,
      );
      expect(plan.modelReady, isFalse);

      // 「下载模型」在这个引擎下 = 让系统装语言资产。
      await service
          .downloadModel(
            language: AsrLanguage.japanese,
            variant: AsrEncoderVariant.int8,
          )
          .drain<void>();
      expect(platform.prepareCalls, 1);

      plan = await service.plan(
        language: AsrLanguage.japanese,
        preference: AsrAccelerationPreference.auto,
      );
      expect(plan.modelReady, isTrue);
    });

    test('installed 用主子标签比：ja 命中 ja-JP', () async {
      final AppleSpeechTranscriptionService service =
          build(_FakePlatform(installed: <String>['ja-JP']));
      final AsrTranscribePlan plan = await service.plan(
        language: AsrLanguage.japanese,
        preference: AsrAccelerationPreference.auto,
      );
      expect(plan.modelReady, isTrue);
    });

    test('跑完产出与 ONNX 后端同构的任务目录', () async {
      final _FakePlatform platform = _FakePlatform();
      final AppleSpeechTranscriptionService service = build(platform);
      final AsrRunningTranscription running = await service.start(
        audioPaths: audioPaths,
        language: AsrLanguage.japanese,
        variant: AsrEncoderVariant.int8,
        preference: AsrAccelerationPreference.auto,
      );
      final List<AsrTranscribeEvent> events = await running.run().toList();
      final AsrTranscribeFinishedEvent finished =
          events.whereType<AsrTranscribeFinishedEvent>().single;

      final Directory dir =
          await service.jobDirFor(audioPaths, AsrLanguage.japanese);
      // 三份产物齐、文件名与包里的常量一致——下游认「这是转录产物」靠的就是
      // transcript.srt 旁边有没有 state.json。
      expect(File('${dir.path}/${AsrJobFiles.srt}').existsSync(), isTrue);
      expect(File('${dir.path}/${AsrJobFiles.state}').existsSync(), isTrue);
      expect(File('${dir.path}/${AsrJobFiles.cueTokens}').existsSync(), isTrue);
      expect(
        AsrTranscriptionService.isAsrGeneratedSubtitlePath(
            finished.result.srtPath),
        isTrue,
      );

      // 两个文件都转了，时间轴是拼接的单轨。
      expect(platform.transcribedPaths, audioPaths);
      final String srt =
          File('${dir.path}/${AsrJobFiles.srt}').readAsStringSync();
      expect(srt, contains('今日はいい天気。'));
      // 第二个文件的 cue 起点被平移到第一个文件之后（1000ms + 100ms）。
      expect(srt, contains('00:00:01,100'));

      // state.json 记的是本引擎的 id，且已完成。
      final Map<String, Object?> state = jsonDecode(
        File('${dir.path}/${AsrJobFiles.state}').readAsStringSync(),
      ) as Map<String, Object?>;
      expect(state['modelId'], kAppleSpeechEngineId);
      expect(state['finished'], isTrue);

      expect(
        await service.finishedSrtPath(audioPaths, AsrLanguage.japanese),
        finished.result.srtPath,
      );
    });

    test('任务 id 与 ONNX 那条不同——换引擎不顶掉对方的进度', () {
      final String appleId = AppleSpeechTranscriptionService.appleSpeechJobId(
        audioPaths,
        AsrLanguage.japanese,
      );
      final String onnxId = AsrTranscriptionService.jobIdFor(
        audioPaths,
        AsrLanguage.japanese,
      );
      expect(appleId, isNot(onnxId));
    });

    test('语言不同也是不同任务', () {
      expect(
        AppleSpeechTranscriptionService.appleSpeechJobId(
          audioPaths,
          AsrLanguage.japanese,
        ),
        isNot(
          AppleSpeechTranscriptionService.appleSpeechJobId(
            audioPaths,
            AsrLanguage.english,
          ),
        ),
      );
    });

    test('discard 清掉任务目录', () async {
      final AppleSpeechTranscriptionService service = build(_FakePlatform());
      final AsrRunningTranscription running = await service.start(
        audioPaths: audioPaths,
        language: AsrLanguage.japanese,
        variant: AsrEncoderVariant.int8,
        preference: AsrAccelerationPreference.auto,
      );
      await running.run().drain<void>();
      final Directory dir =
          await service.jobDirFor(audioPaths, AsrLanguage.japanese);
      expect(dir.existsSync(), isTrue);
      await service.discard(audioPaths, AsrLanguage.japanese);
      expect(dir.existsSync(), isFalse);
      expect(
        await service.finishedSrtPath(audioPaths, AsrLanguage.japanese),
        isNull,
      );
    });

    test('requestPause 取消原生任务且不产出半份产物', () async {
      final _FakePlatform platform = _FakePlatform();
      final AppleSpeechTranscriptionService service = build(platform);
      final AsrRunningTranscription running = await service.start(
        audioPaths: audioPaths,
        language: AsrLanguage.japanese,
        variant: AsrEncoderVariant.int8,
        preference: AsrAccelerationPreference.auto,
      );
      running.requestPause();
      final List<AsrTranscribeEvent> events = await running.run().toList();
      expect(platform.cancelCalls, greaterThan(0));
      expect(events.whereType<AsrTranscribeFinishedEvent>(), isEmpty);
      final Directory dir =
          await service.jobDirFor(audioPaths, AsrLanguage.japanese);
      // 半份 SRT 比没有更糟：下游会把它当成一份完整字幕去匹配。
      expect(File('${dir.path}/${AsrJobFiles.srt}').existsSync(), isFalse);
    });

    test('转录中途暂停：原生的 CANCELLED 要落成「已暂停」，不是转录失败', () async {
      final _CancellingPlatform platform = _CancellingPlatform();
      final AppleSpeechTranscriptionService service = build(platform);
      final AsrRunningTranscription running = await service.start(
        audioPaths: audioPaths,
        language: AsrLanguage.japanese,
        variant: AsrEncoderVariant.int8,
        preference: AsrAccelerationPreference.auto,
      );

      final List<AsrTranscribeEvent> events = <AsrTranscribeEvent>[];
      final Completer<void> closed = Completer<void>();
      Object? failure;
      final StreamSubscription<AsrTranscribeEvent> sub = running.run().listen(
            events.add,
            onError: (Object error, StackTrace _) => failure = error,
            onDone: closed.complete,
          );

      await platform.started.future;
      running.requestPause();
      await closed.future;
      await sub.cancel();

      expect(platform.cancelCalls, greaterThan(0));
      // 取消是我们自己要求的，不该冒充失败——弹层会把它显示成「转录失败」并
      // 甩出一条 PlatformException 原文。
      expect(failure, isNull);
      // 弹层按下暂停后停在 pausing，只认这个事件才落到「已暂停」。
      expect(events.whereType<AsrTranscribePausedEvent>(), hasLength(1));
      expect(events.whereType<AsrTranscribeFinishedEvent>(), isEmpty);
    });

    test('原生的文件内进度要并进产出流（长文件唯一会动的那个）', () async {
      final _FakePlatform platform = _FakePlatform();
      final AppleSpeechTranscriptionService service = build(platform);
      final AsrRunningTranscription running = await service.start(
        audioPaths: audioPaths,
        language: AsrLanguage.japanese,
        variant: AsrEncoderVariant.int8,
        preference: AsrAccelerationPreference.auto,
      );
      final List<AsrTranscribeEvent> events = await running.run().toList();
      final List<int> processed = events
          .whereType<AsrTranscribeProgressEvent>()
          .map((AsrTranscribeProgressEvent e) => e.progress.processedMs)
          .toList();

      // 假平台每个文件在半路报一次 500/1000；第二个文件要加上第一个的时长。
      // 缺了它们，几小时的音频在整份转完前进度条一动不动。
      expect(processed, contains(500));
      expect(processed, contains(1500));
    });
  });
}
