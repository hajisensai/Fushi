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

  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) {
    featureCalls++;
    return AsrBatchFeatures.forTest(segments);
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
  ) async =>
      <AsrDecodedSegment>[
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

  test('块末检查点之前在飞的批已全部落盘', () async {
    final _PipeDecoder pipe = _PipeDecoder();
    final AsrTranscribeJob job = AsrTranscribeJob(
      jobDir: Directory(p.join(tmp.path, 'ckpt')),
      audioPaths: const <String>['a.mp3'],
      modelId: 'm',
      pcm: _Pcm(chunks: 2),
      segmenter: _Segmenter(perChunk: 5),
      decoder: pipe,
      batchSize: 3,
      chunkSeconds: 5,
      progressInterval: Duration.zero,
    );
    // 第一块结束时有两条 processedMs=5000 的进度：块内节流那条在检查点之前
    // （在飞的批可以还没落盘），块末那条紧跟检查点之后——看后者。
    int segmentsAtCheckpoint = -1;
    await for (final AsrTranscribeEvent e in job.run()) {
      if (e is AsrTranscribeProgressEvent && e.progress.processedMs == 5000) {
        final AsrJobState state = await AsrTranscribeJob.loadState(
          job.jobDir,
          const <String>['a.mp3'],
          modelId: 'm',
        );
        if (state.resumeSamples[0] >= 5 * kAsrSampleRate) {
          segmentsAtCheckpoint = (await AsrTranscribeJob.loadSegments(
            job.jobDir,
          ))
              .length;
        }
      }
    }
    expect(segmentsAtCheckpoint, 5, reason: '第一块 5 段在检查点前全部落盘');
  });
}
