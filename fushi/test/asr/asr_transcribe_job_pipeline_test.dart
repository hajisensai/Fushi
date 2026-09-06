import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:path/path.dart' as p;

/// 一块 PCM 里放 [segmentsPerChunk] 段的 fake 源 + 切段器。
class _Pcm implements AsrPcmSource {
  _Pcm({required this.chunks});
  final int chunks;

  @override
  Future<int?> probeDurationMs(String audioPath) async => chunks * 5000;

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    for (int c = 0; c < chunks; c++) {
      yield AsrPcmChunk(
        startSample: c * 5 * kAsrSampleRate,
        samples: Float32List(5 * kAsrSampleRate),
      );
    }
  }
}

class _Segmenter implements AsrSegmenter {
  _Segmenter({required this.perChunk});
  final int perChunk;

  @override
  Future<List<AsrSpeechSegment>> feed(AsrPcmChunk chunk) async {
    final int len = chunk.samples.length ~/ perChunk;
    return List<AsrSpeechSegment>.generate(
      perChunk,
      (int i) => AsrSpeechSegment(
        startSample: chunk.startSample + i * len,
        // 长度略有差异，让排序有事可做。
        samples: Float32List(len - i * 160),
      ),
    );
  }

  @override
  Future<List<AsrSpeechSegment>> flush() async => <AsrSpeechSegment>[];

  @override
  void reset() {}

  @override
  int? get inProgressSpeechStartSample => null;
}

/// 三段式 fake：encode / search 各自异步完成，记录事件顺序；结果 = 段起点秒数。
class _PipeDecoder implements AsrPipelinedDecoder, AsrBatchShaper {
  _PipeDecoder();

  /// 一批最多 3 段（模拟静态桶封顶）。
  static const int cap = 3;
  final List<String> events = <String>[];
  int encodeCalls = 0;
  int searchCalls = 0;
  int featureCalls = 0;
  int reusedFeatures = 0;
  int decodeBatchCalls = 0;

  static String _label(List<AsrSpeechSegment> segs) =>
      segs.map((AsrSpeechSegment s) => s.startMs ~/ 1000).join(',');

  @override
  int? batchCapFor(int longestSamples) => cap;

  /// 单桶：全部段同一个桶。
  @override
  int? bucketKeyFor(int longestSamples) => 1;

  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) {
    featureCalls++;
    return AsrBatchFeatures.forTest(segments);
  }

  @override
  Future<AsrBatchFeatures> computeFeaturesAsync(
    List<AsrSpeechSegment> segments,
  ) async {
    events.add('fbank-start ${_label(segments)}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    events.add('fbank-done ${_label(segments)}');
    return computeFeatures(segments);
  }

  @override
  Future<AsrEncodedBatch> encode(
    List<AsrSpeechSegment> segments, {
    AsrBatchFeatures? features,
  }) async {
    encodeCalls++;
    if (features != null && identical(features.segments, segments)) {
      reusedFeatures++;
    } else {
      computeFeatures(segments);
    }
    events.add('enc-start ${_label(segments)}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    events.add('enc-done ${_label(segments)}');
    return AsrEncodedBatch.forTest(segments);
  }

  @override
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encoded) async {
    searchCalls++;
    events.add('search-start ${_label(encoded.segments)}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    events.add('search-done ${_label(encoded.segments)}');
    return <AsrDecodedSegment>[
      for (final AsrSpeechSegment s in encoded.segments)
        AsrDecodedSegment(
          tokens: <String>['${s.startMs ~/ 1000}'],
          tokenOffsetsMs: const <int>[0],
        ),
    ];
  }

  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    decodeBatchCalls++;
    return search(await encode(segments));
  }
}

/// 只实现 decodeBatch 的普通解码器（对照组）。
class _PlainDecoder implements AsrBatchDecoder {
  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async => <AsrDecodedSegment>[
    for (final AsrSpeechSegment s in segments)
      AsrDecodedSegment(
        tokens: <String>['${s.startMs ~/ 1000}'],
        tokenOffsetsMs: const <int>[0],
      ),
  ];
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('asr_pipeline_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<List<AsrTranscribedSegment>> runJob(AsrBatchDecoder decoder) async {
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: Directory(p.join(tmp.path, decoder.runtimeType.toString())),
      audioPaths: const <String>['a.mp3'],
      modelId: 'm',
      pcm: _Pcm(chunks: 3),
      segmenter: _Segmenter(perChunk: 7),
      decoder: decoder,
      batchSize: 3,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    final List<AsrTranscribeEvent> events = await job.run().toList();
    expect(events.last, isA<AsrTranscribeFinishedEvent>());
    return AsrTranscribeJob.loadSegments(job.jobDir);
  }

  test('静态桶模式：一批恰好 cap 行（末批除外），batchSize / 音频预算不参与', () async {
    // batchSize=1 在动态路径下意味着一批 ≤ 20 s 音频（每段 5/7 s ≈ 0.7 s，
    // 也就是 4 段一批封顶）；有 shaper 时全按 cap=3 走。
    final _PipeDecoder pipe = _PipeDecoder();
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: Directory(p.join(tmp.path, 'cap')),
      audioPaths: const <String>['a.mp3'],
      modelId: 'm',
      pcm: _Pcm(chunks: 2),
      segmenter: _Segmenter(perChunk: 7),
      decoder: pipe,
      batchSize: 1,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    await job.run().toList();
    final List<int> sizes = pipe.events
        .where((String e) => e.startsWith('enc-start '))
        .map((String e) => e.substring(10).split(',').length)
        .toList();
    // 两块共 14 段：块末不再冲半批（留到下一块继续攒），只有文件末批不足 cap。
    expect(sizes, <int>[3, 3, 3, 3, 2]);
    expect(sizes.every((int n) => n <= _PipeDecoder.cap), isTrue);
    expect(job.maxBatchSegments, 4, reason: '动态路径的上限在这里没被用到');
  });

  test('流水线与串行解码产出相同的段落集合（按起点排序后逐条一致）', () async {
    final _PipeDecoder pipe = _PipeDecoder();
    final List<AsrTranscribedSegment> a = await runJob(pipe);
    final List<AsrTranscribedSegment> b = await runJob(_PlainDecoder());
    int byStart(AsrTranscribedSegment x, AsrTranscribedSegment y) =>
        x.startMs.compareTo(y.startMs);
    a.sort(byStart);
    b.sort(byStart);
    expect(a.length, 21);
    expect(
      a.map((AsrTranscribedSegment s) => '${s.startMs}:${s.text}').toList(),
      b.map((AsrTranscribedSegment s) => '${s.startMs}:${s.text}').toList(),
    );
    expect(pipe.decodeBatchCalls, 0, reason: '任务走的是三段式，不再调 decodeBatch');
    expect(pipe.encodeCalls, pipe.searchCalls);
  });

  test('编码第 i 批时搜索第 i-1 批：两者真的重叠', () async {
    final _PipeDecoder pipe = _PipeDecoder();
    await runJob(pipe);
    // 至少有一处「search-start X」出现在「enc-done Y」之前（Y 是后一批）。
    bool overlapped = false;
    String? pendingEnc;
    for (final String e in pipe.events) {
      if (e.startsWith('enc-start ')) pendingEnc = e.substring(10);
      if (e.startsWith('search-start ') && pendingEnc != null) {
        final int idxDone = pipe.events.indexOf('enc-done $pendingEnc');
        if (idxDone > pipe.events.indexOf(e)) {
          overlapped = true;
          break;
        }
      }
    }
    expect(overlapped, isTrue, reason: pipe.events.join('\n'));
  });

  test('窥视下一批提前算 fbank：encode 拿到的是同一份特征', () async {
    final _PipeDecoder pipe = _PipeDecoder();
    await runJob(pipe);
    expect(pipe.reusedFeatures, greaterThan(0));
    expect(
      pipe.featureCalls,
      pipe.encodeCalls,
      reason: '每批的 fbank 只算一次（提前算了就不再重算）',
    );
  });

  test('块末检查点 = 最早一个未落盘段的起点：在飞的批不等落盘（流水线跨块不断），攒批中的半批留到下一块', () async {
    final _PipeDecoder pipe = _PipeDecoder();
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: Directory(p.join(tmp.path, 'ckpt')),
      audioPaths: const <String>['a.mp3'],
      modelId: 'm',
      pcm: _Pcm(chunks: 3),
      segmenter: _Segmenter(perChunk: 5),
      decoder: pipe,
      batchSize: 3,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    // 每块 5 段、长度随段序递减。第一块：A=[0,1,2] 提交流水线、[3,4] 不够 cap
    // 留下；块末 A 还没落盘（特征都还没算完），检查点 = 0 s（未落盘批的起点也
    // 算「未落盘」），块末不等它。之后每个检查点都必须满足不变式：**起点早于
    // 恢复点的段全部已落盘**（恢复时它们之后的会重跑，之前的不会丢）。
    int? resumeAtChunk1;
    int checkpoints = 0;
    await for (final AsrTranscribeEvent e in job.run()) {
      if (e is! AsrTranscribeProgressEvent) continue;
      final AsrJobState state = await AsrTranscribeJob.loadState(
        job.jobDir,
        const <String>['a.mp3'],
        modelId: 'm',
      );
      final int resume = state.resumeSamples[0];
      if (e.progress.processedMs == 5000) resumeAtChunk1 ??= resume;
      if (resume < 0) continue;
      checkpoints++;
      final Set<int> persisted = (await AsrTranscribeJob.loadSegments(
        job.jobDir,
      )).map((AsrTranscribedSegment s) => s.startMs).toSet();
      for (int startMs = 0; startMs < 15000; startMs += 1000) {
        if (startMs * kAsrSampleRate ~/ 1000 < resume) {
          expect(
            persisted,
            contains(startMs),
            reason: '恢复点 $resume 之前的段 $startMs ms 还没落盘：续跑会漏段',
          );
        }
      }
    }
    expect(resumeAtChunk1, 0, reason: '第一块末 A 未落盘，恢复点必须含它');
    expect(checkpoints, greaterThan(0));
    // 跑完后 15 段一个不少、无重复。
    final List<int> all = (await AsrTranscribeJob.loadSegments(job.jobDir))
        .map((AsrTranscribedSegment s) => s.startMs)
        .toList()
      ..sort();
    expect(all, List<int>.generate(15, (int i) => i * 1000));
  });

  test('两个桶：同一批只装同一个桶的段，短段不被长段的桶带走；攒满的桶先发', () async {
    final _TwoBucketDecoder pipe = _TwoBucketDecoder();
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: Directory(p.join(tmp.path, 'two-buckets')),
      audioPaths: const <String>['a.mp3'],
      modelId: 'm',
      pcm: _Pcm(chunks: 2),
      // 每块 2 长段 + 5 短段。
      segmenter: _MixedSegmenter(longPerChunk: 2, shortPerChunk: 5),
      decoder: pipe,
      batchSize: 1,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    await job.run().toList();
    final List<List<int>> batches = pipe.batches;
    // 每批只有一种桶。
    for (final List<int> b in batches) {
      expect(b.toSet(), hasLength(1), reason: '混桶批：$b');
    }
    // 长段桶 cap 2：4 段 → 2 + 2；短段桶 cap 4：10 段 → 4 + 4 + 2（末批残批）。
    final List<int> longSizes = batches
        .where((List<int> b) => b.first == _TwoBucketDecoder.longKey)
        .map((List<int> b) => b.length)
        .toList();
    final List<int> shortSizes = batches
        .where((List<int> b) => b.first == _TwoBucketDecoder.shortKey)
        .map((List<int> b) => b.length)
        .toList();
    expect(longSizes, <int>[2, 2]);
    expect(shortSizes, <int>[4, 4, 2]);
    // 第一块只有 2 长 + 5 短：长段桶攒满先发，短段桶攒满 4 行也发，剩 1 短段留到
    // 第二块——块末没有任何半批。
    expect(batches.take(2).map((List<int> b) => b.length), <int>[2, 4]);
    final int total = (await AsrTranscribeJob.loadSegments(job.jobDir)).length;
    expect(total, 14);
  });
}

/// 两个桶：段 ≥ 1 s 进长段桶（cap 2），否则短段桶（cap 4）；记录每批的桶键序列。
class _TwoBucketDecoder extends _PipeDecoder {
  static const int longKey = 2;
  static const int shortKey = 1;
  final List<List<int>> batches = <List<int>>[];

  static bool _isLong(int samples) => samples >= kAsrSampleRate;

  @override
  int? batchCapFor(int longestSamples) => _isLong(longestSamples) ? 2 : 4;

  @override
  int? bucketKeyFor(int longestSamples) =>
      _isLong(longestSamples) ? longKey : shortKey;

  @override
  Future<AsrEncodedBatch> encode(
    List<AsrSpeechSegment> segments, {
    AsrBatchFeatures? features,
  }) {
    batches.add(<int>[
      for (final AsrSpeechSegment s in segments) bucketKeyFor(s.samples.length)!,
    ]);
    return super.encode(segments, features: features);
  }
}

/// 每块先 [longPerChunk] 个 2 s 长段、再 [shortPerChunk] 个 0.5 s 短段。
class _MixedSegmenter implements AsrSegmenter {
  _MixedSegmenter({required this.longPerChunk, required this.shortPerChunk});
  final int longPerChunk;
  final int shortPerChunk;

  @override
  Future<List<AsrSpeechSegment>> feed(AsrPcmChunk chunk) async {
    final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
    int cursor = chunk.startSample;
    for (int i = 0; i < longPerChunk; i++) {
      out.add(
        AsrSpeechSegment(
          startSample: cursor,
          samples: Float32List(2 * kAsrSampleRate - i * 160),
        ),
      );
      cursor += 2 * kAsrSampleRate;
    }
    for (int i = 0; i < shortPerChunk; i++) {
      out.add(
        AsrSpeechSegment(
          startSample: cursor,
          samples: Float32List(kAsrSampleRate ~/ 2 - i * 160),
        ),
      );
      cursor += kAsrSampleRate ~/ 2;
    }
    return out;
  }

  @override
  Future<List<AsrSpeechSegment>> flush() async => <AsrSpeechSegment>[];

  @override
  void reset() {}

  @override
  int? get inProgressSpeechStartSample => null;
}
