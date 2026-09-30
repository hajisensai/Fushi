import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/beam_search.dart';
import 'package:fushi_engine/ocr/manga_ocr_kv_recognizer.dart';
import 'package:fushi_engine/ocr/manga_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/manga_ocr_tokenizer.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_tensor_handles.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

/// 测试词表：0=[PAD] 1=[UNK] 2=[CLS] 3=[SEP] 4=[MASK] 5=こ 6=ん 7=##は。
const String kVocabText = '[PAD]\n[UNK]\n[CLS]\n[SEP]\n[MASK]\nこ\nん\n##は\n';
const int kVocabSize = 8;

/// 按「完整历史（含 [CLS]）→ 下一 token 的 logits」出分的玩具语言模型。
///
/// 故意让多条 beam 互相竞争、在不同长度结束，beam 重排会真的发生——KV 版若把
/// past 按错的 beam 取回，这里的输出就会与经典版不同。
typedef ToyLanguageModel = List<double> Function(List<int> history);

List<double> branchingModel(List<int> history) {
  final List<double> logits = List<double>.filled(kVocabSize, -9);
  final int last = history.last;
  final int length = history.length;
  switch (last) {
    case 2: // [CLS]
      logits[5] = 2.0;
      logits[6] = 1.9;
      logits[7] = 0.4;
    case 5: // こ
      logits[6] = 1.2 + 0.1 * length;
      logits[7] = 1.4;
      logits[3] = 0.3 * length;
    case 6: // ん
      logits[3] = 1.0 + 0.2 * length;
      logits[5] = 1.1;
      logits[7] = 0.9;
    case 7: // ##は
      logits[3] = 1.6;
      logits[6] = 1.5;
    default:
      logits[3] = 5;
  }
  return logits;
}

class _FakeEncoder implements OcrSession {
  int runs = 0;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    runs++;
    expect(inputs['pixel_values']!.shape, <int>[1, 3, 224, 224]);
    return <String, OcrTensor>{
      'last_hidden_state': OcrTensor.float32(Float32List(6), <int>[1, 2, 3]),
    };
  }

  @override
  Future<void> close() async {}
}

class _FakeCross implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    expect(inputs['encoder_hidden_states']!.shape, <int>[1, 2, 3]);
    return <String, OcrTensor>{
      'cross_key_values': OcrTensor.float32(Float32List(4), <int>[4, 1]),
    };
  }

  @override
  Future<void> close() async {}
}

/// KV 版 decoder：past 里存每条 beam 的 token 历史（形状 [Bp, P]；首步是识别器上传
/// 的全零占位 [4,1,12,1,64]，当作空历史）。按 beam_idx 取回、接上 input_ids、按
/// 完整历史出 logits，present 回传新历史——与真实导出图的数据流同构。
class _FakeKvDecoder implements OcrSession {
  _FakeKvDecoder(this.model);

  final ToyLanguageModel model;
  final List<List<int>> inputIdShapes = <List<int>>[];
  final List<List<int>> beamIdx = <List<int>>[];

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final OcrTensor ids = inputs['input_ids']!;
    final OcrTensor idx = inputs['beam_idx']!;
    final OcrTensor past = inputs['past_key_values']!;
    expect(inputs['cross_key_values']!.shape, <int>[4, 1]);
    inputIdShapes.add(List<int>.from(ids.shape));
    beamIdx.add(<int>[for (final int v in idx.intData!) v]);
    final int beams = ids.shape[0];
    final bool placeholder = past.shape.length == 5;
    final int pastLength = placeholder ? 0 : past.shape[1];
    final List<List<int>> histories = <List<int>>[];
    for (int b = 0; b < beams; b++) {
      final int source = idx.intData![b];
      final List<int> prior = placeholder
          ? <int>[]
          : <int>[
              for (int t = 0; t < pastLength; t++)
                past.floatData![source * pastLength + t].round(),
            ];
      histories.add(<int>[...prior, ids.intData![b]]);
    }
    final int length = histories.first.length;
    final Float32List present = Float32List(beams * length);
    final Float32List logits = Float32List(beams * kVocabSize);
    for (int b = 0; b < beams; b++) {
      for (int t = 0; t < length; t++) {
        present[b * length + t] = histories[b][t].toDouble();
      }
      logits.setRange(
        b * kVocabSize,
        (b + 1) * kVocabSize,
        model(histories[b]),
      );
    }
    return <String, OcrTensor>{
      'logits': OcrTensor.float32(logits, <int>[beams, kVocabSize]),
      'present_key_values': OcrTensor.float32(present, <int>[beams, length]),
    };
  }

  @override
  Future<void> close() async {}
}

/// 经典 decoder：每步收整段序列，只取最后位置的 logits 由同一个玩具模型给出。
class _FakeClassicDecoder implements OcrSession {
  _FakeClassicDecoder(this.model);

  final ToyLanguageModel model;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final OcrTensor ids = inputs['input_ids']!;
    final int beams = ids.shape[0];
    final int seqLen = ids.shape[1];
    final Float32List logits = Float32List(beams * seqLen * kVocabSize);
    for (int b = 0; b < beams; b++) {
      final List<int> history = <int>[
        for (int t = 0; t < seqLen; t++) ids.intData![b * seqLen + t],
      ];
      logits.setRange(
        (b * seqLen + seqLen - 1) * kVocabSize,
        (b * seqLen + seqLen) * kVocabSize,
        model(history),
      );
    }
    return <String, OcrTensor>{
      'logits': OcrTensor.float32(logits, <int>[beams, seqLen, kVocabSize]),
    };
  }

  @override
  Future<void> close() async {}
}

/// 把普通会话包成句柄后端，并统计活着的句柄（泄漏检测）。
class _CountingHandleSession implements OcrHandleSession {
  _CountingHandleSession(this._inner, this.live);

  final OcrSession _inner;
  final Set<_CountedHandle> live;
  int uploads = 0;

  @override
  Future<OcrTensorHandle> upload(OcrTensor tensor) async {
    uploads++;
    return _CountedHandle(tensor, live);
  }

  @override
  Future<OcrHandleRunResult> runWithHandles({
    Map<String, OcrTensor> tensors = const <String, OcrTensor>{},
    Map<String, OcrTensorHandle> handles = const <String, OcrTensorHandle>{},
    required Set<String> fetch,
  }) async {
    final Map<String, OcrTensor> inputs = <String, OcrTensor>{...tensors};
    for (final MapEntry<String, OcrTensorHandle> entry in handles.entries) {
      final _CountedHandle handle = entry.value as _CountedHandle;
      expect(live, contains(handle), reason: '${entry.key} used after dispose');
      inputs[entry.key] = handle.tensor;
    }
    final Map<String, OcrTensor> outputs = await _inner.run(inputs);
    return OcrHandleRunResult(
      fetched: <String, OcrTensor>{
        for (final MapEntry<String, OcrTensor> e in outputs.entries)
          if (fetch.contains(e.key)) e.key: e.value,
      },
      kept: <String, OcrTensorHandle>{
        for (final MapEntry<String, OcrTensor> e in outputs.entries)
          if (!fetch.contains(e.key)) e.key: _CountedHandle(e.value, live),
      },
    );
  }

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      _inner.run(inputs);

  @override
  Future<void> close() => _inner.close();
}

class _CountedHandle implements OcrTensorHandle {
  _CountedHandle(this.tensor, this.live) {
    live.add(this);
  }

  final OcrTensor tensor;
  final Set<_CountedHandle> live;

  @override
  List<int> get shape => tensor.shape;

  @override
  Future<void> dispose() async {
    live.remove(this);
  }
}

void main() {
  final img.Image page = img.Image(width: 64, height: 64);
  const OcrRect box = OcrRect(left: 0, top: 0, right: 64, bottom: 64);
  final MangaOcrTokenizer tokenizer = MangaOcrTokenizer.fromVocabText(
    kVocabText,
  );

  test('KV 解码与经典 decoder 逐字一致（beam 真的发生重排）', () async {
    final String classic = await MangaOcrRecognizer(
      encoderSession: _FakeEncoder(),
      decoderSession: _FakeClassicDecoder(branchingModel),
      tokenizer: tokenizer,
    ).recognize(page, box);
    final _FakeKvDecoder kvDecoder = _FakeKvDecoder(branchingModel);
    final String kv = await MangaOcrKvRecognizer(
      encoderSession: _FakeEncoder(),
      crossSession: _FakeCross(),
      decoderSession: kvDecoder,
      tokenizer: tokenizer,
    ).recognize(page, box);
    expect(classic, isNotEmpty);
    expect(kv, classic);
    // 第二步起 beam_idx 必然全 0（都来自首步唯一那条）；之后至少有一步不是恒等
    // 排列，才算真的测到了图内重排。
    expect(
      kvDecoder.beamIdx
          .skip(2)
          .any((List<int> idx) => idx.join(',') != '0,1,2,3'),
      isTrue,
    );
  });

  test('首步只算一条 beam（beam_idx=[0]），之后 numBeams 条且逐步传来源', () async {
    final _FakeKvDecoder kvDecoder = _FakeKvDecoder(branchingModel);
    await MangaOcrKvRecognizer(
      encoderSession: _FakeEncoder(),
      crossSession: _FakeCross(),
      decoderSession: kvDecoder,
      tokenizer: tokenizer,
    ).recognize(page, box);
    expect(kvDecoder.inputIdShapes.first, <int>[1, 1]);
    expect(kvDecoder.beamIdx.first, <int>[0]);
    for (final List<int> shape in kvDecoder.inputIdShapes.skip(1)) {
      expect(shape, <int>[4, 1]);
    }
    // 第二步所有 beam 都来自首步唯一的那条。
    expect(kvDecoder.beamIdx[1], <int>[0, 0, 0, 0]);
  });

  test('句柄后端：每块结束后只剩复用的占位 past，close 后全部释放', () async {
    final Set<_CountedHandle> live = <_CountedHandle>{};
    final _CountingHandleSession decoder = _CountingHandleSession(
      _FakeKvDecoder(branchingModel),
      live,
    );
    final MangaOcrKvRecognizer recognizer = MangaOcrKvRecognizer(
      encoderSession: _CountingHandleSession(_FakeEncoder(), live),
      crossSession: _CountingHandleSession(_FakeCross(), live),
      decoderSession: decoder,
      tokenizer: tokenizer,
    );
    final String first = await recognizer.recognize(page, box);
    expect(live, hasLength(1), reason: 'only the reusable placeholder past');
    expect(await recognizer.recognize(page, box), first);
    expect(decoder.uploads, 1, reason: 'placeholder uploaded once per session');
    expect(live, hasLength(1));
    await recognizer.close();
    expect(live, isEmpty);
  });

  test('beam search 的来源下标：每条新序列 = 来源序列 + 一个 token', () async {
    List<List<int>>? previous;
    await beamSearchDecode(
      config: const BeamSearchConfig(startTokenId: 2, eosTokenId: 3),
      stepLogitsWithOrigin:
          (List<List<int>> sequences, List<int> sources) async {
            if (previous != null) {
              for (int i = 0; i < sequences.length; i++) {
                expect(
                  sequences[i].sublist(0, sequences[i].length - 1),
                  previous![sources[i]],
                );
              }
            } else {
              expect(sources, <int>[0, 0, 0, 0]);
            }
            previous = <List<int>>[
              for (final List<int> s in sequences) List<int>.of(s),
            ];
            return <Float32List>[
              for (final List<int> s in sequences)
                Float32List.fromList(branchingModel(s)),
            ];
          },
    );
    expect(previous, isNotNull);
  });
}
