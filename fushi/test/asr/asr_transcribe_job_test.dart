import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_types.dart';

/// 测试用模型包 id（任务状态只把它当不透明字符串比较）。
const String _kModelId = 'test-pack';

/// 合成 PCM 源：每个文件 [durationsMs] 毫秒的静音，按 chunkSeconds 切块。
class _FakePcm implements AsrPcmSource {
  _FakePcm(this.durationsMs, {this.probeFails = const <int>{}});

  final Map<String, int> durationsMs;
  final Set<int> probeFails;
  final List<({String path, int start})> decodeCalls =
      <({String path, int start})>[];

  @override
  Future<int?> probeDurationMs(String audioPath) async {
    final int idx = durationsMs.keys.toList().indexOf(audioPath);
    if (probeFails.contains(idx)) return null;
    return durationsMs[audioPath];
  }

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    decodeCalls.add((path: audioPath, start: startSample));
    final int total = durationsMs[audioPath]! * kAsrSampleRate ~/ 1000;
    int pos = startSample;
    while (pos < total) {
      final int n = (chunkSeconds * kAsrSampleRate).clamp(0, total - pos);
      yield AsrPcmChunk(startSample: pos, samples: Float32List(n));
      pos += n;
    }
  }
}

/// 假切段器：每块产出固定数量的 1 秒语音段；可模拟块边界处的进行中语音。
class _FakeSegmenter implements AsrSegmenter {
  _FakeSegmenter({this.segmentsPerChunk = 3, this.inProgressOffsetSamples});

  final int segmentsPerChunk;

  /// 非 null 时：feed 后报告「块末尾往前这么多样本处有进行中语音」。
  final int? inProgressOffsetSamples;
  int? _inProgress;
  int resets = 0;

  @override
  Future<List<AsrSpeechSegment>> feed(AsrPcmChunk chunk) async {
    final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
    final int step = chunk.samples.length ~/ (segmentsPerChunk + 1);
    for (int i = 0; i < segmentsPerChunk; i++) {
      out.add(
        AsrSpeechSegment(
          startSample: chunk.startSample + i * step,
          samples: Float32List(kAsrSampleRate),
        ),
      );
    }
    _inProgress = inProgressOffsetSamples == null
        ? null
        : chunk.endSample - inProgressOffsetSamples!;
    return out;
  }

  @override
  Future<List<AsrSpeechSegment>> flush() async {
    _inProgress = null;
    return <AsrSpeechSegment>[];
  }

  @override
  void reset() {
    resets++;
    _inProgress = null;
  }

  @override
  int? get inProgressSpeechStartSample => _inProgress;
}

class _FakeDecoder implements AsrBatchDecoder {
  final List<int> batchSizes = <int>[];

  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    batchSizes.add(segments.length);
    return segments
        .map(
          (AsrSpeechSegment s) => AsrDecodedSegment(
            tokens: const <String>['あ', '。'],
            tokenOffsetsMs: const <int>[100, 500],
          ),
        )
        .toList();
  }
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_job_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('两文件全程跑完：进度单调、检查点落盘、SRT 生成、时间按文件偏移', () async {
    final _FakePcm pcm = _FakePcm(<String, int>{
      'a.mp3': 20000,
      'b.mp3': 10000,
    });
    final _FakeDecoder decoder = _FakeDecoder();
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: <String>['a.mp3', 'b.mp3'],
      modelId: _kModelId,
      pcm: pcm,
      segmenter: _FakeSegmenter(),
      decoder: decoder,
      batchSize: 2,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    final List<AsrTranscribeEvent> events = await job.run().toList();
    expect(events.last, isA<AsrTranscribeFinishedEvent>());
    final AsrTranscribeResult r =
        (events.last as AsrTranscribeFinishedEvent).result;
    // a: 4 块 × 3 段 = 12；b: 2 块 × 3 段 = 6。
    expect(r.segmentCount, 18);
    expect(r.cueCount, 18);
    expect(r.totalMs, 30000);
    expect(File(r.srtPath).existsSync(), isTrue);
    final String srt = File(r.srtPath).readAsStringSync();
    // 第二个文件的第一条 cue 落在 20 s 偏移之后。
    expect(srt, contains('00:00:20,000 --> '));
    // 进度单调不减。
    int last = -1;
    for (final AsrTranscribeEvent e in events) {
      if (e is AsrTranscribeProgressEvent) {
        expect(e.progress.processedMs, greaterThanOrEqualTo(last));
        last = e.progress.processedMs;
      }
    }
    // 批次大小 ≤ maxBatchSegments（batchSize 是 20 s 段的参考值，短段按音频预算
    // 可以多装，上限 4 倍）。
    expect(
        decoder.batchSizes.every((int n) => n <= job.maxBatchSegments), isTrue);
    expect(decoder.batchSizes.every((int n) => n >= 1), isTrue);
    final AsrJobState state = await AsrTranscribeJob.loadState(
      tmp,
      <String>['a.mp3', 'b.mp3'],
      modelId: _kModelId,
    );
    expect(state.finished, isTrue);
    expect(state.isFileDone(0), isTrue);
    expect(state.isFileDone(1), isTrue);
  });

  test('暂停后从检查点续跑：不重复段落，恢复点取进行中语音起点', () async {
    final List<String> paths = <String>['a.mp3'];
    final _FakePcm pcm = _FakePcm(<String, int>{'a.mp3': 15000});
    // 每块末尾前 1 秒有进行中语音。
    final _FakeSegmenter seg = _FakeSegmenter(
      inProgressOffsetSamples: kAsrSampleRate,
    );
    final AsrTranscribeJob first = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: paths,
      modelId: _kModelId,
      pcm: pcm,
      segmenter: seg,
      decoder: _FakeDecoder(),
      batchSize: 8,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    // 第一块处理完即请求暂停。
    final List<AsrTranscribeEvent> firstEvents = <AsrTranscribeEvent>[];
    await for (final AsrTranscribeEvent e in first.run()) {
      firstEvents.add(e);
      if (e is AsrTranscribeProgressEvent) first.requestPause();
    }
    expect(firstEvents.last, isA<AsrTranscribePausedEvent>());
    final AsrJobState paused =
        await AsrTranscribeJob.loadState(tmp, paths, modelId: _kModelId);
    // 第一块 5 s = 80000 样本，进行中语音起点 = 80000 - 16000。
    expect(paused.resumeSamples.single, 5 * kAsrSampleRate - kAsrSampleRate);
    final int segmentsAfterPause = (await AsrTranscribeJob.loadSegments(
      tmp,
    ))
        .length;
    expect(segmentsAfterPause, 3);

    // 续跑：从恢复点开始解码。
    final _FakePcm pcm2 = _FakePcm(<String, int>{'a.mp3': 15000});
    final AsrTranscribeJob second = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: paths,
      modelId: _kModelId,
      pcm: pcm2,
      segmenter: _FakeSegmenter(),
      decoder: _FakeDecoder(),
      batchSize: 8,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    final List<AsrTranscribeEvent> secondEvents = await second.run().toList();
    expect(secondEvents.last, isA<AsrTranscribeFinishedEvent>());
    expect(pcm2.decodeCalls.single.start, 5 * kAsrSampleRate - kAsrSampleRate);
    // 第一块 3 段保留 + 续跑覆盖剩余 11 s（3 块）× 3 段。
    final List<AsrTranscribedSegment> all = await AsrTranscribeJob.loadSegments(
      tmp,
    );
    expect(all.length, 3 + 9);
    // 无重复起点。
    expect(
      all.map((AsrTranscribedSegment s) => s.startMs).toSet().length,
      all.length,
    );
  });

  test('路径列表变化视为新任务，旧产物清空', () async {
    // 旧产物里放一条**合法**段落：若不清空会被当成本任务的段落带进结果。
    File(
      '${tmp.path}/${AsrJobFiles.segments}',
    ).writeAsStringSync('{"f":0,"s":0,"e":900,"t":["旧"],"m":[100]}\n');
    File('${tmp.path}/${AsrJobFiles.state}').writeAsStringSync(
      '{"version":1,"audioPaths":["x.mp3"],"resumeSamples":[-1],"finished":true}',
    );
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: <String>['a.mp3'],
      modelId: _kModelId,
      pcm: _FakePcm(<String, int>{'a.mp3': 3000}),
      segmenter: _FakeSegmenter(segmentsPerChunk: 1),
      decoder: _FakeDecoder(),
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    final List<AsrTranscribeEvent> events = await job.run().toList();
    final AsrTranscribeResult r =
        (events.last as AsrTranscribeFinishedEvent).result;
    expect(r.segmentCount, 1);
  });

  test('state.json 版本不是当前版本（v1 旧链路产物）视为新任务，旧产物不复用', () async {
    // BUG-2164：v1 时期带章节的 m4b 转出来整章噪声「あ」，但任务已 finished，UI 会
    // 直接复用。升版后同路径的旧目录必须重跑。
    File(
      '${tmp.path}/${AsrJobFiles.segments}',
    ).writeAsStringSync('{"f":0,"s":0,"e":900,"t":["あ"],"m":[100]}\n');
    File('${tmp.path}/${AsrJobFiles.state}').writeAsStringSync(
      '{"version":1,"audioPaths":["a.mp3"],"fileDurationsMs":[3000],'
      '"resumeSamples":[-1],"finished":true}',
    );
    final ({AsrJobState state, bool fresh}) loaded =
        await AsrTranscribeJob.loadStateDetailed(tmp, <String>['a.mp3'],
            modelId: _kModelId);
    expect(loaded.fresh, isTrue);
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: <String>['a.mp3'],
      modelId: _kModelId,
      pcm: _FakePcm(<String, int>{'a.mp3': 3000}),
      segmenter: _FakeSegmenter(segmentsPerChunk: 1),
      decoder: _FakeDecoder(),
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    final List<AsrTranscribeEvent> events = await job.run().toList();
    final AsrTranscribeResult r =
        (events.last as AsrTranscribeFinishedEvent).result;
    expect(r.segmentCount, 1);
    expect(
      File('${tmp.path}/${AsrJobFiles.segments}').readAsStringSync(),
      isNot(contains('"旧噪"')),
    );
    // 重跑后写回的是当前版本。
    expect(
      File('${tmp.path}/${AsrJobFiles.state}').readAsStringSync(),
      contains('"version":${AsrJobState.currentVersion}'),
    );
  });

  test('时长探测失败：用实际解码样本数补时长，SRT 偏移仍正确', () async {
    final _FakePcm pcm = _FakePcm(
      <String, int>{'a.mp3': 6000, 'b.mp3': 4000},
      probeFails: <int>{0},
    );
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: <String>['a.mp3', 'b.mp3'],
      modelId: _kModelId,
      pcm: pcm,
      segmenter: _FakeSegmenter(segmentsPerChunk: 1),
      decoder: _FakeDecoder(),
      chunkSeconds: 10,
      progressInterval: Duration.zero,
    );
    final List<AsrTranscribeEvent> events = await job.run().toList();
    final AsrTranscribeResult r =
        (events.last as AsrTranscribeFinishedEvent).result;
    expect(r.fileDurationsMs, <int>[6000, 4000]);
    expect(r.totalMs, 10000);
  });

  test('state.json 的 modelId 与传入不符视为新任务（不同词表的段落不能混续）', () async {
    File(
      '${tmp.path}/${AsrJobFiles.segments}',
    ).writeAsStringSync('{"f":0,"s":0,"e":900,"t":["旧"],"m":[100]}\n');
    File('${tmp.path}/${AsrJobFiles.state}').writeAsStringSync(
      '{"version":${AsrJobState.currentVersion},"audioPaths":["a.mp3"],'
      '"modelId":"other-pack","fileDurationsMs":[3000],'
      '"resumeSamples":[-1],"finished":true}',
    );
    final ({AsrJobState state, bool fresh}) loaded =
        await AsrTranscribeJob.loadStateDetailed(
      tmp,
      <String>['a.mp3'],
      modelId: _kModelId,
    );
    expect(loaded.fresh, isTrue);
    expect(loaded.state.modelId, _kModelId);
    expect(loaded.state.finished, isFalse);

    // 同一份文件按它自己的 modelId 读则原样复用。
    final ({AsrJobState state, bool fresh}) same =
        await AsrTranscribeJob.loadStateDetailed(
      tmp,
      <String>['a.mp3'],
      modelId: 'other-pack',
    );
    expect(same.fresh, isFalse);
    expect(same.state.finished, isTrue);

    // 真跑一遍：旧段落被清掉，state 写回传入的 modelId。
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: <String>['a.mp3'],
      modelId: _kModelId,
      pcm: _FakePcm(<String, int>{'a.mp3': 3000}),
      segmenter: _FakeSegmenter(segmentsPerChunk: 1),
      decoder: _FakeDecoder(),
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    final List<AsrTranscribeEvent> events = await job.run().toList();
    final AsrTranscribeResult r =
        (events.last as AsrTranscribeFinishedEvent).result;
    expect(r.segmentCount, 1);
    expect(
      File('${tmp.path}/${AsrJobFiles.segments}').readAsStringSync(),
      isNot(contains('"旧"')),
    );
    final AsrJobState written = await AsrTranscribeJob.loadState(
      tmp,
      <String>['a.mp3'],
      modelId: _kModelId,
    );
    expect(written.modelId, _kModelId);
    expect(written.finished, isTrue);
  });

  test('旧 version 2（无 modelId 时代）的 state.json 视为新任务', () async {
    File('${tmp.path}/${AsrJobFiles.state}').writeAsStringSync(
      '{"version":2,"audioPaths":["a.mp3"],"fileDurationsMs":[3000],'
      '"resumeSamples":[-1],"finished":true}',
    );
    final ({AsrJobState state, bool fresh}) loaded =
        await AsrTranscribeJob.loadStateDetailed(
      tmp,
      <String>['a.mp3'],
      modelId: _kModelId,
    );
    expect(loaded.fresh, isTrue);
    expect(loaded.state.finished, isFalse);
    expect(loaded.state.resumeSamples, <int>[0]);
  });

  test('toJson 带 modelId 与当前版本 3，fromJson 往返', () {
    final AsrJobState state = AsrJobState.fresh(
      const <String>['a.mp3', 'b.mp3'],
      modelId: _kModelId,
    );
    final Map<String, Object?> json = state.toJson();
    expect(json['version'], 3);
    expect(AsrJobState.currentVersion, 3);
    expect(json['modelId'], _kModelId);
    expect(json['audioPaths'], <String>['a.mp3', 'b.mp3']);
    expect(json['resumeSamples'], <int>[0, 0]);
    expect(json['fileDurationsMs'], <int?>[null, null]);
    expect(json['finished'], isFalse);

    final AsrJobState back = AsrJobState.fromJson(json);
    expect(back.modelId, _kModelId);
    expect(back.audioPaths, state.audioPaths);
    expect(back.resumeSamples, state.resumeSamples);
    expect(back.finished, isFalse);
    // copyWith 不丢 modelId。
    expect(state.copyWith(finished: true).modelId, _kModelId);
  });

  test('run 只能调用一次', () async {
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: tmp,
      audioPaths: <String>['a.mp3'],
      modelId: _kModelId,
      pcm: _FakePcm(<String, int>{'a.mp3': 1000}),
      segmenter: _FakeSegmenter(segmentsPerChunk: 1),
      decoder: _FakeDecoder(),
      progressInterval: Duration.zero,
    );
    await job.run().toList();
    expect(() => job.run().toList(), throwsStateError);
  });

  group('pickBatchSize（按音频预算成批）', () {
    AsrSpeechSegment seg(int seconds) => AsrSpeechSegment(
          startSample: 0,
          samples: Float32List(seconds * kAsrSampleRate),
        );
    const int budget = 32 * 20 * kAsrSampleRate;

    test('全是 20 s 长段：恰好 batchSize 段', () {
      final List<AsrSpeechSegment> sorted = List<AsrSpeechSegment>.filled(
        40,
        seg(20),
      );
      expect(
        AsrTranscribeJob.pickBatchSize(
          sorted,
          budgetSamples: budget,
          maxSegments: 128,
        ),
        32,
      );
    });

    test('短段可以装更多，但不超过 maxSegments', () {
      final List<AsrSpeechSegment> sorted = List<AsrSpeechSegment>.filled(
        300,
        seg(2),
      );
      expect(
        AsrTranscribeJob.pickBatchSize(
          sorted,
          budgetSamples: budget,
          maxSegments: 128,
        ),
        128,
      );
    });

    test('短于批内最长段 0.8 倍的段留给下一批（padding 最坏 1.25×）', () {
      final List<AsrSpeechSegment> sorted = <AsrSpeechSegment>[
        seg(20),
        seg(18),
        seg(16),
        seg(15),
        seg(3),
      ];
      expect(
        AsrTranscribeJob.pickBatchSize(
          sorted,
          budgetSamples: budget,
          maxSegments: 128,
        ),
        3,
        reason: '16 = 20 × 0.8 刚好够，15 不够',
      );
    });

    test('单段超预算也至少取 1；空列表取 0', () {
      expect(
        AsrTranscribeJob.pickBatchSize(
          <AsrSpeechSegment>[seg(30)],
          budgetSamples: 10 * kAsrSampleRate,
          maxSegments: 4,
        ),
        1,
      );
      expect(
        AsrTranscribeJob.pickBatchSize(
          const <AsrSpeechSegment>[],
          budgetSamples: budget,
          maxSegments: 4,
        ),
        0,
      );
    });
  });
}
