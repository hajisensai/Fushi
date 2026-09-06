import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onnx/onnx_proto.dart';

/// `onnx_proto.dart` 的 wire 层与 ONNX 类型化视图：编解码往返、未知字段原样保留、
/// 嵌套消息按需解码/回写。
void main() {
  group('wire 层', () {
    test('varint 往返：小值、多字节、int64 最大值与负数（10 字节补码）', () {
      final List<int> samples = <int>[
        0,
        1,
        127,
        128,
        300,
        0xffffffff,
        1 << 40,
        0x7fffffffffffffff,
        -1,
        -1234567890123,
        -0x8000000000000000,
      ];
      for (final int v in samples) {
        final ProtoWriter w = ProtoWriter()..writeVarint(v);
        final Uint8List bytes = w.toBytes();
        expect(bytes.length, lessThanOrEqualTo(10), reason: '$v');
        expect(ProtoReader(bytes).readVarint(), v, reason: '$v');
      }
      // -1 必须是 10 个 0xff 结尾 0x01（与 protobuf 官方编码一致）。
      final Uint8List neg = (ProtoWriter()..writeVarint(-1)).toBytes();
      expect(
        neg,
        Uint8List.fromList(<int>[
          0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, //
        ]),
      );
    });

    test('截断的 varint / 越界长度 / 非法 wire 类型抛 FormatException', () {
      expect(
        () => ProtoReader(Uint8List.fromList(<int>[0x80])).readVarint(),
        throwsFormatException,
      );
      // 字段 1 length-delimited，声称 5 字节但只剩 1 字节。
      expect(
        () => ProtoMessage.decode(Uint8List.fromList(<int>[0x0a, 0x05, 0x01])),
        throwsFormatException,
      );
      // wire type 3（start group）不支持。
      expect(
        () => ProtoMessage.decode(Uint8List.fromList(<int>[0x0b])),
        throwsFormatException,
      );
    });

    test('fixed32 float 与 fixed64 往返', () {
      final ProtoFixed32Field f = ProtoFixed32Field.float(2, 1.5);
      expect(f.asFloat, 1.5);
      final ProtoMessage m = ProtoMessage(<ProtoField>[
        f,
        const ProtoFixed64Field(3, -42),
      ]);
      final ProtoMessage back = ProtoMessage.decode(m.encode());
      expect(back.float(2), 1.5);
      expect((back.fields[1] as ProtoFixed64Field).value, -42);
    });

    test('repeated 标量同时接受 packed 与非 packed', () {
      // 字段 8：非 packed 两个 varint（1, 2）+ packed 一段（3, 300）。
      final ProtoWriter packed = ProtoWriter()
        ..writeVarint(3)
        ..writeVarint(300);
      final ProtoMessage m = ProtoMessage(<ProtoField>[
        const ProtoVarintField(8, 1),
        const ProtoVarintField(8, 2),
        ProtoBytesField(8, packed.toBytes()),
      ]);
      expect(ProtoMessage.decode(m.encode()).varintList(8), <int>[
        1,
        2,
        3,
        300,
      ]);

      final ByteData packedFloats = ByteData(8)
        ..setFloat32(0, 0.25, Endian.little)
        ..setFloat32(4, -2, Endian.little);
      final ProtoMessage mf = ProtoMessage(<ProtoField>[
        ProtoFixed32Field.float(7, 1),
        ProtoBytesField(7, packedFloats.buffer.asUint8List()),
      ]);
      expect(mf.floatList(7), <double>[1, 0.25, -2]);
    });
  });

  group('ProtoMessage', () {
    test('解码→改已知字段→编码：未知字段原样保留、顺序不变', () {
      // 手工拼一段消息：字段 1 varint=7，字段 99 bytes（未知），字段 2 string，
      // 字段 1000 fixed64（未知），字段 2 再次出现（重复）。
      final ProtoMessage original = ProtoMessage(<ProtoField>[
        const ProtoVarintField(1, 7),
        ProtoBytesField(99, Uint8List.fromList(<int>[9, 8, 7, 6])),
        ProtoBytesField.string(2, 'first'),
        const ProtoFixed64Field(1000, 0x0123456789abcdef),
        ProtoBytesField.string(2, 'second'),
      ]);
      final Uint8List bytes = original.encode();
      final ProtoMessage decoded = ProtoMessage.decode(bytes);
      expect(decoded.fields.length, 5);
      expect(decoded.varint(1), 7);
      expect(decoded.stringList(2), <String>['first', 'second']);
      // 合并语义：单值读取取最后一个。
      expect(decoded.string(2), 'second');

      decoded.setVarint(1, 8);
      decoded.setStringList(2, <String>['only']);
      final Uint8List reencoded = decoded.encode();
      final ProtoMessage again = ProtoMessage.decode(reencoded);
      expect(
        again.fields.map((ProtoField f) => f.number).toList(),
        <int>[1, 99, 2, 1000],
        reason: '替换后落在首次出现的位置，未知字段位置不动',
      );
      expect(again.varint(1), 8);
      expect(again.stringList(2), <String>['only']);
      expect(again.bytes(99), Uint8List.fromList(<int>[9, 8, 7, 6]));
      expect((again.fields[3] as ProtoFixed64Field).value, 0x0123456789abcdef);
    });

    test('未改动的消息重编码逐字节一致', () {
      final ProtoMessage m = ProtoMessage(<ProtoField>[
        const ProtoVarintField(3, 1),
        ProtoBytesField.string(1, 'x'),
        ProtoFixed32Field.float(2, 3.25),
        ProtoBytesField(
          5,
          Uint8List.fromList(List<int>.generate(300, (int i) => i & 0xff)),
        ),
      ]);
      final Uint8List bytes = m.encode();
      expect(ProtoMessage.decode(bytes).encode(), bytes);
    });

    test('wire 类型与字段预期不符抛 FormatException', () {
      final ProtoMessage m = ProtoMessage(<ProtoField>[
        ProtoBytesField.string(1, 'not a varint'),
      ]);
      expect(() => m.varint(1), throwsFormatException);
      expect(
        () => ProtoMessage(<ProtoField>[const ProtoVarintField(1, 1)]).bytes(1),
        throwsFormatException,
      );
    });

    test('缺失字段返回 null / 空列表', () {
      final ProtoMessage m = ProtoMessage();
      expect(m.varint(1), isNull);
      expect(m.string(2), isNull);
      expect(m.varintList(3), isEmpty);
      expect(m.has(4), isFalse);
    });
  });

  group('ONNX 视图', () {
    test('TensorProto builder：dims/data_type/raw_data 与 int64 读回', () {
      final OnnxTensorProto t = OnnxTensorProto.int64(
        't',
        <int>[2, 2],
        <int>[1, -1, 5222, 0],
      );
      final OnnxTensorProto back = OnnxTensorProto(
        ProtoMessage.decode(t.encode()),
      );
      expect(back.name, 't');
      expect(back.dims, <int>[2, 2]);
      expect(back.dataType, OnnxDataType.kInt64);
      expect(back.rawData!.length, 32);
      expect(back.readInt64Values(), <int>[1, -1, 5222, 0]);
      expect(
        () => OnnxTensorProto.int64('bad', <int>[3], <int>[1]),
        throwsArgumentError,
      );
      // 用 int64_data（非 raw）编码的张量也能读回。
      final OnnxTensorProto typed = OnnxTensorProto(
        ProtoMessage(<ProtoField>[
          const ProtoVarintField(1, 2),
          const ProtoVarintField(2, OnnxDataType.kInt64),
          const ProtoVarintField(7, 10),
          const ProtoVarintField(7, 20),
        ]),
      );
      expect(typed.readInt64Values(), <int>[10, 20]);
      final OnnxTensorProto f = OnnxTensorProto.float32(
        'f',
        <int>[2],
        <double>[0.5, -1],
      );
      expect(f.dataType, OnnxDataType.kFloat);
      expect(ByteData.sublistView(f.rawData!).getFloat32(4, Endian.little), -1);
    });

    test('ValueInfo：静态维 + 符号维往返', () {
      final OnnxValueInfo v = OnnxValueInfo.tensor(
        'encoder_out',
        OnnxDataType.kFloat,
        <Object>['N', 'T', 512],
      );
      final OnnxValueInfo back = OnnxValueInfo(ProtoMessage.decode(v.encode()));
      expect(back.name, 'encoder_out');
      expect(back.elemType, OnnxDataType.kFloat);
      expect(back.dims, <Object>['N', 'T', 512]);
      final OnnxValueInfo scalar = OnnxValueInfo.tensor(
        's',
        OnnxDataType.kBool,
        const <Object>[],
      );
      expect(scalar.dims, isEmpty);
      expect(
        () => OnnxValueInfo.tensor('x', OnnxDataType.kFloat, <Object>[1.5]),
        throwsArgumentError,
      );
    });

    test('Attribute builder 的 type 枚举值与 onnx.proto 一致', () {
      expect(OnnxAttribute.int('axis', 1).type, 2);
      expect(OnnxAttribute.float('alpha', 1).type, 1);
      expect(OnnxAttribute.string('mode', 'x').type, 3);
      expect(OnnxAttribute.ints('perm', <int>[1, 0]).type, 7);
      expect(OnnxAttribute.ints('perm', <int>[1, 0]).ints, <int>[1, 0]);
      expect(
        OnnxAttribute.tensor(
          'value',
          OnnxTensorProto.int64('c', <int>[], <int>[3]),
        ).type,
        4,
      );
      // 缺 type 时按值字段推断。
      final OnnxAttribute untyped = OnnxAttribute(
        ProtoMessage(<ProtoField>[
          ProtoBytesField.string(1, 'axis'),
          const ProtoVarintField(3, 1),
        ]),
      );
      expect(untyped.type, OnnxAttributeType.kInt);
      expect(untyped.i, 1);
    });

    test('Model → Graph → Node → Attribute(graph) 嵌套往返，且修改子图回写到父级', () {
      final OnnxGraph body = OnnxGraph.create(
        name: 'body',
        nodes: <OnnxNode>[
          OnnxNode.create(
            opType: 'Identity',
            name: 'id',
            inputs: <String>['a'],
            outputs: <String>['b'],
          ),
        ],
        inputs: <OnnxValueInfo>[
          OnnxValueInfo.tensor('a', OnnxDataType.kInt64, const <Object>[]),
        ],
        outputs: <OnnxValueInfo>[
          OnnxValueInfo.tensor('b', OnnxDataType.kInt64, const <Object>[]),
        ],
      );
      final OnnxGraph main = OnnxGraph.create(
        name: 'main',
        nodes: <OnnxNode>[
          OnnxNode.create(
            opType: 'Loop',
            name: 'loop',
            inputs: <String>['m', 'cond', 'x'],
            outputs: <String>['y'],
            attributes: <OnnxAttribute>[OnnxAttribute.graph('body', body)],
          ),
        ],
        initializers: <OnnxTensorProto>[
          OnnxTensorProto.int64('m', <int>[], <int>[3]),
        ],
        inputs: <OnnxValueInfo>[
          OnnxValueInfo.tensor('x', OnnxDataType.kInt64, const <Object>[]),
        ],
        outputs: <OnnxValueInfo>[
          OnnxValueInfo.tensor('y', OnnxDataType.kInt64, const <Object>[]),
        ],
      );
      final OnnxModel model = OnnxModel.create(
        irVersion: 7,
        producerName: 'test',
        opsetImports: <OnnxOpsetId>[OnnxOpsetId.create('', 13)],
        graph: main,
      );
      final OnnxModel back = OnnxModel.decode(model.encode());
      expect(back.irVersion, 7);
      expect(back.producerName, 'test');
      expect(back.hasFunctions, isFalse);
      expect(back.opsetImports.single.domain, '');
      expect(back.opsetImports.single.version, 13);
      final OnnxGraph g = back.graph!;
      expect(g.name, 'main');
      expect(g.initializers.single.readInt64Values(), <int>[3]);
      final OnnxNode loop = g.nodes.single;
      expect(loop.opType, 'Loop');
      expect(loop.inputs, <String>['m', 'cond', 'x']);
      final OnnxAttribute attr = loop.attributes.single;
      expect(attr.type, OnnxAttributeType.kGraph);
      final OnnxGraph inner = attr.g!;
      expect(inner.nodes.single.opType, 'Identity');
      expect(inner.inputs.single.name, 'a');

      // 改子图节点名 → 设回 attr → 设回 node → 设回 graph → 设回 model，整链可见。
      final List<OnnxNode> innerNodes = inner.nodes;
      innerNodes.single.name = 'renamed';
      inner.nodes = innerNodes;
      attr.g = inner;
      loop.attributes = <OnnxAttribute>[attr];
      g.nodes = <OnnxNode>[loop];
      back.graph = g;
      final OnnxModel third = OnnxModel.decode(back.encode());
      expect(
        third.graph!.nodes.single.attributes.single.g!.nodes.single.name,
        'renamed',
      );
    });
  });
}
