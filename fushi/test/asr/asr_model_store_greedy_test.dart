import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';

void main() {
  late Directory tmp;
  late AsrModelStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_store_greedy_');
    store = AsrModelStore(tmp, kAsrJapanesePack);
    store
        .fileFor(AsrModelRole.decoderInt8)
        .writeAsBytesSync(List<int>.filled(10, 1));
    store
        .fileFor(AsrModelRole.joinerInt8)
        .writeAsBytesSync(List<int>.filled(20, 2));
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('首次生成落盘 + sidecar；源文件不变时第二次不重建', () async {
    int builds = 0;
    Uint8List build({
      required Uint8List decoderOnnx,
      required Uint8List joinerOnnx,
      required int blankId,
      required int unkId,
      int contextSize = 2,
    }) {
      builds++;
      expect(decoderOnnx, hasLength(10));
      expect(joinerOnnx, hasLength(20));
      expect(blankId, 0);
      expect(unkId, 5222);
      return Uint8List.fromList(<int>[9, 9, 9]);
    }

    final File graph = await store.ensureGreedyGraph(
      AsrEncoderVariant.int8,
      build: build,
      blankId: 0,
      unkId: 5222,
    );
    expect(graph.path, endsWith('greedy-int8.onnx'));
    expect(graph.readAsBytesSync(), <int>[9, 9, 9]);
    final Map<String, Object?> meta =
        jsonDecode(File('${graph.path}.meta.json').readAsStringSync())
            as Map<String, Object?>;
    expect(meta['decoderBytes'], 10);
    expect(meta['joinerBytes'], 20);
    expect(meta['version'], kAsrGreedyGraphFormatVersion);
    expect(builds, 1);

    await store.ensureGreedyGraph(
      AsrEncoderVariant.int8,
      build: build,
      blankId: 0,
      unkId: 5222,
    );
    expect(builds, 1, reason: '源文件与参数都没变，不该重建');
    // 没有 .part 残留。
    expect(File('${graph.path}.part').existsSync(), isFalse);
  });

  test('源文件字节数变了 / blank 变了 / sidecar 坏了 → 重建', () async {
    int builds = 0;
    Uint8List build({
      required Uint8List decoderOnnx,
      required Uint8List joinerOnnx,
      required int blankId,
      required int unkId,
      int contextSize = 2,
    }) {
      builds++;
      return Uint8List.fromList(<int>[builds]);
    }

    await store.ensureGreedyGraph(
      AsrEncoderVariant.int8,
      build: build,
      blankId: 0,
      unkId: 1,
    );
    store
        .fileFor(AsrModelRole.joinerInt8)
        .writeAsBytesSync(List<int>.filled(21, 2));
    await store.ensureGreedyGraph(
      AsrEncoderVariant.int8,
      build: build,
      blankId: 0,
      unkId: 1,
    );
    expect(builds, 2);
    await store.ensureGreedyGraph(
      AsrEncoderVariant.int8,
      build: build,
      blankId: 3,
      unkId: 1,
    );
    expect(builds, 3);
    File('${tmp.path}/greedy-int8.onnx.meta.json').writeAsStringSync('{bad');
    await store.ensureGreedyGraph(
      AsrEncoderVariant.int8,
      build: build,
      blankId: 3,
      unkId: 1,
    );
    expect(builds, 4);
  });

  test('拼装器抛 FormatException 原样透出，不留半个产物', () async {
    Uint8List build({
      required Uint8List decoderOnnx,
      required Uint8List joinerOnnx,
      required int blankId,
      required int unkId,
      int contextSize = 2,
    }) => throw const FormatException('decoder 缺 y 输入');

    await expectLater(
      store.ensureGreedyGraph(
        AsrEncoderVariant.int8,
        build: build,
        blankId: 0,
        unkId: 1,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(File('${tmp.path}/greedy-int8.onnx').existsSync(), isFalse);
    expect(
      File('${tmp.path}/greedy-int8.onnx.meta.json').existsSync(),
      isFalse,
    );
  });

  test('两个变体各自缓存', () async {
    store
        .fileFor(AsrModelRole.decoderFp32)
        .writeAsBytesSync(List<int>.filled(30, 1));
    store
        .fileFor(AsrModelRole.joinerFp32)
        .writeAsBytesSync(List<int>.filled(40, 2));
    Uint8List build({
      required Uint8List decoderOnnx,
      required Uint8List joinerOnnx,
      required int blankId,
      required int unkId,
      int contextSize = 2,
    }) => Uint8List.fromList(<int>[decoderOnnx.length]);

    final File a = await store.ensureGreedyGraph(
      AsrEncoderVariant.int8,
      build: build,
      blankId: 0,
      unkId: 1,
    );
    final File b = await store.ensureGreedyGraph(
      AsrEncoderVariant.fp32,
      build: build,
      blankId: 0,
      unkId: 1,
    );
    expect(a.path, isNot(b.path));
    expect(a.readAsBytesSync(), <int>[10]);
    expect(b.readAsBytesSync(), <int>[30]);
  });
}
