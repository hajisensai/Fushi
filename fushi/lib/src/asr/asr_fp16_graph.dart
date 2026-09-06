/// 把 fp32 ONNX 模型在设备上整图转成 fp16（GPU 张量核的半精度吞吐约 2 倍）。
///
/// 只在 DirectML / CUDA 这类 fp16 有真实内核收益的 EP 上使用（装配见
/// `asr_engine.dart`）；不下载、不托管：由已下载的 fp32 编码器字节运行时生成并
/// 缓存（`AsrModelStore.ensureFp16Encoder`），与贪心 Loop 图同一套派生文件机制。
///
/// 策略是**全图统一**：主图与全部子图（`If` / `Loop` body）里所有 float 张量——
/// initializer、`Constant` / `ConstantOfShape` 的值、`Cast(to=float)` 的目标、
/// 子图 IO 与 `value_info`——一律改成 float16；只在**主图**的 float 输入 / 输出各插
/// 一个 `Cast` 桥回 fp32，调用方喂 fp32、读 fp32，与原模型契约逐字节相同。
/// 统一转换在结构上不可能出现「同一算子两个输入一边 float 一边 float16」——
/// onnxconverter-common 的 `convert_float_to_float16` 对 `If` 子图引用外层张量
/// 就会转出这种坏图（2026-09-07 实测：zipformer 编码器 `If_163` 里的 `Add_180`
/// 建会话即报 TypeInferenceError）。
///
/// 数值：float→half 按 IEEE 754 舍入到最近偶数；超出 ±65504 落成 ±inf，不做
/// onnxconverter 那种 ±1e4 截断——掩码里的 `-inf` / 大负数本来就该在 softmax
/// 里归零，截成 -1e4 反而会漏一点概率。zipformer 编码器 717 个 float initializer
/// 最大绝对值 25.9（2026-09-07 盘点），权重侧没有溢出面；激活侧的精度损失由
/// `integration_test/asr_transcribe_e2e_itest.dart` 用真机 fp32 / fp16 转写对照
/// 钉住。
///
/// 拒绝的形态（抛 [FormatException]，调用方回退 fp32）：`functions`、
/// `sparse_initializer`、外置权重（`data_location = EXTERNAL`，Omnilingual 1B
/// 的 3.9 GB `model.weights`）、主图 float 输出不是任何节点产出。
library;

import 'dart:typed_data';

import 'package:fushi/src/onnx/onnx_proto.dart';

/// 生成图的命名约定（测试与诊断用）。
abstract final class AsrFp16Graph {
  /// 主图 float IO 桥内侧张量名的前缀：输入 `x` 的 fp16 内部名是 `f16_x`。
  static const String prefix = 'f16_';

  /// 追加到 `producer_name` 尾部的标记。
  static const String producerSuffix = '+fushi-fp16';
}

/// 把 [modelOnnx] 整图转成 fp16，返回可直接喂 ORT 的 ModelProto 字节。
Uint8List convertAsrModelToFp16(Uint8List modelOnnx) {
  final OnnxModel model;
  try {
    model = OnnxModel.decode(modelOnnx);
  } on FormatException catch (e) {
    throw FormatException('不是合法的 ONNX protobuf：${e.message}');
  }
  if (model.hasFunctions) {
    throw const FormatException('模型含 functions（局部函数），fp16 转换不支持');
  }
  final OnnxGraph? graph = model.graph;
  if (graph == null) throw const FormatException('模型没有 graph');
  model.graph = _Fp16Converter().convertMain(graph);
  model.producerName =
      '${model.producerName ?? ''}${AsrFp16Graph.producerSuffix}';
  return model.encode();
}

/// 一次转换的工作对象：持有改名表与统计。
class _Fp16Converter {
  OnnxGraph convertMain(OnnxGraph g) {
    if (g.hasSparseInitializers) {
      throw const FormatException('模型含 sparse_initializer，fp16 转换不支持');
    }
    final Set<String> initializerNames = <String>{
      for (final OnnxTensorProto t in g.initializers) t.name,
    };
    final Set<String> allNames = _collectNames(g);

    // 主图 float 输入 / 输出：外侧保持 fp32，内侧改名为 `f16_<name>`，节点里对它
    // 的引用全部指向内侧名，最后用 Cast 桥接。带 initializer 的输入是老导出的
    // 「有默认值的输入」，不是喂进来的张量——它随 initializer 一起变成 fp16。
    final Map<String, String> rename = <String, String>{};
    final List<OnnxValueInfo> inputs = g.inputs;
    final List<OnnxValueInfo> outputs = g.outputs;
    for (final OnnxValueInfo v in inputs) {
      if (v.elemType != OnnxDataType.kFloat) continue;
      if (initializerNames.contains(v.name)) {
        v.setElemType(OnnxDataType.kFloat16);
        continue;
      }
      rename[v.name] = _bridgeName(v.name, allNames);
    }
    for (final OnnxValueInfo v in outputs) {
      if (v.elemType != OnnxDataType.kFloat) continue;
      // 输入直通输出时内侧名共用输入的，输出侧仍插自己的 Cast。
      rename.putIfAbsent(v.name, () => _bridgeName(v.name, allNames));
    }

    final List<OnnxNode> nodes = _convertNodes(g.nodes, rename);
    final Set<String> available = <String>{
      for (final OnnxNode n in nodes) ...n.outputs,
      for (final OnnxValueInfo v in inputs)
        if (rename.containsKey(v.name)) rename[v.name]!,
    };
    final List<OnnxNode> castIn = <OnnxNode>[];
    final List<OnnxNode> castOut = <OnnxNode>[];
    for (final OnnxValueInfo v in inputs) {
      final String? inner = rename[v.name];
      if (inner == null) continue;
      castIn.add(
        _cast(
          '${AsrFp16Graph.prefix}in_${v.name}',
          v.name,
          inner,
          OnnxDataType.kFloat16,
        ),
      );
    }
    for (final OnnxValueInfo v in outputs) {
      final String? inner = rename[v.name];
      if (inner == null) continue;
      if (!available.contains(inner)) {
        throw FormatException('主图 float 输出 "${v.name}" 不是任何节点的产出');
      }
      castOut.add(
        _cast(
          '${AsrFp16Graph.prefix}out_${v.name}',
          inner,
          v.name,
          OnnxDataType.kFloat,
        ),
      );
    }

    g.nodes = <OnnxNode>[...castIn, ...nodes, ...castOut];
    g.initializers = _convertInitializers(g.initializers);
    g.inputs = inputs;
    g.outputs = outputs;
    g.valueInfos = _convertValueInfos(g.valueInfos);
    return g;
  }

  /// 子图：IO / value_info / initializer 全转 fp16，外层改名表去掉本图自己声明
  /// 的名字（作用域遮蔽）。
  OnnxGraph _convertSubgraph(OnnxGraph g, Map<String, String> outerRename) {
    if (g.hasSparseInitializers) {
      throw const FormatException('子图含 sparse_initializer，fp16 转换不支持');
    }
    final Map<String, String> rename = Map<String, String>.of(outerRename);
    for (final OnnxValueInfo v in g.inputs) {
      rename.remove(v.name);
    }
    for (final OnnxTensorProto t in g.initializers) {
      rename.remove(t.name);
    }
    g.nodes = _convertNodes(g.nodes, rename);
    g.initializers = _convertInitializers(g.initializers);
    g.inputs = _convertValueInfos(g.inputs);
    g.outputs = _convertValueInfos(g.outputs);
    g.valueInfos = _convertValueInfos(g.valueInfos);
    return g;
  }

  List<OnnxNode> _convertNodes(
    List<OnnxNode> nodes,
    Map<String, String> rename,
  ) {
    for (final OnnxNode n in nodes) {
      if (rename.isNotEmpty) {
        n.inputs = n.inputs
            .map((String s) => rename[s] ?? s)
            .toList(growable: false);
        n.outputs = n.outputs
            .map((String s) => rename[s] ?? s)
            .toList(growable: false);
      }
      final List<OnnxAttribute> attrs = n.attributes;
      bool changed = false;
      for (int i = 0; i < attrs.length; i++) {
        final OnnxAttribute a = attrs[i];
        switch (a.type) {
          case OnnxAttributeType.kGraph:
            a.g = _convertSubgraph(a.g!, rename);
            changed = true;
          case OnnxAttributeType.kGraphs:
            a.graphs = a.graphs
                .map((OnnxGraph sg) => _convertSubgraph(sg, rename))
                .toList(growable: false);
            changed = true;
          case OnnxAttributeType.kTensor:
            final OnnxTensorProto t = a.t!;
            if (t.dataType == OnnxDataType.kFloat) {
              a.t = _convertTensor(t);
              changed = true;
            }
          case OnnxAttributeType.kInt:
            if (n.opType == 'Cast' &&
                a.name == 'to' &&
                a.i == OnnxDataType.kFloat) {
              attrs[i] = OnnxAttribute.int('to', OnnxDataType.kFloat16);
              changed = true;
            }
          case OnnxAttributeType.kFloat:
          case OnnxAttributeType.kFloats:
            if (n.opType == 'Constant') {
              // `value_float(s)` 形态的常量：输出类型跟着属性走，必须换成 fp16
              // 张量属性 `value`。
              final bool scalar = a.type == OnnxAttributeType.kFloat;
              final List<double> values = scalar ? <double>[a.f!] : a.floats;
              attrs[i] = OnnxAttribute.tensor(
                'value',
                _tensorFromDoubles(
                  '',
                  scalar ? const <int>[] : <int>[values.length],
                  values,
                ),
              );
              changed = true;
            }
          default:
            break;
        }
      }
      if (changed) n.attributes = attrs;
    }
    return nodes;
  }

  List<OnnxTensorProto> _convertInitializers(List<OnnxTensorProto> tensors) {
    for (int i = 0; i < tensors.length; i++) {
      if (tensors[i].dataType != OnnxDataType.kFloat) continue;
      tensors[i] = _convertTensor(tensors[i]);
    }
    return tensors;
  }

  List<OnnxValueInfo> _convertValueInfos(List<OnnxValueInfo> infos) {
    for (final OnnxValueInfo v in infos) {
      if (v.elemType == OnnxDataType.kFloat) {
        v.setElemType(OnnxDataType.kFloat16);
      }
    }
    return infos;
  }

  static OnnxTensorProto _convertTensor(OnnxTensorProto t) {
    if (t.hasExternalData) {
      throw FormatException('张量 "${t.name}" 的数据在外置文件里，fp16 转换不支持');
    }
    final Uint8List? raw = t.rawData;
    if (raw != null) {
      return OnnxTensorProto.raw(
        t.name,
        OnnxDataType.kFloat16,
        t.dims,
        float32RawToFloat16Raw(raw),
      );
    }
    return _tensorFromDoubles(t.name, t.dims, t.floatData);
  }

  static OnnxTensorProto _tensorFromDoubles(
    String name,
    List<int> dims,
    List<double> values,
  ) {
    final ByteData d = ByteData(values.length * 4);
    for (int i = 0; i < values.length; i++) {
      d.setFloat32(i * 4, values[i], Endian.little);
    }
    return OnnxTensorProto.raw(
      name,
      OnnxDataType.kFloat16,
      dims,
      float32RawToFloat16Raw(d.buffer.asUint8List()),
    );
  }

  static OnnxNode _cast(String name, String input, String output, int to) =>
      OnnxNode.create(
        opType: 'Cast',
        name: name,
        inputs: <String>[input],
        outputs: <String>[output],
        attributes: <OnnxAttribute>[OnnxAttribute.int('to', to)],
      );

  static String _bridgeName(String name, Set<String> taken) {
    final String inner = '${AsrFp16Graph.prefix}$name';
    if (taken.contains(inner)) {
      throw FormatException('张量名 "$inner" 已存在，无法为 "$name" 造 fp16 桥');
    }
    return inner;
  }

  /// 主图（含子图）里出现过的全部张量名，用于桥名查重。
  static Set<String> _collectNames(OnnxGraph g) {
    final Set<String> names = <String>{};
    void walk(OnnxGraph graph) {
      for (final OnnxValueInfo v in graph.inputs) {
        names.add(v.name);
      }
      for (final OnnxValueInfo v in graph.outputs) {
        names.add(v.name);
      }
      for (final OnnxTensorProto t in graph.initializers) {
        names.add(t.name);
      }
      for (final OnnxNode n in graph.nodes) {
        names
          ..addAll(n.inputs)
          ..addAll(n.outputs);
        for (final OnnxAttribute a in n.attributes) {
          if (a.type == OnnxAttributeType.kGraph) walk(a.g!);
          if (a.type == OnnxAttributeType.kGraphs) a.graphs.forEach(walk);
        }
      }
    }

    walk(g);
    return names;
  }
}

/// 小端 float32 字节 → 小端 float16 字节（长度减半）。
Uint8List float32RawToFloat16Raw(Uint8List raw) {
  if (raw.length % 4 != 0) {
    throw FormatException('float32 raw_data 长度 ${raw.length} 非 4 的倍数');
  }
  final int n = raw.length ~/ 4;
  // sublistView 出来的视图偏移未必 4 对齐；不对齐就拷一份再建 32 位视图。
  final Uint8List aligned = raw.offsetInBytes % 4 == 0
      ? raw
      : Uint8List.fromList(raw);
  final Uint32List src = Uint32List.view(
    aligned.buffer,
    aligned.offsetInBytes,
    n,
  );
  final Uint8List out = Uint8List(n * 2);
  if (Endian.host == Endian.little) {
    final Uint16List dst = Uint16List.view(out.buffer, 0, n);
    for (int i = 0; i < n; i++) {
      dst[i] = float32BitsToFloat16Bits(src[i]);
    }
  } else {
    final ByteData d = ByteData.view(out.buffer);
    for (int i = 0; i < n; i++) {
      d.setUint16(i * 2, float32BitsToFloat16Bits(src[i]), Endian.little);
    }
  }
  return out;
}

/// IEEE 754 binary32 位型 → binary16 位型：舍入到最近偶数；超出范围落 ±inf；
/// NaN 保持 NaN（保留静默位）；次正规按位精确舍入；小于半个最小次正规归零。
int float32BitsToFloat16Bits(int f) {
  f &= 0xFFFFFFFF;
  final int sign = (f >> 16) & 0x8000;
  final int exp = (f >> 23) & 0xFF;
  int mant = f & 0x7FFFFF;
  if (exp == 0xFF) {
    // inf / NaN：NaN 至少保留一位尾数，别退化成 inf。
    return sign | 0x7C00 | (mant == 0 ? 0 : 0x200 | (mant >> 13));
  }
  final int e = exp - 127 + 15;
  if (e >= 0x1F) return sign | 0x7C00;
  if (e <= 0) {
    // 次正规（或下溢）：隐含位补回来后右移 (14 - e) 位，带舍入。
    if (e < -10) return sign;
    mant |= 0x800000;
    final int shift = 14 - e;
    int half = mant >> shift;
    final int rem = mant & ((1 << shift) - 1);
    final int halfway = 1 << (shift - 1);
    if (rem > halfway || (rem == halfway && (half & 1) == 1)) half++;
    return sign | half;
  }
  int half = (e << 10) | (mant >> 13);
  final int rem = mant & 0x1FFF;
  // 进位可能溢出到指数位——那正是 65520 → inf 的正确结果。
  if (rem > 0x1000 || (rem == 0x1000 && (half & 1) == 1)) half++;
  return sign | half;
}

/// binary16 位型 → double（测试 / 诊断用的逆变换）。
double float16BitsToDouble(int h) {
  h &= 0xFFFF;
  final int sign = (h & 0x8000) != 0 ? -1 : 1;
  final int exp = (h >> 10) & 0x1F;
  final int mant = h & 0x3FF;
  if (exp == 0x1F) return mant == 0 ? sign * double.infinity : double.nan;
  if (exp == 0) return sign * mant * 5.960464477539063e-8; // 2^-24
  return sign * (1 + mant / 1024) * _pow2(exp - 15);
}

double _pow2(int e) {
  double v = 1;
  if (e >= 0) {
    for (int i = 0; i < e; i++) {
      v *= 2;
    }
  } else {
    for (int i = 0; i < -e; i++) {
      v /= 2;
    }
  }
  return v;
}
