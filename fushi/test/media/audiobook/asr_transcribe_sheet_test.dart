import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_transcription_service.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';
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
  int downloadCalls = 0;
  int discardCalls = 0;
  final List<AsrLanguage> planLanguages = <AsrLanguage>[];
  AsrLanguage? lastDownloadLanguage;
  AsrLanguage? lastStartLanguage;

  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async {
    planLanguages.add(language);
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
  await tester.tap(find.byKey(const ValueKey<String>('asr-transcribe-language')));
  await tester.pumpAndSettle();
  final Finder entry = find.text(language.nativeName).last;
  // 菜单有最大高度、可滚动；条目可能在视口外。
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

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
    // 下载完成后的就绪行带英语包名。
    expect(
      find.textContaining(kAsrEnglishPack.displayName),
      findsOneWidget,
    );
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
    expect(asrLanguageHintFromBookLanguage('zh-Hant-HK'), AsrLanguage.cantonese);
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
      find.textContaining(kAsrEnglishPack.displayName),
      findsOneWidget,
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
}
