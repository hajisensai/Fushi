import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_greedy_graph.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_proto.dart';

/// `buildAsrGreedyGraph` 的结构测试：用 `fixtures/gen_greedy_fixtures.py` 生成的极小
/// 合成 decoder/joiner（IO 与真模型同构）拼图，断言 IO、Loop、前缀化内联与拒绝路径。
/// 数值等价由 `tool/asr/verify_greedy_graph.py` 用 onnxruntime 对真模型对拍。
void main() {
  final Uint8List decoder = File(
    'test/asr/fixtures/greedy_tiny_decoder.onnx',
  ).readAsBytesSync();
  final Uint8List joiner = File(
    'test/asr/fixtures/greedy_tiny_joiner.onnx',
  ).readAsBytesSync();

  Uint8List build({Uint8List? dec, Uint8List? joi, int contextSize = 2}) =>
      buildAsrGreedyGraph(
        decoderOnnx: dec ?? decoder,
        joinerOnnx: joi ?? joiner,
        blankId: 0,
        unkId: 5,
        contextSize: contextSize,
      );

  /// 把源模型的某个 IO 改名后重新编码（模拟 IO 名不符的模型）。
  Uint8List renameIo(Uint8List bytes, String from, String to) {
    final OnnxModel m = OnnxModel.decode(bytes);
    final OnnxGraph g = m.graph!;
    List<OnnxValueInfo> patch(List<OnnxValueInfo> vis) {
      for (final OnnxValueInfo v in vis) {
        if (v.name == from) v.name = to;
      }
      return vis;
    }

    g.inputs = patch(g.inputs);
    g.outputs = patch(g.outputs);
    final List<OnnxNode> nodes = g.nodes;
    for (final OnnxNode n in nodes) {
      n.inputs = n.inputs.map((String s) => s == from ? to : s).toList();
      n.outputs = n.outputs.map((String s) => s == from ? to : s).toList();
    }
    g.nodes = nodes;
    m.graph = g;
    return m.encode();
  }

  test('源 IO 常量与 AsrModelIo 一致（本文件不 import asr_types 才手抄）', () {
    expect(AsrGreedyGraphIo.sourceDecoderInput, AsrModelIo.decoderInputY);
    expect(AsrGreedyGraphIo.sourceDecoderOutput, AsrModelIo.decoderOutput);
    expect(
      AsrGreedyGraphIo.sourceJoinerEncoderInput,
      AsrModelIo.joinerInputEncoder,
    );
    expect(
      AsrGreedyGraphIo.sourceJoinerDecoderInput,
      AsrModelIo.joinerInputDecoder,
    );
    expect(AsrGreedyGraphIo.sourceJoinerOutput, AsrModelIo.joinerOutputLogit);
    expect(AsrGreedyGraphIo.encoderOut, AsrModelIo.encoderOutput);
    expect(AsrGreedyGraphIo.encoderOutLens, AsrModelIo.encoderOutputLens);
  });

  test('生成的字节可被 onnx_proto 重新解析：ir/opset/IO 名与形状正确', () {
    final OnnxModel m = OnnxModel.decode(build());
    expect(m.irVersion, 7);
    expect(m.producerName, 'fushi-asr-greedy-graph');
    expect(m.hasFunctions, isFalse);
    final OnnxOpsetId opset = m.opsetImports.single;
    expect(opset.domain, '');
    expect(opset.version, 13);

    final OnnxGraph g = m.graph!;
    expect(g.hasSparseInitializers, isFalse);
    expect(g.inputs.map((OnnxValueInfo v) => v.name), <String>[
      AsrGreedyGraphIo.encoderOut,
      AsrGreedyGraphIo.encoderOutLens,
    ]);
    expect(g.inputs[0].elemType, OnnxDataType.kFloat);
    // D 取自 joiner encoder_out 的静态维（夹具是 4）。
    expect(g.inputs[0].dims, <Object>['N', 'T', 4]);
    expect(g.inputs[1].elemType, OnnxDataType.kInt64);
    expect(g.inputs[1].dims, <Object>['N']);
    final OnnxValueInfo out = g.outputs.single;
    expect(out.name, AsrGreedyGraphIo.emitted);
    expect(out.elemType, OnnxDataType.kInt64);
    expect(out.dims, <Object>['N', 'T']);
  });

  test('Loop 节点存在，body 含前缀化的 decoder/joiner 节点与绑定后的 IO', () {
    final OnnxGraph g = OnnxModel.decode(build()).graph!;
    final OnnxNode loop = g.nodes.singleWhere(
      (OnnxNode n) => n.opType == 'Loop',
    );
    expect(loop.name, AsrGreedyGraphIo.loopNodeName);
    expect(loop.inputs.length, 5, reason: 'M, cond, ctx, dec, need_dec');
    expect(
      loop.outputs.length,
      4,
      reason: 'ctx_final, dec_final, need_dec_final, emitted[T,N]',
    );
    final OnnxAttribute bodyAttr = loop.attributes.single;
    expect(bodyAttr.name, 'body');
    expect(bodyAttr.type, OnnxAttributeType.kGraph);
    final OnnxGraph body = bodyAttr.g!;

    // body IO：iter/cond/ctx/dec/need_dec → cond/ctx/dec/need_dec/emit_t，
    // loop-carried 三个：ctx、dec（decoder_out 静态维 4）、need_dec。
    expect(body.inputs.length, 5);
    expect(body.inputs[0].elemType, OnnxDataType.kInt64);
    expect(body.inputs[1].elemType, OnnxDataType.kBool);
    expect(body.inputs[2].dims, <Object>['N', 2]);
    expect(body.inputs[3].elemType, OnnxDataType.kFloat);
    expect(body.inputs[3].dims, <Object>['N', 4]);
    expect(body.inputs[4].elemType, OnnxDataType.kBool);
    expect(body.outputs.length, 5);
    expect(body.outputs[1].dims, <Object>['N', 2]);
    expect(body.outputs[2].dims, <Object>['N', 4]);
    expect(body.outputs[3].elemType, OnnxDataType.kBool);
    expect(body.outputs[4].dims, <Object>['N']);

    final List<OnnxNode> nodes = body.nodes;
    // decoder 在 If 门控的 then 分支里，不直接出现在 body。
    expect(
      nodes.where(
        (OnnxNode n) => n.name.startsWith(AsrGreedyGraphIo.decoderPrefix),
      ),
      isEmpty,
    );
    final OnnxNode gate = nodes.singleWhere((OnnxNode n) => n.opType == 'If');
    expect(gate.name, AsrGreedyGraphIo.decoderGateNodeName);
    expect(gate.inputs, <String>['${AsrGreedyGraphIo.prefix}need_dec_in']);
    expect(gate.outputs, <String>['${AsrGreedyGraphIo.prefix}dec']);
    final Map<String, OnnxGraph> branches = <String, OnnxGraph>{
      for (final OnnxAttribute a in gate.attributes) a.name: a.g!,
    };
    expect(
      branches.keys,
      unorderedEquals(<String>['then_branch', 'else_branch']),
    );
    final List<OnnxNode> decNodes = branches['then_branch']!.nodes;
    expect(
      decNodes.every(
        (OnnxNode n) => n.name.startsWith(AsrGreedyGraphIo.decoderPrefix),
      ),
      isTrue,
    );
    expect(decNodes.map((OnnxNode n) => n.opType), <String>[
      'Gather',
      'Reshape',
      'Gemm',
    ]);
    // decoder 的 y 绑到 loop-carried ctx，decoder_out 前缀化并成为 then 分支输出。
    expect(decNodes.first.inputs, contains('${AsrGreedyGraphIo.prefix}ctx'));
    expect(decNodes.last.outputs, <String>[
      '${AsrGreedyGraphIo.decoderPrefix}decoder_out',
    ]);
    expect(
      branches['then_branch']!.outputs.single.name,
      '${AsrGreedyGraphIo.decoderPrefix}decoder_out',
    );
    expect(branches['then_branch']!.inputs, isEmpty);
    final OnnxNode keep = branches['else_branch']!.nodes.single;
    expect(keep.opType, 'Identity');
    expect(keep.inputs, <String>['${AsrGreedyGraphIo.prefix}dec_in']);

    final List<OnnxNode> joiNodes = nodes
        .where((OnnxNode n) => n.name.startsWith(AsrGreedyGraphIo.joinerPrefix))
        .toList();
    expect(joiNodes.map((OnnxNode n) => n.opType), <String>[
      'Add',
      'Tanh',
      'Gemm',
    ]);
    // joiner 吃当前帧 + If 选出的 dec；logit 前缀化并串到 ArgMax。
    expect(joiNodes.first.inputs, <String>[
      '${AsrGreedyGraphIo.prefix}enc_t',
      '${AsrGreedyGraphIo.prefix}dec',
    ]);
    expect(joiNodes.last.outputs, <String>[
      '${AsrGreedyGraphIo.joinerPrefix}logit',
    ]);
    final OnnxNode argmax = nodes.singleWhere(
      (OnnxNode n) => n.opType == 'ArgMax',
    );
    expect(argmax.inputs, <String>['${AsrGreedyGraphIo.joinerPrefix}logit']);
    // 其余算子齐全。
    final Set<String> ops = nodes.map((OnnxNode n) => n.opType).toSet();
    expect(
      ops,
      containsAll(<String>[
        'If', 'Gather', 'ArgMax', 'Equal', 'Or', 'Not', 'Less', 'And', //
        'Slice', 'Unsqueeze', 'Concat', 'Where', 'Cast', 'ReduceMax',
        'Identity',
      ]),
    );
    // body + 两个分支内每个节点输出名唯一，且全部带前缀。
    final List<String> outs = <String>[
      ...nodes.expand((OnnxNode n) => n.outputs),
      ...decNodes.expand((OnnxNode n) => n.outputs),
      ...keep.outputs,
    ];
    expect(outs.toSet().length, outs.length);
    expect(
      outs.every((String s) => s.startsWith(AsrGreedyGraphIo.prefix)),
      isTrue,
    );
  });

  test('两个子图的 initializer 前缀化后放主图，并保留原始 raw_data', () {
    final OnnxGraph g = OnnxModel.decode(build()).graph!;
    final Map<String, OnnxTensorProto> inits = <String, OnnxTensorProto>{
      for (final OnnxTensorProto t in g.initializers) t.name: t,
    };
    final OnnxTensorProto srcEmb = OnnxModel.decode(decoder).graph!.initializers
        .singleWhere(
          (OnnxTensorProto t) => t.name == 'decoder.embedding.weight',
        );
    final OnnxTensorProto emb =
        inits['${AsrGreedyGraphIo.decoderPrefix}decoder.embedding.weight']!;
    expect(emb.dims, srcEmb.dims);
    expect(emb.rawData, srcEmb.rawData);
    expect(
      inits.containsKey('${AsrGreedyGraphIo.joinerPrefix}output_linear.bias'),
      isTrue,
    );
    // 常量：blank/unk/-1、slice 索引、cond=true。
    expect(inits['${AsrGreedyGraphIo.prefix}blank']!.readInt64Values(), <int>[
      0,
    ]);
    expect(inits['${AsrGreedyGraphIo.prefix}unk']!.readInt64Values(), <int>[5]);
    expect(inits['${AsrGreedyGraphIo.prefix}no_emit']!.readInt64Values(), <int>[
      AsrGreedyGraphIo.noEmit,
    ]);
    expect(
      inits['${AsrGreedyGraphIo.prefix}true']!.dataType,
      OnnxDataType.kBool,
    );
    expect(inits['${AsrGreedyGraphIo.prefix}dec_dim']!.readInt64Values(), <int>[
      4,
    ]);
    // 名字全局唯一。
    expect(inits.length, g.initializers.length);
  });

  test('源模型 IO 名不符抛 FormatException（不静默产出错图）', () {
    expect(
      () => build(joi: renameIo(joiner, 'logit', 'logits')),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('输出应为'),
        ),
      ),
    );
    expect(
      () => build(dec: renameIo(decoder, 'y', 'tokens')),
      throwsFormatException,
    );
    // 把 decoder 当 joiner 喂。
    expect(() => build(joi: decoder), throwsFormatException);
    // 不是 protobuf。
    expect(
      () => build(dec: Uint8List.fromList(<int>[0x80, 0x80, 0x80])),
      throwsFormatException,
    );
  });

  test('context_size 与 decoder y 的静态维不符抛 FormatException', () {
    expect(
      () => build(contextSize: 3),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('第 1 维应为 3'),
        ),
      ),
    );
    expect(() => build(contextSize: 0), throwsArgumentError);
  });

  test('decoder y 是 int32 时：then 分支先 Cast 再喂 decoder，主图 IO 仍是 int64', () {
    // X-ASR 中文导出把 y 导成 int32（asr_model_manifest.dart 文件头表格）。
    final OnnxModel m = OnnxModel.decode(decoder);
    final OnnxGraph g = m.graph!;
    g.inputs = <OnnxValueInfo>[
      OnnxValueInfo.tensor('y', OnnxDataType.kInt32, <Object>['N', 2]),
    ];
    m.graph = g;
    final OnnxGraph out = OnnxModel.decode(build(dec: m.encode())).graph!;
    // 主图契约不变：encoder_out_lens int64 进、emitted int64 出。
    expect(out.inputs[1].elemType, OnnxDataType.kInt64);
    expect(out.outputs.single.elemType, OnnxDataType.kInt64);
    final OnnxGraph body = out.nodes
        .singleWhere((OnnxNode n) => n.opType == 'Loop')
        .attributes
        .single
        .g!;
    // loop-carried ctx 仍是 int64。
    expect(body.inputs[2].elemType, OnnxDataType.kInt64);
    final OnnxNode gate = body.nodes.singleWhere(
      (OnnxNode n) => n.opType == 'If',
    );
    final OnnxGraph thenBranch = gate.attributes
        .singleWhere((OnnxAttribute a) => a.name == 'then_branch')
        .g!;
    final OnnxNode cast = thenBranch.nodes.first;
    expect(cast.opType, 'Cast');
    expect(cast.inputs, <String>['${AsrGreedyGraphIo.prefix}ctx']);
    expect(
      cast.attributes.single.i,
      OnnxDataType.kInt32,
      reason: 'Cast to=int32',
    );
    // decoder 的 Gather 读的是 Cast 之后的张量，而不是 int64 的 ctx。
    final OnnxNode gather = thenBranch.nodes.singleWhere(
      (OnnxNode n) => n.opType == 'Gather',
    );
    expect(gather.inputs, contains(cast.outputs.single));
    expect(gather.inputs, isNot(contains('${AsrGreedyGraphIo.prefix}ctx')));
    // int64 源模型不插 Cast。
    final OnnxGraph plainThen = OnnxModel.decode(build())
        .graph!
        .nodes
        .singleWhere((OnnxNode n) => n.opType == 'Loop')
        .attributes
        .single
        .g!
        .nodes
        .singleWhere((OnnxNode n) => n.opType == 'If')
        .attributes
        .singleWhere((OnnxAttribute a) => a.name == 'then_branch')
        .g!;
    expect(plainThen.nodes.where((OnnxNode n) => n.opType == 'Cast'), isEmpty);
  });

  test('decoder y 是 float 等其它类型时抛 FormatException', () {
    final OnnxModel m = OnnxModel.decode(decoder);
    final OnnxGraph g = m.graph!;
    g.inputs = <OnnxValueInfo>[
      OnnxValueInfo.tensor('y', OnnxDataType.kFloat, <Object>['N', 2]),
    ];
    m.graph = g;
    expect(() => build(dec: m.encode()), throwsFormatException);
  });

  test('decoder_out 第二维是符号维时抛 FormatException', () {
    final OnnxModel m = OnnxModel.decode(decoder);
    final OnnxGraph g = m.graph!;
    g.outputs = <OnnxValueInfo>[
      OnnxValueInfo.tensor('decoder_out', OnnxDataType.kFloat, <Object>[
        'N',
        'D',
      ]),
    ];
    m.graph = g;
    expect(
      () => build(dec: m.encode()),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('静态值'),
        ),
      ),
    );
  });

  test('缺默认域 opset / 两模型 opset 不一致抛 FormatException', () {
    final OnnxModel m = OnnxModel.decode(joiner);
    m.opsetImports = <OnnxOpsetId>[OnnxOpsetId.create('', 12)];
    expect(
      () => build(joi: m.encode()),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('不一致'),
        ),
      ),
    );
    m.opsetImports = <OnnxOpsetId>[OnnxOpsetId.create('com.microsoft', 1)];
    expect(
      () => build(joi: m.encode()),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('缺默认域'),
        ),
      ),
    );
  });

  test('含 functions 的模型拒绝内联', () {
    final OnnxModel m = OnnxModel.decode(decoder);
    // ModelProto.functions = 25：塞一个空 FunctionProto 即算存在。
    m.message.fields.add(ProtoBytesField(25, Uint8List(0)));
    expect(
      () => build(dec: m.encode()),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('functions'),
        ),
      ),
    );
  });
}
