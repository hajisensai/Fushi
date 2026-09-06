/// 由 RNN-T decoder / joiner 两个 ONNX 文件在设备上拼出「整段逐帧贪心解码」一张图。
///
/// 动机：`AsrTransducerDecoder` 在 Dart 里逐帧调 joiner，一帧一次 ORT 往返；整本
/// 7 小时有声书 66 万帧，往返本身就是 ASR 阶段的耗时大头。把 decoder + joiner +
/// argmax + 上下文更新编进一个 `Loop` 算子，一个批次只调 ORT 一次。图不托管、不
/// 下载：由已下载的 decoder/joiner 字节运行时生成（纯 Dart protobuf，见
/// `onnx_proto.dart`）。
///
/// 语义与 [AsrTransducerDecoder] 的逐帧贪心**逐字等价**（每帧最多一个符号）：
///
/// ```text
/// ctx[n] = [blank] * contextSize;  need_dec = true
/// for t in 0..T-1:
///   if need_dec: dec = decoder(ctx)           # [N, D]（否则沿用上一帧的 dec）
///   logit = joiner(encoder_out[:, t, :], dec) # [N, V]
///   y     = argmax(logit, axis=1)             # [N]
///   emit  = y != blank && y != unk && t < encoder_out_lens
///   ctx   = emit ? concat(ctx[:, 1:], y) : ctx
///   need_dec = any(emit)
///   emitted[:, t] = emit ? y : -1
/// ```
///
/// 图结构：
/// - 主图输入 `encoder_out[N,T,D] f32`、`encoder_out_lens[N] i64`；输出
///   `emitted[N,T] i64`（-1 = 该帧不发射）。
/// - 主图：`Shape/Slice/Squeeze` 取 `T` 与 `N`，`ConstantOfShape` 造全 blank 的
///   `ctx[N,ctx]` 与全零占位 `dec[N,D]`，`Loop(M=T, cond=true, ctx, dec, need_dec)`，
///   scan 输出 `[T,N]` 经 `Transpose` 得 `[N,T]`。loop-carried 三个：`ctx`、`dec`、
///   `need_dec`。
/// - body：`If(need_dec)` 的 then 分支内联 decoder（由 `ctx` 重算 `dec`），else 分支
///   原样传递上一帧的 `dec`；`Gather(encoder_out, iter, axis=1)` 取当前帧；joiner
///   全部节点内联；再接 `ArgMax / Equal / Or / Not / Less / And / Slice / Unsqueeze /
///   Concat / Where`，`Cast→ReduceMax→Cast` 得 `any(emit)` 作下一帧的 `need_dec`。
///   decoder / joiner 的 initializer 都放主图（子图可引用外层作用域），张量与节点名
///   一律加前缀避免冲突。
///
/// 为什么不每帧重算 decoder：ORT profiling（int8，N=8，T=250）里 decoder 的 Conv +
/// 量化 MatMul 占 body 内核时间 ~35%，而语音里只有 ~15% 的帧发射；两次发射之间
/// `ctx` 不变、`decoder(ctx)` 也就不变，`If` 门控与逐帧重算**逐值相同**（int8 的
/// DynamicQuantizeLinear 也是——同一批 ctx 行给同一结果）。
///
/// 任何结构不符——IO 名/数量/类型/秩不对、`decoder_out` 第二维不是静态值、缺默认域
/// opset 或版本 < 13、两模型 opset 不一致、含 `functions` / `sparse_initializer`、节点
/// 引用未定义张量——都抛 [FormatException]，绝不静默产出错图。
library;

import 'dart:typed_data';

import 'package:fushi/src/onnx/onnx_proto.dart';

/// 生成图的对外 IO 名。
abstract final class AsrGreedyGraphIo {
  /// 输入 `[N, T, D]` float32（encoder 输出，pad 帧任意值）。
  static const String encoderOut = 'encoder_out';

  /// 输入 `[N]` int64，每行有效帧数；`t >= lens[n]` 的帧不发射、不更新上下文。
  static const String encoderOutLens = 'encoder_out_lens';

  /// 输出 `[N, T]` int64：发射的 token id，未发射为 [noEmit]。
  static const String emitted = 'emitted';

  /// [emitted] 中「本帧无符号」的占位值。
  static const int noEmit = -1;

  /// 源 decoder / joiner 模型必须具备的 IO 名（镜像 `AsrModelIo`；本文件不 import
  /// `asr_types.dart` 以保持纯 Dart、可被 `dart run` 工具直接调用）。
  static const String sourceDecoderInput = 'y';
  static const String sourceDecoderOutput = 'decoder_out';
  static const String sourceJoinerEncoderInput = 'encoder_out';
  static const String sourceJoinerDecoderInput = 'decoder_out';
  static const String sourceJoinerOutput = 'logit';

  /// 生成图内部所有新增节点/张量名的前缀，以及两个内联子图的前缀。
  static const String prefix = 'fg_';
  static const String decoderPrefix = 'fg_dec/';
  static const String joinerPrefix = 'fg_join/';

  /// Loop 节点名与 body 内 decoder 门控 If 节点名（测试与调试用）。
  static const String loopNodeName = 'fg_loop';
  static const String decoderGateNodeName = 'fg_dec_gate';

  /// 生成图要求的最低默认域 opset（Squeeze/Unsqueeze axes 作输入、Loop 等）。
  static const int minOpset = 13;
}

/// 由 decoder/joiner 的 ONNX 字节拼出贪心解码图，返回可直接喂 ORT 的 ModelProto 字节。
///
/// [blankId] / [unkId] 来自 `tokens.txt`；[contextSize] 必须与 decoder 的 `y`
/// 第二维一致（静态维不符抛 [FormatException]）。
Uint8List buildAsrGreedyGraph({
  required Uint8List decoderOnnx,
  required Uint8List joinerOnnx,
  required int blankId,
  required int unkId,
  int contextSize = 2,
}) {
  if (contextSize < 1) {
    throw ArgumentError.value(contextSize, 'contextSize', '至少 1');
  }
  if (blankId < 0 || unkId < 0) {
    throw ArgumentError('blankId/unkId 必须非负：$blankId / $unkId');
  }

  final _SourceModel decoder = _SourceModel.parse(decoderOnnx, '解码器（decoder）');
  final _SourceModel joiner = _SourceModel.parse(joinerOnnx, '联结器（joiner）');
  decoder.requireIo(
    inputs: <String>[AsrGreedyGraphIo.sourceDecoderInput],
    outputs: <String>[AsrGreedyGraphIo.sourceDecoderOutput],
  );
  joiner.requireIo(
    inputs: <String>[
      AsrGreedyGraphIo.sourceJoinerEncoderInput,
      AsrGreedyGraphIo.sourceJoinerDecoderInput,
    ],
    outputs: <String>[AsrGreedyGraphIo.sourceJoinerOutput],
  );
  decoder.requireTensorIo(
    AsrGreedyGraphIo.sourceDecoderInput,
    elemType: OnnxDataType.kInt64,
    rank: 2,
    staticDims: <int, int>{1: contextSize},
  );
  decoder.requireTensorIo(
    AsrGreedyGraphIo.sourceDecoderOutput,
    elemType: OnnxDataType.kFloat,
    rank: 2,
  );
  joiner.requireTensorIo(
    AsrGreedyGraphIo.sourceJoinerEncoderInput,
    elemType: OnnxDataType.kFloat,
    rank: 2,
  );
  joiner.requireTensorIo(
    AsrGreedyGraphIo.sourceJoinerDecoderInput,
    elemType: OnnxDataType.kFloat,
    rank: 2,
  );
  joiner.requireTensorIo(
    AsrGreedyGraphIo.sourceJoinerOutput,
    elemType: OnnxDataType.kFloat,
    rank: 2,
  );

  final int? decoderDim = decoder.staticDim(
    AsrGreedyGraphIo.sourceDecoderOutput,
    1,
  );
  if (decoderDim == null) {
    throw FormatException(
      '${decoder.label} "${AsrGreedyGraphIo.sourceDecoderOutput}" 第 1 维必须是静态值'
      '（loop-carried dec_out 的占位形状需要它）',
    );
  }

  final int opset = _mergeDefaultOpset(decoder, joiner);
  final List<OnnxOpsetId> opsetImports = _mergeOpsetImports(
    decoder,
    joiner,
    opset,
  );
  final int irVersion = _max(decoder.irVersion, joiner.irVersion);

  const String p = AsrGreedyGraphIo.prefix;

  // ---- 主图常量（initializer；ir>=4 不必列入 input）。
  final List<OnnxTensorProto> initializers = <OnnxTensorProto>[
    OnnxTensorProto.int64('${p}blank', <int>[], <int>[blankId]),
    OnnxTensorProto.int64('${p}unk', <int>[], <int>[unkId]),
    OnnxTensorProto.int64('${p}no_emit', <int>[], <int>[
      AsrGreedyGraphIo.noEmit,
    ]),
    OnnxTensorProto.int64('${p}i0', <int>[1], <int>[0]),
    OnnxTensorProto.int64('${p}i1', <int>[1], <int>[1]),
    OnnxTensorProto.int64('${p}i2', <int>[1], <int>[2]),
    OnnxTensorProto.int64('${p}ctx_size', <int>[1], <int>[contextSize]),
    OnnxTensorProto.int64('${p}dec_dim', <int>[1], <int>[decoderDim]),
    OnnxTensorProto.bool('${p}true', <int>[], <bool>[true]),
  ];

  // ---- 内联两个子图：改名 + 绑定 IO。
  const String bodyCtx = '${p}ctx';
  const String bodyDecIn = '${p}dec_in';
  const String bodyNeedDecIn = '${p}need_dec_in';
  const String bodyEncFrame = '${p}enc_t';
  const String decOut = '${AsrGreedyGraphIo.decoderPrefix}decoder_out';
  const String decKeep = '${p}dec_keep';
  const String dec = '${p}dec';
  const String logit = '${AsrGreedyGraphIo.joinerPrefix}logit';

  final _InlinedGraph decoderInlined = _inline(
    decoder,
    prefix: AsrGreedyGraphIo.decoderPrefix,
    bindings: <String, String>{
      AsrGreedyGraphIo.sourceDecoderInput: bodyCtx,
      AsrGreedyGraphIo.sourceDecoderOutput: decOut,
    },
  );
  final _InlinedGraph joinerInlined = _inline(
    joiner,
    prefix: AsrGreedyGraphIo.joinerPrefix,
    bindings: <String, String>{
      AsrGreedyGraphIo.sourceJoinerEncoderInput: bodyEncFrame,
      AsrGreedyGraphIo.sourceJoinerDecoderInput: dec,
      AsrGreedyGraphIo.sourceJoinerOutput: logit,
    },
  );
  initializers
    ..addAll(decoderInlined.initializers)
    ..addAll(joinerInlined.initializers);
  _requireUniqueNames(initializers.map((OnnxTensorProto t) => t.name));

  // ---- decoder 门控：need_dec ? decoder(ctx) : dec_in。两个分支都没有输入，
  //      直接引用外层作用域（body 的 ctx / dec_in 与主图 initializer）。
  final List<Object> decShape = <Object>['N', decoderDim];
  final OnnxGraph thenBranch = OnnxGraph.create(
    name: '${p}dec_recompute',
    nodes: decoderInlined.nodes,
    inputs: const <OnnxValueInfo>[],
    outputs: <OnnxValueInfo>[
      OnnxValueInfo.tensor(decOut, OnnxDataType.kFloat, decShape),
    ],
  );
  final OnnxGraph elseBranch = OnnxGraph.create(
    name: '${p}dec_reuse',
    nodes: <OnnxNode>[
      OnnxNode.create(
        opType: 'Identity',
        name: '${p}dec_keep_id',
        inputs: <String>[bodyDecIn],
        outputs: <String>[decKeep],
      ),
    ],
    inputs: const <OnnxValueInfo>[],
    outputs: <OnnxValueInfo>[
      OnnxValueInfo.tensor(decKeep, OnnxDataType.kFloat, decShape),
    ],
  );

  // ---- Loop body。
  const String iter = '${p}iter';
  const String condIn = '${p}cond_in';
  const String condOut = '${p}cond_out';
  const String ctxOut = '${p}ctx_out';
  const String needDecOut = '${p}need_dec_out';
  const String emitT = '${p}emit_t';

  final List<OnnxNode> body = <OnnxNode>[
    OnnxNode.create(
      opType: 'If',
      name: AsrGreedyGraphIo.decoderGateNodeName,
      inputs: <String>[bodyNeedDecIn],
      outputs: <String>[dec],
      attributes: <OnnxAttribute>[
        OnnxAttribute.graph('then_branch', thenBranch),
        OnnxAttribute.graph('else_branch', elseBranch),
      ],
    ),
    OnnxNode.create(
      opType: 'Gather',
      name: '${p}gather_frame',
      inputs: <String>[AsrGreedyGraphIo.encoderOut, iter],
      outputs: <String>[bodyEncFrame],
      attributes: <OnnxAttribute>[OnnxAttribute.int('axis', 1)],
    ),
    ...joinerInlined.nodes,
    OnnxNode.create(
      opType: 'ArgMax',
      name: '${p}argmax',
      inputs: <String>[logit],
      outputs: <String>['${p}y'],
      attributes: <OnnxAttribute>[
        OnnxAttribute.int('axis', 1),
        OnnxAttribute.int('keepdims', 0),
      ],
    ),
    OnnxNode.create(
      opType: 'Equal',
      name: '${p}is_blank',
      inputs: <String>['${p}y', '${p}blank'],
      outputs: <String>['${p}is_blank_out'],
    ),
    OnnxNode.create(
      opType: 'Equal',
      name: '${p}is_unk',
      inputs: <String>['${p}y', '${p}unk'],
      outputs: <String>['${p}is_unk_out'],
    ),
    OnnxNode.create(
      opType: 'Or',
      name: '${p}is_silent',
      inputs: <String>['${p}is_blank_out', '${p}is_unk_out'],
      outputs: <String>['${p}is_silent_out'],
    ),
    OnnxNode.create(
      opType: 'Not',
      name: '${p}is_symbol',
      inputs: <String>['${p}is_silent_out'],
      outputs: <String>['${p}is_symbol_out'],
    ),
    OnnxNode.create(
      opType: 'Less',
      name: '${p}in_range',
      inputs: <String>[iter, AsrGreedyGraphIo.encoderOutLens],
      outputs: <String>['${p}in_range_out'],
    ),
    OnnxNode.create(
      opType: 'And',
      name: '${p}emit',
      inputs: <String>['${p}is_symbol_out', '${p}in_range_out'],
      outputs: <String>['${p}emit_out'],
    ),
    OnnxNode.create(
      opType: 'Slice',
      name: '${p}ctx_tail',
      inputs: <String>[bodyCtx, '${p}i1', '${p}ctx_size', '${p}i1'],
      outputs: <String>['${p}ctx_tail_out'],
    ),
    OnnxNode.create(
      opType: 'Unsqueeze',
      name: '${p}y_col',
      inputs: <String>['${p}y', '${p}i1'],
      outputs: <String>['${p}y_col_out'],
    ),
    OnnxNode.create(
      opType: 'Concat',
      name: '${p}ctx_shifted',
      inputs: <String>['${p}ctx_tail_out', '${p}y_col_out'],
      outputs: <String>['${p}ctx_shifted_out'],
      attributes: <OnnxAttribute>[OnnxAttribute.int('axis', 1)],
    ),
    OnnxNode.create(
      opType: 'Unsqueeze',
      name: '${p}emit_col',
      inputs: <String>['${p}emit_out', '${p}i1'],
      outputs: <String>['${p}emit_col_out'],
    ),
    OnnxNode.create(
      opType: 'Where',
      name: '${p}ctx_select',
      inputs: <String>['${p}emit_col_out', '${p}ctx_shifted_out', bodyCtx],
      outputs: <String>[ctxOut],
    ),
    OnnxNode.create(
      opType: 'Where',
      name: '${p}emit_select',
      inputs: <String>['${p}emit_out', '${p}y', '${p}no_emit'],
      outputs: <String>[emitT],
    ),
    // any(emit)：bool 不能直接 ReduceMax，绕 int32。
    OnnxNode.create(
      opType: 'Cast',
      name: '${p}emit_i32',
      inputs: <String>['${p}emit_out'],
      outputs: <String>['${p}emit_i32_out'],
      attributes: <OnnxAttribute>[OnnxAttribute.int('to', OnnxDataType.kInt32)],
    ),
    OnnxNode.create(
      opType: 'ReduceMax',
      name: '${p}any_emit',
      inputs: <String>['${p}emit_i32_out'],
      outputs: <String>['${p}any_emit_out'],
      attributes: <OnnxAttribute>[OnnxAttribute.int('keepdims', 0)],
    ),
    OnnxNode.create(
      opType: 'Cast',
      name: '${p}need_dec_next',
      inputs: <String>['${p}any_emit_out'],
      outputs: <String>[needDecOut],
      attributes: <OnnxAttribute>[OnnxAttribute.int('to', OnnxDataType.kBool)],
    ),
    OnnxNode.create(
      opType: 'Identity',
      name: '${p}cond_pass',
      inputs: <String>[condIn],
      outputs: <String>[condOut],
    ),
  ];
  _requireUniqueNames(<String>[
    ...body.expand((OnnxNode n) => n.outputs),
    ...thenBranch.nodes.expand((OnnxNode n) => n.outputs),
    ...elseBranch.nodes.expand((OnnxNode n) => n.outputs),
  ]);

  final OnnxGraph bodyGraph = OnnxGraph.create(
    name: '${p}body',
    nodes: body,
    inputs: <OnnxValueInfo>[
      OnnxValueInfo.tensor(iter, OnnxDataType.kInt64, const <Object>[]),
      OnnxValueInfo.tensor(condIn, OnnxDataType.kBool, const <Object>[]),
      OnnxValueInfo.tensor(bodyCtx, OnnxDataType.kInt64, <Object>[
        'N',
        contextSize,
      ]),
      OnnxValueInfo.tensor(bodyDecIn, OnnxDataType.kFloat, decShape),
      OnnxValueInfo.tensor(bodyNeedDecIn, OnnxDataType.kBool, const <Object>[]),
    ],
    outputs: <OnnxValueInfo>[
      OnnxValueInfo.tensor(condOut, OnnxDataType.kBool, const <Object>[]),
      OnnxValueInfo.tensor(ctxOut, OnnxDataType.kInt64, <Object>[
        'N',
        contextSize,
      ]),
      OnnxValueInfo.tensor(dec, OnnxDataType.kFloat, decShape),
      OnnxValueInfo.tensor(needDecOut, OnnxDataType.kBool, const <Object>[]),
      OnnxValueInfo.tensor(emitT, OnnxDataType.kInt64, const <Object>['N']),
    ],
  );

  // ---- 主图。
  final List<OnnxNode> main = <OnnxNode>[
    OnnxNode.create(
      opType: 'Shape',
      name: '${p}shape',
      inputs: <String>[AsrGreedyGraphIo.encoderOut],
      outputs: <String>['${p}shape_out'],
    ),
    OnnxNode.create(
      opType: 'Slice',
      name: '${p}n_dim',
      inputs: <String>['${p}shape_out', '${p}i0', '${p}i1'],
      outputs: <String>['${p}n_dim_out'],
    ),
    OnnxNode.create(
      opType: 'Slice',
      name: '${p}t_dim',
      inputs: <String>['${p}shape_out', '${p}i1', '${p}i2'],
      outputs: <String>['${p}t_dim_out'],
    ),
    OnnxNode.create(
      opType: 'Squeeze',
      name: '${p}trip_count',
      inputs: <String>['${p}t_dim_out'],
      outputs: <String>['${p}trip_count_out'],
    ),
    OnnxNode.create(
      opType: 'Concat',
      name: '${p}ctx_shape',
      inputs: <String>['${p}n_dim_out', '${p}ctx_size'],
      outputs: <String>['${p}ctx_shape_out'],
      attributes: <OnnxAttribute>[OnnxAttribute.int('axis', 0)],
    ),
    OnnxNode.create(
      opType: 'ConstantOfShape',
      name: '${p}ctx_init',
      inputs: <String>['${p}ctx_shape_out'],
      outputs: <String>['${p}ctx_init_out'],
      attributes: <OnnxAttribute>[
        OnnxAttribute.tensor(
          'value',
          OnnxTensorProto.int64('${p}ctx_fill', <int>[1], <int>[blankId]),
        ),
      ],
    ),
    OnnxNode.create(
      opType: 'Concat',
      name: '${p}dec_shape',
      inputs: <String>['${p}n_dim_out', '${p}dec_dim'],
      outputs: <String>['${p}dec_shape_out'],
      attributes: <OnnxAttribute>[OnnxAttribute.int('axis', 0)],
    ),
    // 全零 float 占位（ConstantOfShape 默认 value 即 float32 0）；第 0 帧 need_dec
    // 恒为 true，占位值不会参与任何计算。
    OnnxNode.create(
      opType: 'ConstantOfShape',
      name: '${p}dec_init',
      inputs: <String>['${p}dec_shape_out'],
      outputs: <String>['${p}dec_init_out'],
    ),
    OnnxNode.create(
      opType: 'Loop',
      name: AsrGreedyGraphIo.loopNodeName,
      inputs: <String>[
        '${p}trip_count_out',
        '${p}true',
        '${p}ctx_init_out',
        '${p}dec_init_out',
        '${p}true',
      ],
      outputs: <String>[
        '${p}ctx_final',
        '${p}dec_final',
        '${p}need_dec_final',
        '${p}emitted_tn',
      ],
      attributes: <OnnxAttribute>[OnnxAttribute.graph('body', bodyGraph)],
    ),
    OnnxNode.create(
      opType: 'Transpose',
      name: '${p}emitted_nt',
      inputs: <String>['${p}emitted_tn'],
      outputs: <String>[AsrGreedyGraphIo.emitted],
      attributes: <OnnxAttribute>[
        OnnxAttribute.ints('perm', <int>[1, 0]),
      ],
    ),
  ];

  final OnnxGraph mainGraph = OnnxGraph.create(
    name: '${p}greedy_search',
    nodes: main,
    initializers: initializers,
    inputs: <OnnxValueInfo>[
      OnnxValueInfo.tensor(
        AsrGreedyGraphIo.encoderOut,
        OnnxDataType.kFloat,
        <Object>[
          'N',
          'T',
          joiner.staticDim(AsrGreedyGraphIo.sourceJoinerEncoderInput, 1) ?? 'D',
        ],
      ),
      OnnxValueInfo.tensor(
        AsrGreedyGraphIo.encoderOutLens,
        OnnxDataType.kInt64,
        const <Object>['N'],
      ),
    ],
    outputs: <OnnxValueInfo>[
      OnnxValueInfo.tensor(
        AsrGreedyGraphIo.emitted,
        OnnxDataType.kInt64,
        const <Object>['N', 'T'],
      ),
    ],
  );

  final OnnxModel model = OnnxModel.create(
    irVersion: irVersion,
    producerName: 'fushi-asr-greedy-graph',
    opsetImports: opsetImports,
    graph: mainGraph,
  );
  return model.encode();
}

// ---------------------------------------------------------------------------
// 源模型解析与校验
// ---------------------------------------------------------------------------

class _SourceModel {
  _SourceModel._(this.label, this.model, this.graph, this.inputs, this.outputs);

  factory _SourceModel.parse(Uint8List bytes, String label) {
    final OnnxModel model;
    try {
      model = OnnxModel.decode(bytes);
    } on FormatException catch (e) {
      throw FormatException('$label 不是合法的 ONNX protobuf：${e.message}');
    }
    final int? ir = model.irVersion;
    if (ir == null || ir < 4) {
      throw FormatException(
        '$label ir_version=$ir，需要 >= 4（initializer 不列入 input）',
      );
    }
    if (model.hasFunctions) {
      throw FormatException('$label 含 functions（局部函数），内联不支持');
    }
    final OnnxGraph? graph = model.graph;
    if (graph == null) {
      throw FormatException('$label 缺 graph');
    }
    _rejectSparse(graph, label);
    final Set<String> initNames = graph.initializers
        .map((OnnxTensorProto t) => t.name)
        .toSet();
    // ir<4 风格「input 里也列 initializer」按 initializer 处理，不算真输入。
    final List<OnnxValueInfo> inputs = graph.inputs
        .where((OnnxValueInfo v) => !initNames.contains(v.name))
        .toList();
    return _SourceModel._(label, model, graph, inputs, graph.outputs);
  }

  final String label;
  final OnnxModel model;
  final OnnxGraph graph;
  final List<OnnxValueInfo> inputs;
  final List<OnnxValueInfo> outputs;

  int get irVersion => model.irVersion!;

  int? get defaultOpset {
    for (final OnnxOpsetId o in model.opsetImports) {
      if (o.domain.isEmpty || o.domain == 'ai.onnx') return o.version;
    }
    return null;
  }

  void requireIo({
    required List<String> inputs,
    required List<String> outputs,
  }) {
    final List<String> inNames = this.inputs
        .map((OnnxValueInfo v) => v.name)
        .toList();
    final List<String> outNames = this.outputs
        .map((OnnxValueInfo v) => v.name)
        .toList();
    if (!_sameSet(inNames, inputs)) {
      throw FormatException('$label 输入应为 $inputs，实际 $inNames');
    }
    if (!_sameSet(outNames, outputs)) {
      throw FormatException('$label 输出应为 $outputs，实际 $outNames');
    }
  }

  OnnxValueInfo _io(String name) {
    for (final OnnxValueInfo v in inputs) {
      if (v.name == name) return v;
    }
    for (final OnnxValueInfo v in outputs) {
      if (v.name == name) return v;
    }
    throw FormatException('$label 没有 IO "$name"');
  }

  void requireTensorIo(
    String name, {
    required int elemType,
    required int rank,
    Map<int, int> staticDims = const <int, int>{},
  }) {
    final OnnxValueInfo v = _io(name);
    final int? actualType = v.elemType;
    if (actualType != elemType) {
      throw FormatException('$label "$name" 元素类型应为 $elemType，实际 $actualType');
    }
    final List<Object>? dims = v.dims;
    if (dims == null || dims.length != rank) {
      throw FormatException('$label "$name" 秩应为 $rank，实际形状 $dims');
    }
    for (final MapEntry<int, int> e in staticDims.entries) {
      final Object d = dims[e.key];
      if (d is int && d != e.value) {
        throw FormatException('$label "$name" 第 ${e.key} 维应为 ${e.value}，实际 $d');
      }
    }
  }

  /// IO 某一维的静态值；符号维返回 null。
  int? staticDim(String name, int axis) {
    final Object? d = _io(name).dims?[axis];
    return d is int ? d : null;
  }

  static void _rejectSparse(OnnxGraph graph, String label) {
    if (graph.hasSparseInitializers) {
      throw FormatException('$label 含 sparse_initializer，内联不支持');
    }
    for (final OnnxNode n in graph.nodes) {
      for (final OnnxAttribute a in n.attributes) {
        final OnnxGraph? g = a.type == OnnxAttributeType.kGraph ? a.g : null;
        if (g != null) _rejectSparse(g, label);
        if (a.type == OnnxAttributeType.kGraphs) {
          for (final OnnxGraph sub in a.graphs) {
            _rejectSparse(sub, label);
          }
        }
      }
    }
  }
}

int _mergeDefaultOpset(_SourceModel a, _SourceModel b) {
  final int? va = a.defaultOpset;
  final int? vb = b.defaultOpset;
  if (va == null) throw FormatException('${a.label} 缺默认域 opset_import');
  if (vb == null) throw FormatException('${b.label} 缺默认域 opset_import');
  if (va != vb) {
    throw FormatException('${a.label} opset $va 与 ${b.label} opset $vb 不一致');
  }
  if (va < AsrGreedyGraphIo.minOpset) {
    throw FormatException('默认域 opset $va 低于生成图所需 ${AsrGreedyGraphIo.minOpset}');
  }
  return va;
}

/// 默认域取 [defaultOpset]；其余域（如 `com.microsoft`）合并去重，同域异版抛错。
List<OnnxOpsetId> _mergeOpsetImports(
  _SourceModel a,
  _SourceModel b,
  int defaultOpset,
) {
  final Map<String, int> merged = <String, int>{'': defaultOpset};
  for (final _SourceModel m in <_SourceModel>[a, b]) {
    for (final OnnxOpsetId o in m.model.opsetImports) {
      final String domain = o.domain == 'ai.onnx' ? '' : o.domain;
      if (domain.isEmpty) continue;
      final int? existing = merged[domain];
      if (existing != null && existing != o.version) {
        throw FormatException(
          '域 "$domain" 的 opset 在两模型间不一致：$existing vs ${o.version}',
        );
      }
      merged[domain] = o.version;
    }
  }
  return merged.entries
      .map((MapEntry<String, int> e) => OnnxOpsetId.create(e.key, e.value))
      .toList();
}

// ---------------------------------------------------------------------------
// 子图内联（改名 + IO 绑定）
// ---------------------------------------------------------------------------

class _InlinedGraph {
  const _InlinedGraph(this.nodes, this.initializers);

  final List<OnnxNode> nodes;
  final List<OnnxTensorProto> initializers;
}

/// 把源图所有张量名加 [prefix]（含嵌套子图内的名字），图 IO 按 [bindings] 换成
/// 宿主 body 里的名字；节点名也加前缀。丢弃源图 value_info（可选的形状提示）。
_InlinedGraph _inline(
  _SourceModel source, {
  required String prefix,
  required Map<String, String> bindings,
}) {
  final Map<String, String> rename = <String, String>{};
  _collectDefinedNames(source.graph, prefix, rename, source.label);
  for (final MapEntry<String, String> b in bindings.entries) {
    if (!rename.containsKey(b.key)) {
      throw FormatException('${source.label} 缺 IO "${b.key}"，无法绑定');
    }
    rename[b.key] = b.value;
  }
  final List<OnnxNode> nodes = source.graph.nodes;
  for (final OnnxNode n in nodes) {
    _renameNode(n, prefix, rename, source.label);
  }
  final List<OnnxTensorProto> initializers = source.graph.initializers;
  for (final OnnxTensorProto t in initializers) {
    t.name = _lookup(rename, t.name, source.label, 'initializer');
  }
  return _InlinedGraph(nodes, initializers);
}

/// 登记图（及嵌套子图）里所有「被定义」的名字：输入、initializer、节点输出。
void _collectDefinedNames(
  OnnxGraph graph,
  String prefix,
  Map<String, String> rename,
  String label,
) {
  void define(String name) {
    if (name.isEmpty) return;
    rename.putIfAbsent(name, () => '$prefix$name');
  }

  graph.inputs.map((OnnxValueInfo v) => v.name).forEach(define);
  graph.initializers.map((OnnxTensorProto t) => t.name).forEach(define);
  for (final OnnxNode n in graph.nodes) {
    n.outputs.forEach(define);
    for (final OnnxAttribute a in n.attributes) {
      for (final OnnxGraph sub in _subgraphsOf(a)) {
        _collectDefinedNames(sub, prefix, rename, label);
      }
    }
  }
}

void _renameNode(
  OnnxNode node,
  String prefix,
  Map<String, String> rename,
  String label,
) {
  node.inputs = node.inputs
      .map(
        (String s) =>
            s.isEmpty ? s : _lookup(rename, s, label, '节点 ${node.name} 输入'),
      )
      .toList();
  node.outputs = node.outputs
      .map(
        (String s) =>
            s.isEmpty ? s : _lookup(rename, s, label, '节点 ${node.name} 输出'),
      )
      .toList();
  node.name = '$prefix${node.name.isEmpty ? node.opType : node.name}';
  final List<OnnxAttribute> attrs = node.attributes;
  bool touched = false;
  for (final OnnxAttribute a in attrs) {
    if (a.type == OnnxAttributeType.kGraph) {
      final OnnxGraph? g = a.g;
      if (g != null) {
        _renameGraphInPlace(g, prefix, rename, label);
        a.g = g;
        touched = true;
      }
    } else if (a.type == OnnxAttributeType.kGraphs) {
      final List<OnnxGraph> gs = a.graphs;
      for (final OnnxGraph g in gs) {
        _renameGraphInPlace(g, prefix, rename, label);
      }
      a.graphs = gs;
      touched = true;
    }
  }
  if (touched) node.attributes = attrs;
}

/// 嵌套子图整体改名（IO、initializer、节点、value_info）。
void _renameGraphInPlace(
  OnnxGraph graph,
  String prefix,
  Map<String, String> rename,
  String label,
) {
  final List<OnnxNode> nodes = graph.nodes;
  for (final OnnxNode n in nodes) {
    _renameNode(n, prefix, rename, label);
  }
  graph.nodes = nodes;
  final List<OnnxTensorProto> inits = graph.initializers;
  for (final OnnxTensorProto t in inits) {
    t.name = _lookup(rename, t.name, label, '子图 initializer');
  }
  graph.initializers = inits;
  for (final int which in <int>[0, 1, 2]) {
    final List<OnnxValueInfo> vis = switch (which) {
      0 => graph.inputs,
      1 => graph.outputs,
      _ => graph.valueInfos,
    };
    for (final OnnxValueInfo v in vis) {
      v.name = _lookup(rename, v.name, label, '子图 IO');
    }
    switch (which) {
      case 0:
        graph.inputs = vis;
      case 1:
        graph.outputs = vis;
      default:
        graph.valueInfos = vis;
    }
  }
}

Iterable<OnnxGraph> _subgraphsOf(OnnxAttribute a) {
  if (a.type == OnnxAttributeType.kGraph) {
    final OnnxGraph? g = a.g;
    return g == null ? const <OnnxGraph>[] : <OnnxGraph>[g];
  }
  if (a.type == OnnxAttributeType.kGraphs) return a.graphs;
  return const <OnnxGraph>[];
}

String _lookup(
  Map<String, String> rename,
  String name,
  String label,
  String where,
) {
  final String? out = rename[name];
  if (out == null) {
    throw FormatException('$label $where 引用了未定义的张量 "$name"');
  }
  return out;
}

void _requireUniqueNames(Iterable<String> names) {
  final Set<String> seen = <String>{};
  for (final String n in names) {
    if (n.isEmpty) continue;
    if (!seen.add(n)) {
      throw FormatException('生成图内张量名重复："$n"');
    }
  }
}

bool _sameSet(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);

int _max(int a, int b) => a > b ? a : b;
