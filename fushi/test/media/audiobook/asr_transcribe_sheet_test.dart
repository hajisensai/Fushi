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
  ) async => <AsrSpeechSegment>[
    AsrSpeechSegment(startSample: 0, samples: Float32List(2 * kAsrSampleRate)),
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
  ) async => segments
      .map(
        (AsrSpeechSegment _) => AsrDecodedSegment(
          tokens: const <String>['今', '日', '。'],
          tokenOffsetsMs: const <int>[100, 300, 600],
        ),
      )
      .toList();
}

/// 假服务：模型就绪与否、已完成产物可编程；`start` 装配真任务 + 假会话。
class _FakeService extends AsrTranscriptionService {
  _FakeService({required this.ready, required this.jobsDir, this.existingSrt})
    : super(
        pcm: _FakePcm(),
        openStore: () async => AsrModelStore(jobsDir),
        jobsRoot: () async => jobsDir,
      );

  bool ready;
  final Directory jobsDir;
  String? existingSrt;
  int downloadCalls = 0;
  int discardCalls = 0;

  @override
  Future<AsrTranscribePlan> plan(AsrAccelerationPreference preference) async {
    return AsrTranscribePlan(
      variant: AsrEncoderVariant.int8,
      expectedProvider: OnnxExecutionProvider.cpu,
      modelStatus: AsrModelStatus(
        ready: ready,
        diskBytes: 0,
        totalBytes: 1000,
        obtainedBytes: ready ? 1000 : 250,
      ),
    );
  }

  @override
  Stream<ModelDownloadEvent> downloadModel(AsrEncoderVariant variant) async* {
    downloadCalls++;
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
  Future<String?> finishedSrtPath(List<String> audioPaths) async => existingSrt;

  @override
  Future<AsrJobState?> existingState(List<String> audioPaths) async => null;

  @override
  Future<void> discard(List<String> audioPaths) async {
    discardCalls++;
    existingSrt = null;
  }

  @override
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
  }) async {
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
      pcm: _FakePcm(),
      segmenter: _FakeSegmenter(),
      decoder: _FakeDecoder(),
      progressInterval: Duration.zero,
    );
    return AsrRunningTranscription(sessions: sessions, job: job);
  }
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_sheet_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Widget wrap(_FakeService service, void Function(String?) onResult) {
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
