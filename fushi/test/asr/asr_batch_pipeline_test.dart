import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';

/// 三段都由测试手动放行的假解码器：能精确观察「谁在等谁」。
class _Manual implements AsrPipelinedDecoder {
  final List<String> events = <String>[];
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};
  Object? failEncodeOf;

  static String label(List<AsrSpeechSegment> segs) =>
      segs.map((AsrSpeechSegment s) => s.startMs ~/ 1000).join(',');

  Future<void> _wait(String key) {
    events.add('$key start');
    return gates.putIfAbsent(key, Completer<void>.new).future.then((_) {
      events.add('$key done');
    });
  }

  /// 放行某一段（还没到就先登记，到了立刻过）。
  void release(String key) {
    gates.putIfAbsent(key, Completer<void>.new).complete();
  }

  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) =>
      AsrBatchFeatures.forTest(segments);

  @override
  Future<AsrBatchFeatures> computeFeaturesAsync(
    List<AsrSpeechSegment> segments,
  ) async {
    await _wait('fbank ${label(segments)}');
    return computeFeatures(segments);
  }

  @override
  Future<AsrEncodedBatch> encode(
    List<AsrSpeechSegment> segments, {
    AsrBatchFeatures? features,
  }) async {
    expect(features, isNotNull, reason: '流水线必须把算好的特征交给 encode');
    expect(identical(features!.segments, segments), isTrue);
    await _wait('enc ${label(segments)}');
    if (failEncodeOf == label(segments)) throw StateError('encode 炸了');
    return AsrEncodedBatch.forTest(segments);
  }

  @override
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encoded) async {
    await _wait('search ${label(encoded.segments)}');
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
  ) =>
      throw UnimplementedError();
}

List<AsrSpeechSegment> _batch(int startSec) => <AsrSpeechSegment>[
      AsrSpeechSegment(
        startSample: startSec * kAsrSampleRate,
        samples: Float32List(kAsrSampleRate),
      ),
    ];

/// 让微任务/已完成的 future 都跑完（不推进任何定时器）。
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('搜索不门控编码：第 k−1 批还在搜，第 k 批照样发 Run；深度 2 时第 k+1 批等第 k−1 批的 Run', () async {
    final _Manual pipe = _Manual();
    final List<String> committed = <String>[];
    final AsrBatchPipeline pipeline = AsrBatchPipeline(
      pipe: pipe,
      commit: (List<AsrSpeechSegment> b, List<AsrDecodedSegment> d) async {
        committed.add(_Manual.label(b));
      },
      encodeDepth: 2,
      maxUncommitted: 8,
    );
    await pipeline.submit(_batch(0));
    await pipeline.submit(_batch(1));
    await pipeline.submit(_batch(2));
    // 三批的 fbank 同时在算（提交不等任何东西）。
    await _settle();
    expect(
      pipe.events,
      containsAll(<String>['fbank 0 start', 'fbank 1 start', 'fbank 2 start']),
    );
    pipe.release('fbank 0');
    pipe.release('fbank 1');
    pipe.release('fbank 2');
    await _settle();
    // 深度 2：第 0、1 批的 Run 已发，第 2 批等第 0 批回来。
    expect(pipe.events, contains('enc 0 start'));
    expect(pipe.events, contains('enc 1 start'));
    expect(pipe.events, isNot(contains('enc 2 start')));
    pipe.release('enc 0');
    await _settle();
    // 第 0 批一回来：它的搜索发出，第 2 批的 Run 也发出——搜索没有门控编码。
    expect(pipe.events, contains('search 0 start'));
    expect(pipe.events, contains('enc 2 start'));
    expect(committed, isEmpty);
    pipe.release('enc 1');
    pipe.release('enc 2');
    await _settle();
    expect(pipe.events, contains('search 1 start'));
    expect(pipe.events, contains('search 2 start'));
    // 落盘按提交顺序：第 1 批先搜完也要等第 0 批。
    pipe.release('search 1');
    await _settle();
    expect(committed, isEmpty);
    pipe.release('search 0');
    await _settle();
    expect(committed, <String>['0', '1']);
    expect(pipeline.uncommitted.map(_Manual.label), <String>['2']);
    pipe.release('search 2');
    await pipeline.flush();
    expect(committed, <String>['0', '1', '2']);
    expect(pipeline.uncommitted, isEmpty);
  });

  test('背压：未落盘批到 maxUncommitted 时 submit 等到有批落盘', () async {
    final _Manual pipe = _Manual();
    final AsrBatchPipeline pipeline = AsrBatchPipeline(
      pipe: pipe,
      commit: (List<AsrSpeechSegment> b, List<AsrDecodedSegment> d) async {},
      encodeDepth: 1,
      maxUncommitted: 2,
    );
    await pipeline.submit(_batch(0));
    await pipeline.submit(_batch(1));
    bool third = false;
    final Future<void> pending = pipeline.submit(_batch(2)).then((_) {
      third = true;
    });
    await _settle();
    expect(third, isFalse, reason: '两批未落盘，第三批必须等');
    expect(pipeline.uncommitted.length, 2);
    for (final String k in <String>['fbank 0', 'enc 0', 'search 0']) {
      pipe.release(k);
    }
    await pending;
    expect(third, isTrue);
    expect(pipeline.uncommitted.map(_Manual.label), <String>['1', '2']);
    for (final String k in <String>[
      'fbank 1',
      'enc 1',
      'search 1',
      'fbank 2',
      'enc 2',
      'search 2',
    ]) {
      pipe.release(k);
    }
    await pipeline.flush();
    expect(pipeline.uncommitted, isEmpty);
  });

  test('某批 encode 抛错：flush 抛同一个错，之后的 submit 也抛，不吞', () async {
    final _Manual pipe = _Manual()..failEncodeOf = '1';
    final AsrBatchPipeline pipeline = AsrBatchPipeline(
      pipe: pipe,
      commit: (List<AsrSpeechSegment> b, List<AsrDecodedSegment> d) async {},
      encodeDepth: 2,
      maxUncommitted: 4,
    );
    await pipeline.submit(_batch(0));
    await pipeline.submit(_batch(1));
    for (final String k in <String>[
      'fbank 0',
      'enc 0',
      'search 0',
      'fbank 1',
      'enc 1',
    ]) {
      pipe.release(k);
    }
    await expectLater(pipeline.flush(), throwsStateError);
    await expectLater(pipeline.submit(_batch(2)), throwsStateError);
  });

  test('参数校验', () {
    final _Manual pipe = _Manual();
    Future<void> commit(
      List<AsrSpeechSegment> b,
      List<AsrDecodedSegment> d,
    ) async {}
    expect(
      () => AsrBatchPipeline(pipe: pipe, commit: commit, encodeDepth: 0),
      throwsArgumentError,
    );
    expect(
      () => AsrBatchPipeline(
        pipe: pipe,
        commit: commit,
        encodeDepth: 2,
        maxUncommitted: 1,
      ),
      throwsArgumentError,
    );
    expect(AsrBatchPipeline(pipe: pipe, commit: commit).maxUncommitted, 4);
  });
}
