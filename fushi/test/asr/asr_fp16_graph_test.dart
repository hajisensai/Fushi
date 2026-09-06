import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_fp16_graph.dart';
import 'package:fushi/src/onnx/onnx_proto.dart';

/// `convertAsrModelToFp16` 的结构测试：手拼一个带 initializer / Constant /
/// Cast(to=float) / If 子图（引用外层输入）的极小模型，断言全图统一 fp16、主图
/// IO 桥、子图作用域改名与拒绝路径。数值等价由
/// `tool/asr/verify_fp16_encoder.py` 用 onnxruntime-directml 对真模型对拍。
void main() {
  /// 合成模型：
  /// ```text
  /// x[N,4] f32, lens[N] i64
  /// w = initializer f32 [4]
  /// c = Constant f32 [1]
  /// a = Add(x, w); b = Cast(lens -> float); s = If(flag){ then: Mul(a, c) ; else: a }
  /// y = Add(s, b)         -> 输出 y f32
  /// lens_out = Identity(lens) -> 输出 i64
  /// ```
  Uint8List buildTiny({bool externalWeight = false, String? extraName}) {
    final OnnxTensorProto w = OnnxTensorProto.float32(
      'w',
      <int>[4],
      <double>[1.0, -2.5, 65520.0, 1e-8],
    );
    if (externalWeight) {
      // data_location = EXTERNAL（字段 14）。
      w.message.setVarint(14, 1);
    }
    final OnnxGraph thenBranch = OnnxGraph.create(
      name: 'then',
      nodes: <OnnxNode>[
        OnnxNode.create(
          opType: 'Mul',
          name: 'mul',
          inputs: <String>['a', 'c'],
          outputs: <String>['s_then'],
        ),
      ],
      inputs: const <OnnxValueInfo>[],
      outputs: <OnnxValueInfo>[
        OnnxValueInfo.tensor('s_then', OnnxDataType.kFloat, <Object>['N', 4]),
      ],
    );
    final OnnxGraph elseBranch = OnnxGraph.create(
      name: 'else',
      nodes: <OnnxNode>[
        OnnxNode.create(
          opType: 'Identity',
          name: 'id_else',
          inputs: <String>['x'],
          outputs: <String>['s_else'],
        ),
      ],
      inputs: const <OnnxValueInfo>[],
      outputs: <OnnxValueInfo>[
        OnnxValueInfo.tensor('s_else', OnnxDataType.kFloat, <Object>['N', 4]),
      ],
    );
    final OnnxGraph g = OnnxGraph.create(
      name: 'tiny',
      nodes: <OnnxNode>[
        OnnxNode.create(
          opType: 'Constant',
          name: 'const_c',
          inputs: const <String>[],
          outputs: <String>['c'],
          attributes: <OnnxAttribute>[
            OnnxAttribute.tensor(
              'value',
              OnnxTensorProto.float32('', <int>[1], <double>[0.5]),
            ),
          ],
        ),
        OnnxNode.create(
          opType: 'Add',
          name: 'add_a',
          inputs: <String>['x', 'w'],
          outputs: <String>['a'],
        ),
        OnnxNode.create(
          opType: 'Cast',
          name: 'cast_b',
          inputs: <String>['lens'],
          outputs: <String>['b'],
          attributes: <OnnxAttribute>[
            OnnxAttribute.int('to', OnnxDataType.kFloat),
          ],
        ),
        OnnxNode.create(
          opType: 'If',
          name: 'gate',
          inputs: <String>['flag'],
          outputs: <String>['s'],
          attributes: <OnnxAttribute>[
            OnnxAttribute.graph('then_branch', thenBranch),
            OnnxAttribute.graph('else_branch', elseBranch),
          ],
        ),
        OnnxNode.create(
          opType: 'Add',
          name: 'add_y',
          inputs: <String>['s', 'b'],
          outputs: <String>[extraName ?? 'y'],
        ),
        OnnxNode.create(
          opType: 'Identity',
          name: 'id_lens',
          inputs: <String>['lens'],
          outputs: <String>['lens_out'],
        ),
      ],
      inputs: <OnnxValueInfo>[
        OnnxValueInfo.tensor('x', OnnxDataType.kFloat, <Object>['N', 4]),
        OnnxValueInfo.tensor('lens', OnnxDataType.kInt64, <Object>['N']),
      ],
      outputs: <OnnxValueInfo>[
        OnnxValueInfo.tensor('y', OnnxDataType.kFloat, <Object>['N', 4]),
        OnnxValueInfo.tensor('lens_out', OnnxDataType.kInt64, <Object>['N']),
      ],
      initializers: <OnnxTensorProto>[
        w,
        OnnxTensorProto.bool('flag', <int>[], <bool>[true]),
      ],
      valueInfos: <OnnxValueInfo>[
        OnnxValueInfo.tensor('a', OnnxDataType.kFloat, <Object>['N', 4]),
      ],
    );
    return OnnxModel.create(
      irVersion: 8,
      producerName: 'test',
      opsetImports: <OnnxOpsetId>[OnnxOpsetId.create('', 17)],
      graph: g,
    ).encode();
  }

  group('float32 → float16 位型', () {
    final Map<double, int> table = <double, int>{
      0.0: 0x0000,
      1.0: 0x3C00,
      -2.5: 0xC100,
      65504.0: 0x7BFF,
      65520.0: 0x7C00, // 舍入进位溢出 → inf
      1e5: 0x7C00,
      -1e9: 0xFC00,
      5.960464477539063e-8: 0x0001, // 最小次正规
      1e-8: 0x0000, // 小于半个最小次正规 → 0
      0.1: 0x2E66,
    };
    int bitsOf(double v) {
      final ByteData d = ByteData(4)..setFloat32(0, v, Endian.little);
      return d.getUint32(0, Endian.little);
    }

    test('已知值逐位一致', () {
      for (final MapEntry<double, int> e in table.entries) {
        expect(
          float32BitsToFloat16Bits(bitsOf(e.key)),
          e.value,
          reason: 'value ${e.key}',
        );
      }
      expect(float32BitsToFloat16Bits(bitsOf(double.infinity)), 0x7C00);
      expect(float32BitsToFloat16Bits(bitsOf(double.negativeInfinity)), 0xFC00);
      final int nan = float32BitsToFloat16Bits(bitsOf(double.nan));
      expect(nan & 0x7C00, 0x7C00);
      expect(nan & 0x03FF, isNot(0));
    });

    test('往返：half 能精确表示的值原样回来，其余误差 ≤ 半 ulp', () {
      for (final double v in <double>[
        0.0,
        1.0,
        -2.5,
        1024.0,
        0.1,
        3.14159,
        -0.00042,
        65504.0,
      ]) {
        final double back = float16BitsToDouble(
          float32BitsToFloat16Bits(bitsOf(v)),
        );
        expect((back - v).abs() <= v.abs() * 1e-3 + 1e-7, isTrue, reason: '$v');
      }
    });

    test('raw 字节：长度减半、小端、偏移不对齐的视图也正确', () {
      final ByteData d = ByteData(12)
        ..setFloat32(0, 1.0, Endian.little)
        ..setFloat32(4, -2.5, Endian.little)
        ..setFloat32(8, 0.5, Endian.little);
      final Uint8List padded = Uint8List(13)
        ..setRange(1, 13, d.buffer.asUint8List());
      final Uint8List unaligned = Uint8List.sublistView(padded, 1);
      expect(unaligned.offsetInBytes % 4, isNot(0));
      final Uint8List out = float32RawToFloat16Raw(unaligned);
      expect(out.length, 6);
      final ByteData o = ByteData.sublistView(out);
      expect(o.getUint16(0, Endian.little), 0x3C00);
      expect(o.getUint16(2, Endian.little), 0xC100);
      expect(o.getUint16(4, Endian.little), 0x3800);
      expect(() => float32RawToFloat16Raw(Uint8List(6)), throwsFormatException);
    });
  });

  group('convertAsrModelToFp16', () {
    late OnnxModel converted;
    late OnnxGraph g;
    setUpAll(() {
      converted = OnnxModel.decode(convertAsrModelToFp16(buildTiny()));
      g = converted.graph!;
    });

    test('主图 IO 保持 fp32 / int64，内侧改名并用 Cast 桥接', () {
      expect(converted.producerName, 'test${AsrFp16Graph.producerSuffix}');
      final Map<String, int?> inputs = <String, int?>{
        for (final OnnxValueInfo v in g.inputs) v.name: v.elemType,
      };
      final Map<String, int?> outputs = <String, int?>{
        for (final OnnxValueInfo v in g.outputs) v.name: v.elemType,
      };
      expect(inputs, <String, int?>{
        'x': OnnxDataType.kFloat,
        'lens': OnnxDataType.kInt64,
      });
      expect(outputs, <String, int?>{
        'y': OnnxDataType.kFloat,
        'lens_out': OnnxDataType.kInt64,
      });
      final List<OnnxNode> nodes = g.nodes;
      final OnnxNode first = nodes.first;
      expect(first.opType, 'Cast');
      expect(first.inputs, <String>['x']);
      expect(first.outputs, <String>['${AsrFp16Graph.prefix}x']);
      expect(first.attributes.single.i, OnnxDataType.kFloat16);
      final OnnxNode last = nodes.last;
      expect(last.opType, 'Cast');
      expect(last.inputs, <String>['${AsrFp16Graph.prefix}y']);
      expect(last.outputs, <String>['y']);
      expect(last.attributes.single.i, OnnxDataType.kFloat);
      // 原节点对 x / y 的引用全部指向内侧名。
      final OnnxNode addA = nodes.firstWhere((OnnxNode n) => n.name == 'add_a');
      expect(addA.inputs, <String>['${AsrFp16Graph.prefix}x', 'w']);
      final OnnxNode addY = nodes.firstWhere((OnnxNode n) => n.name == 'add_y');
      expect(addY.outputs, <String>['${AsrFp16Graph.prefix}y']);
      // 非 float 输出没有桥。
      expect(
        nodes.where((OnnxNode n) => n.opType == 'Cast').length,
        3, // in-bridge、out-bridge、原 cast_b
      );
    });

    test('initializer / Constant / Cast(to=float) / value_info 全部变成 fp16', () {
      final OnnxTensorProto w = g.initializers.firstWhere(
        (OnnxTensorProto t) => t.name == 'w',
      );
      expect(w.dataType, OnnxDataType.kFloat16);
      expect(w.dims, <int>[4]);
      final ByteData raw = ByteData.sublistView(w.rawData!);
      expect(raw.lengthInBytes, 8);
      expect(raw.getUint16(0, Endian.little), 0x3C00);
      expect(raw.getUint16(2, Endian.little), 0xC100);
      expect(raw.getUint16(4, Endian.little), 0x7C00);
      expect(raw.getUint16(6, Endian.little), 0x0000);
      // bool initializer 不动。
      expect(
        g.initializers
            .firstWhere((OnnxTensorProto t) => t.name == 'flag')
            .dataType,
        OnnxDataType.kBool,
      );
      final List<OnnxNode> nodes = g.nodes;
      final OnnxNode c = nodes.firstWhere((OnnxNode n) => n.name == 'const_c');
      expect(c.attributes.single.t!.dataType, OnnxDataType.kFloat16);
      expect(c.attributes.single.t!.rawData!.length, 2);
      final OnnxNode castB = nodes.firstWhere(
        (OnnxNode n) => n.name == 'cast_b',
      );
      expect(castB.attributes.single.i, OnnxDataType.kFloat16);
      expect(g.valueInfos.single.elemType, OnnxDataType.kFloat16);
    });

    test('If 子图：输出类型改 fp16，引用外层输入的节点跟着改名', () {
      final OnnxNode gate = g.nodes.firstWhere(
        (OnnxNode n) => n.name == 'gate',
      );
      final Map<String, OnnxGraph> branches = <String, OnnxGraph>{
        for (final OnnxAttribute a in gate.attributes) a.name: a.g!,
      };
      final OnnxGraph elseBranch = branches['else_branch']!;
      expect(elseBranch.outputs.single.elemType, OnnxDataType.kFloat16);
      expect(elseBranch.nodes.single.inputs, <String>[
        '${AsrFp16Graph.prefix}x',
      ]);
      final OnnxGraph thenBranch = branches['then_branch']!;
      expect(thenBranch.outputs.single.elemType, OnnxDataType.kFloat16);
      expect(thenBranch.nodes.single.inputs, <String>['a', 'c']);
    });

    test('拒绝：外置权重、输出无产出者、桥名撞名', () {
      expect(
        () => convertAsrModelToFp16(buildTiny(externalWeight: true)),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('外置文件'),
          ),
        ),
      );
      expect(
        () => convertAsrModelToFp16(buildTiny(extraName: 'not_y')),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('不是任何节点的产出'),
          ),
        ),
      );
      expect(
        () => convertAsrModelToFp16(
          buildTiny(extraName: '${AsrFp16Graph.prefix}x'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => convertAsrModelToFp16(Uint8List.fromList(<int>[0xFF, 0xFF])),
        throwsFormatException,
      );
    });

    test('真 joiner 夹具（float IO）转换后仍是合法 protobuf 且 IO 契约不变', () {
      final Uint8List joiner = File(
        'test/asr/fixtures/greedy_tiny_joiner.onnx',
      ).readAsBytesSync();
      final OnnxModel out = OnnxModel.decode(convertAsrModelToFp16(joiner));
      final OnnxGraph og = out.graph!;
      for (final OnnxValueInfo v in og.inputs) {
        expect(v.elemType, OnnxDataType.kFloat, reason: v.name);
      }
      expect(og.outputs.single.elemType, OnnxDataType.kFloat);
      expect(
        og.initializers.every(
          (OnnxTensorProto t) => t.dataType != OnnxDataType.kFloat,
        ),
        isTrue,
      );
    });
  });
}
