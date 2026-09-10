import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi/utils.dart';
import 'package:path/path.dart' as p;

class _NoopSession implements OnnxSession {
  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async =>
      <String, OnnxTensor>{};

  @override
  Future<void> close() async {}
}

class _FakePcm implements AsrPcmSource {
  @override
  Future<int?> probeDurationMs(String audioPath) async => 4000;

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    yield AsrPcmChunk(startSample: 0, samples: Float32List(4 * kAsrSampleRate));
  }
}

class _FakeSegmenter implements AsrSegmenter {
  @override
  Future<List<AsrSpeechSegment>> feed(
    AsrPcmChunk chunk,
  ) async =>
      <AsrSpeechSegment>[
        AsrSpeechSegment(
            startSample: 0, samples: Float32List(2 * kAsrSampleRate)),
      ];

  @override
  Future<List<AsrSpeechSegment>> flush() async => <AsrSpeechSegment>[];

  @override
  void reset() {}

  @override
  int? get inProgressSpeechStartSample => null;
}

class _FakeDecoder implements AsrBatchDecoder {
  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async =>
      segments
          .map(
            (AsrSpeechSegment _) => AsrDecodedSegment(
              tokens: const <String>['今', '日', '。'],
              tokenOffsetsMs: const <int>[100, 300, 600],
            ),
          )
          .toList();
}

/// 假服务：模型就绪与否、已完成产物可编程；`start` 装配真任务 + 假会话。
/// 每次 plan / download / start 收到的语言都记下来，供「切语言真的传到了
/// service」的断言。
class _FakeService extends AsrTranscriptionService {
  _FakeService({
    required this.ready,
    required this.jobsDir,
    this.existingSrt,
    this.probeError,
  }) : super(
          audioProfile: AsrAudioProfile.cleanSpeech,
          backend: const AsrIsolateBackend(
            buildFactory: _unusedOnnxFactory,
          ),
          pcm: _FakePcm(),
          openStore: (AsrLanguage l) async =>
              AsrModelStore(jobsDir, asrModelPackFor(l)),
          jobsRoot: () async => jobsDir,
        );

  bool ready;
  final Directory jobsDir;
  String? existingSrt;

  /// 非 null 时 plan 报「EP 探测失败」（模拟有 GPU 的机器探测抛错被推荐成 CPU）。
  final String? probeError;

  /// 非 null 时 `start` 抛它。装模型文件读不出图那条路径：引擎在 load 阶段把坏
  /// 档删掉再抛，所以抛之前 `ready` 归 false——与真实时序一致。
  Object? startError;
  int downloadCalls = 0;
  int discardCalls = 0;
  final List<AsrLanguage> planLanguages = <AsrLanguage>[];
  final List<AsrAccelerationPreference> planPreferences =
      <AsrAccelerationPreference>[];
  AsrAccelerationPreference? lastStartPreference;
  AsrLanguage? lastDownloadLanguage;
  AsrLanguage? lastStartLanguage;

  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async {
    planLanguages.add(language);
    planPreferences.add(preference);
    return AsrTranscribePlan(
      language: language,
      variant: AsrEncoderVariant.int8,
      expectedProvider: OnnxExecutionProvider.cpu,
      modelStatus: AsrModelStatus(
        ready: ready,
        diskBytes: 0,
        totalBytes: 1000,
        obtainedBytes: ready ? 1000 : 250,
      ),
      probeError: probeError,
    );
  }

  @override
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    bool includeAlignment = false,
  }) async* {
    downloadCalls++;
    lastDownloadLanguage = language;
    yield const ModelDownloadEvent(
      fileName: 'a.onnx',
      receivedBytes: 500,
      totalBytes: 1000,
    );
    ready = true;
    yield const ModelDownloadEvent(
      fileName: 'a.onnx',
      receivedBytes: 1000,
      totalBytes: 1000,
      done: true,
    );
  }

  @override
  Future<String?> finishedSrtPath(
    List<String> audioPaths,
    AsrLanguage language,
  ) async =>
      existingSrt;

  @override
  Future<AsrJobState?> existingState(
    List<String> audioPaths,
    AsrLanguage language,
  ) async =>
      null;

  @override
  Future<void> discard(List<String> audioPaths, AsrLanguage language) async {
    discardCalls++;
    existingSrt = null;
  }

  @override
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
  }) async {
    lastStartLanguage = language;
    lastStartPreference = preference;
    final Object? failure = startError;
    if (failure != null) {
      // 引擎判定坏档时是「先删文件、再抛」，所以下一次 plan 必然未就绪。
      ready = false;
      Error.throwWithStackTrace(failure, StackTrace.current);
    }
    final AsrEngineSessions sessions = AsrEngineSessions(
      encoder: _NoopSession(),
      decoder: _NoopSession(),
      joiner: _NoopSession(),
      vad: _NoopSession(),
      tokens: AsrTokenTable.parse('<blk>\t0\n'),
      variant: variant,
      encoderResolution: const OnnxProviderResolution(
        requested: <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
        effective: OnnxExecutionProvider.cpu,
      ),
    );
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: Directory('${jobsDir.path}/job'),
      audioPaths: audioPaths,
      modelId: asrModelPackFor(language).id,
      pcm: _FakePcm(),
      segmenter: _FakeSegmenter(),
      decoder: _FakeDecoder(),
      progressInterval: Duration.zero,
    );
    return AsrInProcessTranscription(sessions: sessions, job: job);
  }
}

/// 在语言下拉里选 [language]：先点开下拉（触发器显示当前语言），再点菜单里的
/// 母语名条目（触发器与条目可能同文，取最后一个即菜单项）。
Future<void> pickLanguage(WidgetTester tester, AsrLanguage language) async {
  await tester
      .tap(find.byKey(const ValueKey<String>('asr-transcribe-language')));
  await tester.pumpAndSettle();
  final Finder entry = find.text(language.nativeName).last;
  // 菜单有最大高度、可滚动；条目可能在视口外。
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

/// 状态行（`asr-transcribe-status`）当前显示的文本。
String _statusText(WidgetTester tester) =>
    tester
        .widget<Text>(
          find.byKey(const ValueKey<String>('asr-transcribe-status')),
        )
        .data ??
    '';

/// 这几组用例都走进程内路径（`runInIsolate: false`）或只碰 UI，不会真起后台
/// isolate。真被调到说明用例走错了路径，直接炸比默默建个真后端好。
OnnxSessionFactory _unusedOnnxFactory() =>
    throw UnimplementedError('本用例不该在 isolate 里建 ONNX 后端');

void main() {
  late Directory tmp;

  /// 「上次选的语言」偏好桩：默认日语；setter 写回 [savedLanguage]。
  String savedLanguage = 'ja';
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_sheet_test_');
    savedLanguage = 'ja';
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Widget wrap(
    _FakeService service,
    void Function(String?) onResult, {
    Future<String?> Function({
      required String fileName,
      required String? initialDirectory,
    })? saveFilePicker,
    AsrLanguage? languageHint,
    AsrModelCatalog Function()? catalogGetter,
    Future<void> Function(AsrModelCatalog catalog)? catalogSetter,
    Future<String?> Function()? directoryPicker,
  }) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: FilledButton(
                  key: const ValueKey<String>('open'),
                  onPressed: () async {
                    final String? r = await showAsrTranscribeSheet(
                      context: context,
                      audioPaths: const <String>['a.mp3'],
                      service: service,
                      saveFilePicker: saveFilePicker,
                      languageHint: languageHint,
                      languageGetter: () => savedLanguage,
                      languageSetter: (String tag) async => savedLanguage = tag,
                      catalogGetter: catalogGetter,
                      catalogSetter: catalogSetter,
                      directoryPicker: directoryPicker,
                    );
                    onResult(r);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('模型未就绪：先下载，下载完进入就绪态', (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: false, jobsDir: tmp);
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_model_download),
      findsOneWidget,
    );
    expect(find.textContaining('750'), findsOneWidget); // 1000-250 字节待下载
    await tester.tap(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_model_download),
    );
    await tester.pumpAndSettle();
    expect(service.downloadCalls, 1);
    expect(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
      findsOneWidget,
    );
  });

  testWidgets('切到英语：plan / 下载都带英语，且语言偏好被写成 en', (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: false, jobsDir: tmp);
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    // 初值来自偏好（ja），模型就绪行标出日语包名。
    expect(service.planLanguages, <AsrLanguage>[AsrLanguage.japanese]);

    await pickLanguage(tester, AsrLanguage.english);
    expect(service.planLanguages.last, AsrLanguage.english);
    expect(savedLanguage, 'en');

    await tester.tap(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_model_download),
    );
    await tester.pumpAndSettle();
    expect(service.lastDownloadLanguage, AsrLanguage.english);
    // 下载完成后的就绪行带英语包名。（只看状态行：模型下拉里也会显示包名。）
    expect(_statusText(tester), contains(kAsrEnglishPack.displayName));
  });

  testWidgets('偏好里存的是 en：弹层初值就是英语，start 也带英语', (WidgetTester tester) async {
    savedLanguage = 'en';
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(service.planLanguages, <AsrLanguage>[AsrLanguage.english]);
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
      );
      // 要等到任务真跑完（完成态）再回 fake async：运行中的不定进度条会让
      // pumpAndSettle 永远等不到安定。
      for (int i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find
            .widgetWithText(FilledButton, t.audiobook_transcribe_use_result)
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    expect(service.lastStartLanguage, AsrLanguage.english);
  });

  testWidgets('非 macOS：加速分段只有自动 / 仅 CPU，不露 CoreML',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(find.text(t.audiobook_transcribe_accel_auto), findsOneWidget);
    expect(find.text(t.audiobook_transcribe_accel_cpu), findsOneWidget);
    expect(find.text(t.audiobook_transcribe_accel_coreml), findsNothing);
  });

  testWidgets('macOS：露出 CoreML 分段，选中后 plan / start 都收到 coreml',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(service.planPreferences, <AsrAccelerationPreference>[
      AsrAccelerationPreference.auto,
    ]);

    final Finder coreml = find.text(t.audiobook_transcribe_accel_coreml);
    await tester.ensureVisible(coreml);
    await tester.pumpAndSettle();
    await tester.tap(coreml);
    await tester.pumpAndSettle();
    expect(service.planPreferences.last, AsrAccelerationPreference.coreml);

    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
      );
      for (int i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // 等任务真正跑完再退出：提前退出会让 fake 任务还握着 jobsDir 里的文件
        // 句柄，tearDown 删临时目录在 Windows 上会撞 errno 32。
        if (find
            .widgetWithText(FilledButton, t.audiobook_transcribe_use_result)
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    expect(service.lastStartPreference, AsrAccelerationPreference.coreml);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('就绪 → 开始 → 完成 → 使用字幕返回 SRT 路径', (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
    String? result = 'unset';
    await tester.pumpWidget(wrap(service, (String? r) => result = r));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();

    // 任务里有真实文件 IO（segments.jsonl / transcript.srt），要在 runAsync 里让
    // 真事件循环跑完，再回到 fake async 泛起帧。
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
      );
      for (int i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find
            .widgetWithText(FilledButton, t.audiobook_transcribe_use_result)
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_use_result),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.audiobook_transcribe_done(cues: 1, segments: 1)),
      findsOneWidget,
    );
    await tester.tap(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_use_result),
    );
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result, endsWith(AsrJobFiles.srt));
    expect(File(result!).readAsStringSync(), contains('今日。'));
  });

  testWidgets('完成态有「导出字幕文件」：桌面存盘对话框拿到路径后拷贝产物', (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
    final Directory exportDir = Directory(p.join(tmp.path, 'export'))
      ..createSync();
    String? askedName;
    String? askedDir;
    final String target = p.join(exportDir.path, 'out.srt');
    await tester.pumpWidget(
      wrap(
        service,
        (String? _) {},
        saveFilePicker: ({
          required String fileName,
          required String? initialDirectory,
        }) async {
          askedName = fileName;
          askedDir = initialDirectory;
          return target;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
      );
      for (int i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find
            .widgetWithText(OutlinedButton, t.audiobook_transcribe_export)
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      await tester.tap(
        find.widgetWithText(OutlinedButton, t.audiobook_transcribe_export),
      );
      for (int i = 0; i < 20 && !File(target).existsSync(); i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(File(target).existsSync(), isTrue);
    expect(File(target).readAsStringSync(), contains('今日。'));
    // 默认文件名 = 首个音频同名 .srt，起始目录 = 音频所在目录。
    expect(askedName, endsWith('.srt'));
    expect(askedDir, isNotNull);
    // 导出不消费产物：「使用字幕」仍在。
    expect(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_use_result),
      findsOneWidget,
    );
  });

  test('字幕行点击分流：能转录且有音频才弹来源选择', () {
    expect(
      shouldOfferSubtitleSourceChooser(asrSupported: true, hasAudio: true),
      isTrue,
    );
    expect(
      shouldOfferSubtitleSourceChooser(asrSupported: true, hasAudio: false),
      isFalse,
    );
    expect(
      shouldOfferSubtitleSourceChooser(asrSupported: false, hasAudio: true),
      isFalse,
    );
  });

  test('导出默认文件名：首个音频同名 .srt；无音频退回 transcript.srt', () {
    expect(
      // 用平台自己的分隔符拼路径：`basenameWithoutExtension` 走平台上下文，写死
      // `D:\...` 在 Linux CI 上 `\` 不是分隔符、会整串当文件名（曾让 CI 真红）。
      suggestedTranscriptFileName(<String>[
        p.join(tmp.path, '第01巻.m4b'),
        p.join(tmp.path, 'b.mp3'),
      ]),
      '第01巻.srt',
    );
    expect(suggestedTranscriptFileName(const <String>[]), 'transcript.srt');
  });

  test('asrLanguageHintFromBookLanguage：取 BCP-47 主子标签，认不出 / 空返回 null', () {
    expect(asrLanguageHintFromBookLanguage('ja-JP'), AsrLanguage.japanese);
    expect(asrLanguageHintFromBookLanguage('ja'), AsrLanguage.japanese);
    expect(asrLanguageHintFromBookLanguage('en-GB'), AsrLanguage.english);
    expect(asrLanguageHintFromBookLanguage('en_GB'), AsrLanguage.english);
    expect(asrLanguageHintFromBookLanguage('EN'), AsrLanguage.english);
    expect(asrLanguageHintFromBookLanguage(' en-US '), AsrLanguage.english);
    // 中文按口语分流：`zh` / `zh-CN` / `zh-Hant-TW` 是普通话，`HK` / `MO` 子标签与
    // `yue` 主子标签是粤语。
    expect(asrLanguageHintFromBookLanguage('zh'), AsrLanguage.mandarin);
    expect(asrLanguageHintFromBookLanguage('zh-CN'), AsrLanguage.mandarin);
    expect(asrLanguageHintFromBookLanguage('zh-Hant-TW'), AsrLanguage.mandarin);
    expect(asrLanguageHintFromBookLanguage('zh-HK'), AsrLanguage.cantonese);
    expect(
        asrLanguageHintFromBookLanguage('zh-Hant-HK'), AsrLanguage.cantonese);
    expect(asrLanguageHintFromBookLanguage('yue'), AsrLanguage.cantonese);
    expect(asrLanguageHintFromBookLanguage('ko-KR'), AsrLanguage.korean);
    // Omnilingual 兜住的 9 种也能从书的语言标签推出来。
    expect(asrLanguageHintFromBookLanguage('de'), AsrLanguage.german);
    expect(asrLanguageHintFromBookLanguage('pt-BR'), AsrLanguage.portuguese);
    expect(asrLanguageHintFromBookLanguage('ar-SA'), AsrLanguage.arabic);
    expect(asrLanguageHintFromBookLanguage('xx'), isNull);
    expect(asrLanguageHintFromBookLanguage('zh-Hans-CN'), AsrLanguage.mandarin);
    expect(asrLanguageHintFromBookLanguage(null), isNull);
    expect(asrLanguageHintFromBookLanguage(''), isNull);
    expect(asrLanguageHintFromBookLanguage('   '), isNull);
  });

  testWidgets('languageHint=english 且偏好存 ja：初值英语、plan 收到英语、偏好不被改写',
      (WidgetTester tester) async {
    savedLanguage = 'ja';
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
    await tester.pumpWidget(
      wrap(service, (String? _) {}, languageHint: AsrLanguage.english),
    );
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(service.planLanguages, <AsrLanguage>[AsrLanguage.english]);
    expect(
      _statusText(tester),
      contains(kAsrEnglishPack.displayName),
      reason: '就绪行应标出英语包名（初值来自书的语言而非偏好）',
    );
    expect(savedLanguage, 'ja', reason: 'hint 只作初值，不写回偏好');

    // 用户手动切回日语才写回。
    await pickLanguage(tester, AsrLanguage.japanese);
    expect(service.planLanguages.last, AsrLanguage.japanese);
    expect(savedLanguage, 'ja');
  });

  testWidgets('plan 带 probeError：就绪行追加「GPU 探测失败，按 CPU 规划」提示',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      ready: true,
      jobsDir: tmp,
      probeError: 'DirectML.dll not found',
    );
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        t.audiobook_transcribe_probe_failed(reason: 'DirectML.dll not found'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('plan 无 probeError：就绪行不含探测失败提示', (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(t.audiobook_transcribe_probe_failed(reason: '')),
      findsNothing,
    );
  });

  test('导出：用户取消存盘对话框时不写文件、返回 false', () async {
    final File src = File(p.join(tmp.path, 'src.srt'))..writeAsStringSync('1');
    final bool r = await exportTranscribedSrt(
      srtPath: src.path,
      audioPaths: <String>[p.join(tmp.path, 'x.m4b')],
      desktop: true,
      saveFilePicker: ({
        required String fileName,
        required String? initialDirectory,
      }) async =>
          null,
    );
    expect(r, isFalse);
  });

  testWidgets('已有完成产物：直接进入完成态，可放弃后重转', (WidgetTester tester) async {
    final File srt = File('${tmp.path}/old.srt')..writeAsStringSync('1\n');
    final _FakeService service = _FakeService(
      ready: true,
      jobsDir: tmp,
      existingSrt: srt.path,
    );
    String? result = 'unset';
    await tester.pumpWidget(wrap(service, (String? r) => result = r));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_use_result),
      findsOneWidget,
    );
    await tester.tap(
      find.widgetWithText(TextButton, t.audiobook_transcribe_discard),
    );
    await tester.pumpAndSettle();
    expect(service.discardCalls, 1);
    expect(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, t.cancel));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  // BUG-2375：模型文件被截断/内容不是 onnx 时 ORT 报 `Protobuf parsing failed`，
  // 而整本转录跑在后台 isolate，错误跨边界只剩字符串（`Bad state: ...`），所以
  // 这里的判据只能按文本走。引擎已经把坏档删掉，界面必须退回「需要下载」并说明
  // 原因——从前是停在错误态、把那句 protobuf 原文甩给用户，重试永远同一个错。
  testWidgets('模型读不出图：退回下载态并说明模型已被清除', (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp)
      ..startError = StateError(
        'PlatformException(ORT_ERROR, Load model from '
        r'D:\hibiki\support\asr_models\reazonspeech-k2-v2\'
        'encoder-epoch-99-avg-1.onnx failed:Protobuf parsing failed., '
        'false, null)',
      );
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
    );
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_model_download),
      findsOneWidget,
      reason: '坏档已被删，界面该落回既有的下载阶段',
    );
    expect(
      find.textContaining(t.audiobook_transcribe_model_discarded),
      findsOneWidget,
      reason: '不说一句为什么，用户会以为刚下好的模型没生效',
    );
  });

  testWidgets('非坏档失败仍停在错误态，不谎报模型被清除', (WidgetTester tester) async {
    final _FakeService service = _FakeService(ready: true, jobsDir: tmp)
      ..startError = StateError('cuda out of memory');
    await tester.pumpWidget(wrap(service, (String? _) {}));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(FilledButton, t.audiobook_transcribe_start),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('cuda out of memory'), findsOneWidget);
    expect(
      find.textContaining(t.audiobook_transcribe_model_discarded),
      findsNothing,
    );
  });

  group('模型选择', () {
    late AsrModelCatalog catalog;

    Future<void> setCatalog(AsrModelCatalog next) async {
      catalog = next;
      asrModelRegistry = buildAsrModelRegistry(next);
    }

    // 真实 IO 只能在 setUp / tearDown 里做：testWidgets 体内是 fake async，
    // `Directory.systemTemp.createTemp()` 的 Future 永远不会完成，用例会一路挂到
    // 10 分钟超时（症状是「did not complete」，不是断言失败）。
    late Directory modelDir;

    setUp(() async {
      catalog = AsrModelCatalog.empty;
      asrModelRegistry = buildAsrModelRegistry(catalog);
      modelDir = await Directory.systemTemp.createTemp('asr_local_ui_');
      for (final String name in <String>[
        'tokens.txt',
        'encoder-epoch-99-avg-1.onnx',
        'decoder-epoch-99-avg-1.onnx',
        'joiner-epoch-99-avg-1.onnx',
      ]) {
        File(p.join(modelDir.path, name)).writeAsBytesSync(<int>[1, 2, 3]);
      }
    });
    tearDown(() async {
      asrModelRegistry = AsrModelRegistry.builtin();
      if (modelDir.existsSync()) await modelDir.delete(recursive: true);
    });

    Widget wrapWithCatalog(
      _FakeService service, {
      Future<String?> Function()? directoryPicker,
    }) =>
        wrap(
          service,
          (String? _) {},
          catalogGetter: () => catalog,
          catalogSetter: setCatalog,
          directoryPicker: directoryPicker,
        );

    testWidgets('默认显示该语言的内置模型，并列出可切换的备选', (WidgetTester tester) async {
      final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
      await tester.pumpWidget(wrapWithCatalog(service));
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();

      expect(find.text(kAsrJapanesePack.displayName), findsWidgets);

      await tester
          .tap(find.byKey(const ValueKey<String>('asr-transcribe-model')));
      await tester.pumpAndSettle();
      expect(find.text(kAsrOmnilingualPack.displayName), findsWidgets);
    });

    testWidgets('换模型：写进目录并按新包重新规划', (WidgetTester tester) async {
      final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
      await tester.pumpWidget(wrapWithCatalog(service));
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();
      final int plansBefore = service.planLanguages.length;

      await tester
          .tap(find.byKey(const ValueKey<String>('asr-transcribe-model')));
      await tester.pumpAndSettle();
      final Finder entry = find.text(kAsrOmnilingualPack.displayName).last;
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(catalog.choices[AsrLanguage.japanese.tag], kAsrOmnilingualPack.id);
      expect(service.planLanguages.length, greaterThan(plansBefore));
      // 只有日语改了：英语仍是内置英语包。
      expect(
        asrModelRegistry.packForLanguage(AsrLanguage.english)?.id,
        kAsrEnglishPack.id,
      );
    });

    testWidgets('手动指定本地模型：接入后自动选中', (WidgetTester tester) async {
      final _FakeService service = _FakeService(ready: true, jobsDir: tmp);
      await tester.pumpWidget(
        wrapWithCatalog(service, directoryPicker: () async => modelDir.path),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();

      // 「手动指定模型」弹层里有文本框，光标闪烁是一个永不停的动画：
      // pumpAndSettle 会一直等到超时。这几步一律用有限 pump。
      Future<void> settle() async {
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await tester
          .tap(find.byKey(const ValueKey<String>('asr-transcribe-model-add')));
      await settle();
      expect(
        find.byKey(const ValueKey<String>('asr-local-model-pick')),
        findsOneWidget,
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('asr-local-model-pick')));
      await settle();
      await tester
          .tap(find.byKey(const ValueKey<String>('asr-local-model-confirm')));
      await settle();

      expect(catalog.customPacks, hasLength(1));
      final String id = catalog.customPacks.single.id;
      expect(id, startsWith(kAsrCustomPackIdPrefix));
      expect(catalog.choices[AsrLanguage.japanese.tag], id);
      expect(asrModelRegistry.packForLanguage(AsrLanguage.japanese)?.id, id);
    });
  });
}
