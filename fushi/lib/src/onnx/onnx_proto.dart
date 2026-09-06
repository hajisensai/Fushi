/// 最小 protobuf wire 编解码 + ONNX 消息的类型化访问（纯 Dart，无依赖）。
///
/// 用途：在设备上由已下载的 ONNX 模型文件**运行时拼装**新图（例如把 RNN-T
/// decoder/joiner 内联进一张带 `Loop` 的贪心解码图，见 `asr_greedy_graph.dart`），
/// 不引入 protobuf 生成代码、也不托管额外模型。
///
/// 设计：
/// - [ProtoMessage] 把消息解析成**有序字段列表**（字段号 + wire 类型 + 原始值），
///   只对调用方要读/改的字段做解释；其余字段（大块 `raw_data`、`int32_data`、
///   `doc_string`、我们不认识的新字段）原样保留、原位重序列化。
/// - ONNX 类型化包装（[OnnxModel] / [OnnxGraph] / [OnnxNode] / [OnnxAttribute] /
///   [OnnxTensorProto] / [OnnxValueInfo] 等）是 [ProtoMessage] 上的薄视图：
///   getter 按需解码，setter 编码后整体替换该字段号的全部出现（保持首次出现的
///   位置）。批量编辑时「取一次列表 → 改 → 设回一次」。
/// - 字段号按 onnx.proto（IR 7 / opset 13 时代）；proto2 语义，`repeated` 标量
///   字段读取时同时接受 packed 与非 packed 编码。
///
/// 所有格式错误抛 [FormatException]（截断的 varint、越界长度、wire 类型与字段
/// 预期不符、缺必填字段），不静默返回半解析结果。
library;

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// wire 层
// ---------------------------------------------------------------------------

/// protobuf wire 类型（不支持已废弃的 group 0x03/0x04）。
enum ProtoWireType {
  varint(0),
  fixed64(1),
  lengthDelimited(2),
  fixed32(5);

  const ProtoWireType(this.code);

  final int code;

  static ProtoWireType fromCode(int code) {
    switch (code) {
      case 0:
        return ProtoWireType.varint;
      case 1:
        return ProtoWireType.fixed64;
      case 2:
        return ProtoWireType.lengthDelimited;
      case 5:
        return ProtoWireType.fixed32;
      default:
        throw FormatException('不支持的 protobuf wire 类型 $code');
    }
  }
}

/// 顺序读取 protobuf 字节流。
class ProtoReader {
  ProtoReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _pos = 0;

  int get position => _pos;
  bool get isAtEnd => _pos >= _bytes.length;

  /// 读取一个 varint，按 64 位无符号语义拼接后落成 Dart int（负数即 int64 补码）。
  int readVarint() {
    int result = 0;
    int shift = 0;
    while (true) {
      if (_pos >= _bytes.length) {
        throw const FormatException('protobuf varint 在数据末尾被截断');
      }
      final int b = _bytes[_pos++];
      if (shift < 64) {
        result |= (b & 0x7f) << shift;
      }
      if (b & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw const FormatException('protobuf varint 超过 10 字节');
      }
    }
  }

  int readFixed64() {
    _ensure(8);
    final int v = _view.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  int readFixed32() {
    _ensure(4);
    final int v = _view.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  /// 读取 length-delimited 载荷，返回不拷贝的视图。
  Uint8List readBytes() {
    final int length = readVarint();
    if (length < 0 || length > _bytes.length - _pos) {
      throw FormatException(
        'protobuf 长度 $length 越界（剩余 ${_bytes.length - _pos}）',
      );
    }
    final Uint8List out = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return out;
  }

  void _ensure(int n) {
    if (_bytes.length - _pos < n) {
      throw FormatException('protobuf 需要 $n 字节，只剩 ${_bytes.length - _pos}');
    }
  }
}

/// 顺序写出 protobuf 字节流。
class ProtoWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  int get length => _builder.length;

  void writeVarint(int value) {
    // 负数按 int64 补码写 10 字节；`>>>` 保证无符号右移。
    int v = value;
    while (true) {
      if ((v & ~0x7f) == 0) {
        _builder.addByte(v);
        return;
      }
      _builder.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
  }

  void writeKey(int fieldNumber, ProtoWireType type) {
    if (fieldNumber <= 0) {
      throw ArgumentError.value(fieldNumber, 'fieldNumber', '必须为正');
    }
    writeVarint((fieldNumber << 3) | type.code);
  }

  void writeFixed64(int value) {
    _scratch.setInt64(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 8).sublist(0));
  }

  void writeFixed32(int bits) {
    _scratch.setUint32(0, bits & 0xffffffff, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4).sublist(0));
  }

  void writeBytes(Uint8List bytes) {
    writeVarint(bytes.length);
    _builder.add(bytes);
  }

  Uint8List toBytes() => _builder.toBytes();
}

/// 一个已解析的字段：字段号 + wire 类型 + 原始值。
sealed class ProtoField {
  const ProtoField(this.number);

  final int number;

  ProtoWireType get wireType;

  void writeTo(ProtoWriter writer);
}

class ProtoVarintField extends ProtoField {
  const ProtoVarintField(super.number, this.value);

  final int value;

  @override
  ProtoWireType get wireType => ProtoWireType.varint;

  @override
  void writeTo(ProtoWriter writer) {
    writer.writeKey(number, wireType);
    writer.writeVarint(value);
  }
}

class ProtoFixed64Field extends ProtoField {
  const ProtoFixed64Field(super.number, this.value);

  final int value;

  @override
  ProtoWireType get wireType => ProtoWireType.fixed64;

  @override
  void writeTo(ProtoWriter writer) {
    writer.writeKey(number, wireType);
    writer.writeFixed64(value);
  }
}

class ProtoFixed32Field extends ProtoField {
  const ProtoFixed32Field(super.number, this.bits);

  /// 原始 32 位（float 用 [ProtoFixed32Field.float] 构造）。
  final int bits;

  factory ProtoFixed32Field.float(int number, double value) {
    final ByteData d = ByteData(4)..setFloat32(0, value, Endian.little);
    return ProtoFixed32Field(number, d.getUint32(0, Endian.little));
  }

  double get asFloat {
    final ByteData d = ByteData(4)..setUint32(0, bits, Endian.little);
    return d.getFloat32(0, Endian.little);
  }

  @override
  ProtoWireType get wireType => ProtoWireType.fixed32;

  @override
  void writeTo(ProtoWriter writer) {
    writer.writeKey(number, wireType);
    writer.writeFixed32(bits);
  }
}

class ProtoBytesField extends ProtoField {
  const ProtoBytesField(super.number, this.bytes);

  factory ProtoBytesField.string(int number, String value) =>
      ProtoBytesField(number, Uint8List.fromList(utf8.encode(value)));

  final Uint8List bytes;

  String get asString => utf8.decode(bytes);

  @override
  ProtoWireType get wireType => ProtoWireType.lengthDelimited;

  @override
  void writeTo(ProtoWriter writer) {
    writer.writeKey(number, wireType);
    writer.writeBytes(bytes);
  }
}

/// 有序字段列表形式的 protobuf 消息。
class ProtoMessage {
  ProtoMessage([List<ProtoField>? fields]) : fields = fields ?? <ProtoField>[];

  /// 解析整段字节；每个字段保留原始 wire 值，不做任何解释。
  factory ProtoMessage.decode(Uint8List bytes) {
    final ProtoReader reader = ProtoReader(bytes);
    final List<ProtoField> fields = <ProtoField>[];
    while (!reader.isAtEnd) {
      final int key = reader.readVarint();
      final int number = key >>> 3;
      if (number <= 0) {
        throw FormatException('protobuf 字段号非法：$number（偏移 ${reader.position}）');
      }
      final ProtoWireType type = ProtoWireType.fromCode(key & 0x7);
      switch (type) {
        case ProtoWireType.varint:
          fields.add(ProtoVarintField(number, reader.readVarint()));
        case ProtoWireType.fixed64:
          fields.add(ProtoFixed64Field(number, reader.readFixed64()));
        case ProtoWireType.fixed32:
          fields.add(ProtoFixed32Field(number, reader.readFixed32()));
        case ProtoWireType.lengthDelimited:
          fields.add(ProtoBytesField(number, reader.readBytes()));
      }
    }
    return ProtoMessage(fields);
  }

  final List<ProtoField> fields;

  Uint8List encode() {
    final ProtoWriter writer = ProtoWriter();
    for (final ProtoField f in fields) {
      f.writeTo(writer);
    }
    return writer.toBytes();
  }

  bool has(int number) => fields.any((ProtoField f) => f.number == number);

  Iterable<ProtoField> all(int number) =>
      fields.where((ProtoField f) => f.number == number);

  /// 单值 varint 字段（int64/int32/enum/bool）；缺失返回 null。重复出现取最后一个
  /// （proto2 合并语义）。
  int? varint(int number) {
    int? value;
    for (final ProtoField f in all(number)) {
      value = _asVarint(f).value;
    }
    return value;
  }

  /// 单值 length-delimited 字段；缺失返回 null。
  Uint8List? bytes(int number) {
    Uint8List? value;
    for (final ProtoField f in all(number)) {
      value = _asBytes(f).bytes;
    }
    return value;
  }

  String? string(int number) {
    final Uint8List? b = bytes(number);
    return b == null ? null : utf8.decode(b);
  }

  double? float(int number) {
    double? value;
    for (final ProtoField f in all(number)) {
      value = _asFixed32(f).asFloat;
    }
    return value;
  }

  List<Uint8List> bytesList(int number) =>
      all(number).map((ProtoField f) => _asBytes(f).bytes).toList();

  List<String> stringList(int number) =>
      bytesList(number).map(utf8.decode).toList();

  /// repeated int64/int32：同时接受非 packed（多个 varint 字段）与 packed
  /// （一个 length-delimited 载荷内连续 varint）。
  List<int> varintList(int number) {
    final List<int> out = <int>[];
    for (final ProtoField f in all(number)) {
      switch (f) {
        case ProtoVarintField():
          out.add(f.value);
        case ProtoBytesField():
          final ProtoReader r = ProtoReader(f.bytes);
          while (!r.isAtEnd) {
            out.add(r.readVarint());
          }
        default:
          throw FormatException('字段 $number 期望 varint/packed，实际 ${f.wireType}');
      }
    }
    return out;
  }

  /// repeated float：同时接受非 packed 与 packed。
  List<double> floatList(int number) {
    final List<double> out = <double>[];
    for (final ProtoField f in all(number)) {
      switch (f) {
        case ProtoFixed32Field():
          out.add(f.asFloat);
        case ProtoBytesField():
          if (f.bytes.length % 4 != 0) {
            throw FormatException(
              '字段 $number packed float 长度 ${f.bytes.length} 非 4 的倍数',
            );
          }
          final ByteData d = ByteData.sublistView(f.bytes);
          for (int i = 0; i < f.bytes.length; i += 4) {
            out.add(d.getFloat32(i, Endian.little));
          }
        default:
          throw FormatException(
            '字段 $number 期望 fixed32/packed，实际 ${f.wireType}',
          );
      }
    }
    return out;
  }

  /// 删掉字段号 [number] 的全部出现，把 [replacement] 插到原首次出现处（没有则追加）。
  void replaceAll(int number, List<ProtoField> replacement) {
    for (final ProtoField f in replacement) {
      if (f.number != number) {
        throw ArgumentError('替换字段号 ${f.number} 与目标 $number 不一致');
      }
    }
    int insertAt = -1;
    for (int i = fields.length - 1; i >= 0; i--) {
      if (fields[i].number == number) {
        fields.removeAt(i);
        insertAt = i;
      }
    }
    if (insertAt < 0) insertAt = fields.length;
    fields.insertAll(insertAt, replacement);
  }

  void removeAll(int number) => replaceAll(number, const <ProtoField>[]);

  void setVarint(int number, int value) =>
      replaceAll(number, <ProtoField>[ProtoVarintField(number, value)]);

  void setBytes(int number, Uint8List value) =>
      replaceAll(number, <ProtoField>[ProtoBytesField(number, value)]);

  void setString(int number, String value) =>
      replaceAll(number, <ProtoField>[ProtoBytesField.string(number, value)]);

  void setFloat(int number, double value) =>
      replaceAll(number, <ProtoField>[ProtoFixed32Field.float(number, value)]);

  void setBytesList(int number, List<Uint8List> values) => replaceAll(
    number,
    values.map((Uint8List v) => ProtoBytesField(number, v)).toList(),
  );

  void setStringList(int number, List<String> values) => replaceAll(
    number,
    values.map((String v) => ProtoBytesField.string(number, v)).toList(),
  );

  /// repeated int64 按非 packed 写（onnx.proto 是 proto2、未标 packed）。
  void setVarintList(int number, List<int> values) => replaceAll(
    number,
    values.map((int v) => ProtoVarintField(number, v)).toList(),
  );

  void setFloatList(int number, List<double> values) => replaceAll(
    number,
    values.map((double v) => ProtoFixed32Field.float(number, v)).toList(),
  );

  static ProtoVarintField _asVarint(ProtoField f) {
    if (f is ProtoVarintField) return f;
    throw FormatException('字段 ${f.number} 期望 varint，实际 ${f.wireType}');
  }

  static ProtoBytesField _asBytes(ProtoField f) {
    if (f is ProtoBytesField) return f;
    throw FormatException(
      '字段 ${f.number} 期望 length-delimited，实际 ${f.wireType}',
    );
  }

  static ProtoFixed32Field _asFixed32(ProtoField f) {
    if (f is ProtoFixed32Field) return f;
    throw FormatException('字段 ${f.number} 期望 fixed32，实际 ${f.wireType}');
  }
}

// ---------------------------------------------------------------------------
// ONNX 类型化视图
// ---------------------------------------------------------------------------

/// `TensorProto.DataType` 中本仓用到的取值。
abstract final class OnnxDataType {
  static const int kFloat = 1;
  static const int kUint8 = 2;
  static const int kInt8 = 3;
  static const int kInt32 = 6;
  static const int kInt64 = 7;
  static const int kBool = 9;
  static const int kFloat16 = 10;
}

/// `AttributeProto.AttributeType`（枚举值，注意与 AttributeProto 的字段号不同）。
abstract final class OnnxAttributeType {
  static const int kFloat = 1;
  static const int kInt = 2;
  static const int kString = 3;
  static const int kTensor = 4;
  static const int kGraph = 5;
  static const int kFloats = 6;
  static const int kInts = 7;
  static const int kStrings = 8;
  static const int kTensors = 9;
  static const int kGraphs = 10;
}

/// 所有 ONNX 视图的基类：持有一个可变 [ProtoMessage]。
abstract class OnnxMessageView {
  OnnxMessageView(this.message);

  final ProtoMessage message;

  Uint8List encode() => message.encode();
}

/// `ModelProto`。
class OnnxModel extends OnnxMessageView {
  OnnxModel(super.message);

  factory OnnxModel.decode(Uint8List bytes) =>
      OnnxModel(ProtoMessage.decode(bytes));

  /// 新建空模型（无 graph，调用方随后设置）。
  factory OnnxModel.create({
    required int irVersion,
    required String producerName,
    required List<OnnxOpsetId> opsetImports,
    required OnnxGraph graph,
  }) {
    final OnnxModel m = OnnxModel(ProtoMessage());
    m.irVersion = irVersion;
    m.producerName = producerName;
    m.graph = graph;
    m.opsetImports = opsetImports;
    return m;
  }

  static const int _fIrVersion = 1;
  static const int _fProducerName = 2;
  static const int _fGraph = 7;
  static const int _fOpsetImport = 8;
  static const int _fFunctions = 25;

  int? get irVersion => message.varint(_fIrVersion);
  set irVersion(int? v) => v == null
      ? message.removeAll(_fIrVersion)
      : message.setVarint(_fIrVersion, v);

  String? get producerName => message.string(_fProducerName);
  set producerName(String? v) => v == null
      ? message.removeAll(_fProducerName)
      : message.setString(_fProducerName, v);

  OnnxGraph? get graph {
    final Uint8List? b = message.bytes(_fGraph);
    return b == null ? null : OnnxGraph(ProtoMessage.decode(b));
  }

  set graph(OnnxGraph? g) => g == null
      ? message.removeAll(_fGraph)
      : message.setBytes(_fGraph, g.encode());

  List<OnnxOpsetId> get opsetImports => message
      .bytesList(_fOpsetImport)
      .map((Uint8List b) => OnnxOpsetId(ProtoMessage.decode(b)))
      .toList();

  set opsetImports(List<OnnxOpsetId> v) => message.setBytesList(
    _fOpsetImport,
    v.map((OnnxOpsetId o) => o.encode()).toList(),
  );

  /// `functions`（局部函数定义）是否存在——内联子图时不支持。
  bool get hasFunctions => message.has(_fFunctions);
}

/// `OperatorSetIdProto`。
class OnnxOpsetId extends OnnxMessageView {
  OnnxOpsetId(super.message);

  factory OnnxOpsetId.create(String domain, int version) {
    final OnnxOpsetId o = OnnxOpsetId(ProtoMessage());
    if (domain.isNotEmpty) o.message.setString(1, domain);
    o.message.setVarint(2, version);
    return o;
  }

  String get domain => message.string(1) ?? '';
  int get version {
    final int? v = message.varint(2);
    if (v == null) throw const FormatException('OperatorSetIdProto 缺 version');
    return v;
  }
}

/// `GraphProto`。
class OnnxGraph extends OnnxMessageView {
  OnnxGraph(super.message);

  factory OnnxGraph.create({
    required String name,
    required List<OnnxNode> nodes,
    required List<OnnxValueInfo> inputs,
    required List<OnnxValueInfo> outputs,
    List<OnnxTensorProto> initializers = const <OnnxTensorProto>[],
    List<OnnxValueInfo> valueInfos = const <OnnxValueInfo>[],
  }) {
    final OnnxGraph g = OnnxGraph(ProtoMessage());
    g.nodes = nodes;
    g.name = name;
    g.initializers = initializers;
    g.inputs = inputs;
    g.outputs = outputs;
    g.valueInfos = valueInfos;
    return g;
  }

  static const int _fNode = 1;
  static const int _fName = 2;
  static const int _fInitializer = 5;
  static const int _fInput = 11;
  static const int _fOutput = 12;
  static const int _fValueInfo = 13;
  static const int _fSparseInitializer = 15;

  String? get name => message.string(_fName);
  set name(String? v) =>
      v == null ? message.removeAll(_fName) : message.setString(_fName, v);

  List<OnnxNode> get nodes => _decodeList(_fNode, OnnxNode.new);
  set nodes(List<OnnxNode> v) => _encodeList(_fNode, v);

  List<OnnxTensorProto> get initializers =>
      _decodeList(_fInitializer, OnnxTensorProto.new);
  set initializers(List<OnnxTensorProto> v) => _encodeList(_fInitializer, v);

  List<OnnxValueInfo> get inputs => _decodeList(_fInput, OnnxValueInfo.new);
  set inputs(List<OnnxValueInfo> v) => _encodeList(_fInput, v);

  List<OnnxValueInfo> get outputs => _decodeList(_fOutput, OnnxValueInfo.new);
  set outputs(List<OnnxValueInfo> v) => _encodeList(_fOutput, v);

  List<OnnxValueInfo> get valueInfos =>
      _decodeList(_fValueInfo, OnnxValueInfo.new);
  set valueInfos(List<OnnxValueInfo> v) => _encodeList(_fValueInfo, v);

  bool get hasSparseInitializers => message.has(_fSparseInitializer);

  List<T> _decodeList<T>(int number, T Function(ProtoMessage) ctor) => message
      .bytesList(number)
      .map((Uint8List b) => ctor(ProtoMessage.decode(b)))
      .toList();

  void _encodeList(int number, List<OnnxMessageView> views) =>
      message.setBytesList(
        number,
        views.map((OnnxMessageView v) => v.encode()).toList(),
      );
}

/// `NodeProto`。
class OnnxNode extends OnnxMessageView {
  OnnxNode(super.message);

  factory OnnxNode.create({
    required String opType,
    required List<String> inputs,
    required List<String> outputs,
    required String name,
    List<OnnxAttribute> attributes = const <OnnxAttribute>[],
    String domain = '',
  }) {
    final OnnxNode n = OnnxNode(ProtoMessage());
    n.inputs = inputs;
    n.outputs = outputs;
    n.name = name;
    n.opType = opType;
    n.attributes = attributes;
    if (domain.isNotEmpty) n.message.setString(_fDomain, domain);
    return n;
  }

  static const int _fInput = 1;
  static const int _fOutput = 2;
  static const int _fName = 3;
  static const int _fOpType = 4;
  static const int _fAttribute = 5;
  static const int _fDomain = 7;

  List<String> get inputs => message.stringList(_fInput);
  set inputs(List<String> v) => message.setStringList(_fInput, v);

  List<String> get outputs => message.stringList(_fOutput);
  set outputs(List<String> v) => message.setStringList(_fOutput, v);

  String get name => message.string(_fName) ?? '';
  set name(String v) => message.setString(_fName, v);

  String get opType => message.string(_fOpType) ?? '';
  set opType(String v) => message.setString(_fOpType, v);

  String get domain => message.string(_fDomain) ?? '';

  List<OnnxAttribute> get attributes => message
      .bytesList(_fAttribute)
      .map((Uint8List b) => OnnxAttribute(ProtoMessage.decode(b)))
      .toList();

  set attributes(List<OnnxAttribute> v) => message.setBytesList(
    _fAttribute,
    v.map((OnnxAttribute a) => a.encode()).toList(),
  );
}

/// `AttributeProto`。
class OnnxAttribute extends OnnxMessageView {
  OnnxAttribute(super.message);

  static const int _fName = 1;
  static const int _fF = 2;
  static const int _fI = 3;
  static const int _fS = 4;
  static const int _fT = 5;
  static const int _fG = 6;
  static const int _fFloats = 7;
  static const int _fInts = 8;
  static const int _fStrings = 9;
  static const int _fTensors = 10;
  static const int _fGraphs = 11;
  static const int _fType = 20;

  static OnnxAttribute _base(String name, int type) {
    final OnnxAttribute a = OnnxAttribute(ProtoMessage());
    a.message.setString(_fName, name);
    a.message.setVarint(_fType, type);
    return a;
  }

  factory OnnxAttribute.int(String name, int value) =>
      _base(name, OnnxAttributeType.kInt)..message.setVarint(_fI, value);

  factory OnnxAttribute.float(String name, double value) =>
      _base(name, OnnxAttributeType.kFloat)..message.setFloat(_fF, value);

  factory OnnxAttribute.ints(String name, List<int> values) =>
      _base(name, OnnxAttributeType.kInts)
        ..message.setVarintList(_fInts, values);

  factory OnnxAttribute.string(String name, String value) =>
      _base(name, OnnxAttributeType.kString)..message.setString(_fS, value);

  factory OnnxAttribute.tensor(String name, OnnxTensorProto value) =>
      _base(name, OnnxAttributeType.kTensor)
        ..message.setBytes(_fT, value.encode());

  factory OnnxAttribute.graph(String name, OnnxGraph value) =>
      _base(name, OnnxAttributeType.kGraph)
        ..message.setBytes(_fG, value.encode());

  String get name => message.string(_fName) ?? '';

  /// 缺 `type` 时按存在的值字段推断（老导出器偶有此情况）。
  int get type {
    final int? t = message.varint(_fType);
    if (t != null) return t;
    if (message.has(_fF)) return OnnxAttributeType.kFloat;
    if (message.has(_fI)) return OnnxAttributeType.kInt;
    if (message.has(_fS)) return OnnxAttributeType.kString;
    if (message.has(_fT)) return OnnxAttributeType.kTensor;
    if (message.has(_fG)) return OnnxAttributeType.kGraph;
    if (message.has(_fFloats)) return OnnxAttributeType.kFloats;
    if (message.has(_fInts)) return OnnxAttributeType.kInts;
    if (message.has(_fStrings)) return OnnxAttributeType.kStrings;
    if (message.has(_fTensors)) return OnnxAttributeType.kTensors;
    if (message.has(_fGraphs)) return OnnxAttributeType.kGraphs;
    throw FormatException('AttributeProto "$name" 缺 type 且没有值字段');
  }

  int? get i => message.varint(_fI);
  double? get f => message.float(_fF);
  String? get s => message.string(_fS);
  List<int> get ints => message.varintList(_fInts);
  List<double> get floats => message.floatList(_fFloats);
  List<String> get strings => message.stringList(_fStrings);

  OnnxTensorProto? get t {
    final Uint8List? b = message.bytes(_fT);
    return b == null ? null : OnnxTensorProto(ProtoMessage.decode(b));
  }

  set t(OnnxTensorProto? v) =>
      v == null ? message.removeAll(_fT) : message.setBytes(_fT, v.encode());

  OnnxGraph? get g {
    final Uint8List? b = message.bytes(_fG);
    return b == null ? null : OnnxGraph(ProtoMessage.decode(b));
  }

  set g(OnnxGraph? v) =>
      v == null ? message.removeAll(_fG) : message.setBytes(_fG, v.encode());

  List<OnnxGraph> get graphs => message
      .bytesList(_fGraphs)
      .map((Uint8List b) => OnnxGraph(ProtoMessage.decode(b)))
      .toList();

  set graphs(List<OnnxGraph> v) => message.setBytesList(
    _fGraphs,
    v.map((OnnxGraph g) => g.encode()).toList(),
  );
}

/// `TensorProto`。数据只通过 `raw_data`（小端）构造；读取既有模型时其它数据
/// 字段（`float_data`/`int32_data`/`int64_data`…）作为未知字段原样保留。
class OnnxTensorProto extends OnnxMessageView {
  OnnxTensorProto(super.message);

  static const int _fDims = 1;
  static const int _fDataType = 2;
  static const int _fFloatData = 4;
  static const int _fInt64Data = 7;
  static const int _fName = 8;
  static const int _fRawData = 9;
  static const int _fExternalData = 13;
  static const int _fDataLocation = 14;

  /// 任意元素类型的张量，数据以小端 `raw_data` 给出（调用方保证字节数与
  /// [dataType] × 元素数一致；fp16 等本文件没有类型化工厂的类型走这里）。
  factory OnnxTensorProto.raw(
    String name,
    int dataType,
    List<int> dims,
    Uint8List rawData,
  ) => _raw(name, dataType, dims, rawData);

  static OnnxTensorProto _raw(
    String name,
    int dataType,
    List<int> dims,
    Uint8List rawData,
  ) {
    final OnnxTensorProto t = OnnxTensorProto(ProtoMessage());
    t.message.setVarintList(_fDims, dims);
    t.message.setVarint(_fDataType, dataType);
    t.name = name;
    t.message.setBytes(_fRawData, rawData);
    return t;
  }

  factory OnnxTensorProto.int64(String name, List<int> dims, List<int> values) {
    _checkCount(dims, values.length);
    final ByteData d = ByteData(values.length * 8);
    for (int i = 0; i < values.length; i++) {
      d.setInt64(i * 8, values[i], Endian.little);
    }
    return _raw(name, OnnxDataType.kInt64, dims, d.buffer.asUint8List());
  }

  factory OnnxTensorProto.float32(
    String name,
    List<int> dims,
    List<double> values,
  ) {
    _checkCount(dims, values.length);
    final ByteData d = ByteData(values.length * 4);
    for (int i = 0; i < values.length; i++) {
      d.setFloat32(i * 4, values[i], Endian.little);
    }
    return _raw(name, OnnxDataType.kFloat, dims, d.buffer.asUint8List());
  }

  factory OnnxTensorProto.bool(String name, List<int> dims, List<bool> values) {
    _checkCount(dims, values.length);
    final Uint8List raw = Uint8List(values.length);
    for (int i = 0; i < values.length; i++) {
      raw[i] = values[i] ? 1 : 0;
    }
    return _raw(name, OnnxDataType.kBool, dims, raw);
  }

  static void _checkCount(List<int> dims, int count) {
    final int expected = dims.fold<int>(1, (int a, int b) => a * b);
    if (expected != count) {
      throw ArgumentError('dims $dims 需要 $expected 个元素，给了 $count');
    }
  }

  String get name => message.string(_fName) ?? '';
  set name(String v) => message.setString(_fName, v);

  List<int> get dims => message.varintList(_fDims);
  int? get dataType => message.varint(_fDataType);
  Uint8List? get rawData => message.bytes(_fRawData);
  List<int> get int64Data => message.varintList(_fInt64Data);

  /// `float_data`（packed 或非 packed）；只在没有 `raw_data` 的老导出里出现。
  List<double> get floatData => message.floatList(_fFloatData);

  /// 数据不在本文件里（`data_location = EXTERNAL` 或带 `external_data` 项）。
  bool get hasExternalData =>
      message.has(_fExternalData) ||
      (message.varint(_fDataLocation) ?? 0) != 0;

  /// 把 int64 标量/向量读成 Dart 列表（`raw_data` 或 `int64_data` 二者之一）。
  List<int> readInt64Values() {
    if (dataType != OnnxDataType.kInt64) {
      throw FormatException('张量 "$name" 不是 int64（data_type=$dataType）');
    }
    final Uint8List? raw = rawData;
    if (raw == null) return int64Data;
    if (raw.length % 8 != 0) {
      throw FormatException('张量 "$name" raw_data 长度 ${raw.length} 非 8 的倍数');
    }
    final ByteData d = ByteData.sublistView(raw);
    return List<int>.generate(
      raw.length ~/ 8,
      (int i) => d.getInt64(i * 8, Endian.little),
    );
  }
}

/// `ValueInfoProto`（只支持 `tensor_type`）。
class OnnxValueInfo extends OnnxMessageView {
  OnnxValueInfo(super.message);

  /// [dims] 每项为 `int`（静态维）或 `String`（符号维）。
  factory OnnxValueInfo.tensor(String name, int elemType, List<Object> dims) {
    final OnnxValueInfo v = OnnxValueInfo(ProtoMessage());
    v.name = name;
    v.message.setBytes(_fType, _encodeTensorType(elemType, dims));
    return v;
  }

  static const int _fName = 1;
  static const int _fType = 2;

  // TypeProto / TypeProto.Tensor / TensorShapeProto / Dimension 字段号。
  static const int _fTypeTensorType = 1;
  static const int _fTensorElemType = 1;
  static const int _fTensorShape = 2;
  static const int _fShapeDim = 1;
  static const int _fDimValue = 1;
  static const int _fDimParam = 2;

  static Uint8List _encodeTensorType(int elemType, List<Object> dims) {
    final ProtoMessage shape = ProtoMessage();
    for (final Object d in dims) {
      final ProtoMessage dim = ProtoMessage();
      if (d is int) {
        dim.setVarint(_fDimValue, d);
      } else if (d is String) {
        dim.setString(_fDimParam, d);
      } else {
        throw ArgumentError.value(d, 'dims', '只接受 int 或 String');
      }
      shape.fields.add(ProtoBytesField(_fShapeDim, dim.encode()));
    }
    final ProtoMessage tensor = ProtoMessage()
      ..setVarint(_fTensorElemType, elemType)
      ..setBytes(_fTensorShape, shape.encode());
    return (ProtoMessage()..setBytes(_fTypeTensorType, tensor.encode()))
        .encode();
  }

  String get name => message.string(_fName) ?? '';
  set name(String v) => message.setString(_fName, v);

  ProtoMessage? get _tensorType {
    final Uint8List? type = message.bytes(_fType);
    if (type == null) return null;
    final Uint8List? tensor = ProtoMessage.decode(type).bytes(_fTypeTensorType);
    return tensor == null ? null : ProtoMessage.decode(tensor);
  }

  /// 元素类型；非张量类型（sequence/map/optional）返回 null。
  int? get elemType => _tensorType?.varint(_fTensorElemType);

  /// 只改元素类型，形状与其它字段原样保留；非张量类型抛 [FormatException]。
  void setElemType(int value) {
    final Uint8List? type = message.bytes(_fType);
    final Uint8List? tensor = type == null
        ? null
        : ProtoMessage.decode(type).bytes(_fTypeTensorType);
    if (type == null || tensor == null) {
      throw FormatException('ValueInfoProto "$name" 不是张量类型');
    }
    final ProtoMessage typeMsg = ProtoMessage.decode(type);
    final ProtoMessage tensorMsg = ProtoMessage.decode(tensor)
      ..setVarint(_fTensorElemType, value);
    typeMsg.setBytes(_fTypeTensorType, tensorMsg.encode());
    message.setBytes(_fType, typeMsg.encode());
  }

  /// 形状：每项 `int`（静态）或 `String`（符号，未命名符号维给空串）；
  /// 没有 shape 字段（rank 未知）返回 null。
  List<Object>? get dims {
    final ProtoMessage? tensor = _tensorType;
    if (tensor == null) return null;
    final Uint8List? shape = tensor.bytes(_fTensorShape);
    if (shape == null) return null;
    return ProtoMessage.decode(shape).bytesList(_fShapeDim).map((Uint8List b) {
      final ProtoMessage dim = ProtoMessage.decode(b);
      final int? value = dim.varint(_fDimValue);
      if (value != null) return value as Object;
      return (dim.string(_fDimParam) ?? '') as Object;
    }).toList();
  }
}
