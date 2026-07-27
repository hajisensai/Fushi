import 'dart:convert';
import 'dart:typed_data';

import 'package:hibiki/src/media/manga/ocr/google_lens_protocol.dart';

/// 合成一份 Lens `LensOverlayServerResponse` 的 protobuf 字节。
///
/// ## 这份 fixture 能证明什么、不能证明什么（BUG-1163 审查结论）
///
/// 它**能**证明解码算法本身：旋转判竖排、CJK 去空格、视觉顺序排序、畸形数据
/// 拒绝——因为这些逻辑不依赖字段号是否与 Google 一致。
///
/// 它**不能**独立证明字段号与真实 wire 格式一致：本文件按 [GoogleLensWireFields]
/// 编码，实现也按同一张表解码，字段号整体写错时这里照样全绿。以前这里是自己
/// 硬编码 `2/3/1/1/2…` 一套魔数，那才是纯闭环；现在字段号只有一处定义，其外部
/// 锚点是 `google_lens_wire_contract_test.dart`——那份测试拿**与本实现无血缘
/// 关系**的第三方 protoc 产物逐条核对 [GoogleLensWireFields]，字段号写错在那里
/// 变红。两者合起来才构成完整证据链：契约测试钉住「字段号 = Google 的」，本
/// fixture 钉住「按这些字段号解出来的语义是对的」。
///
/// 仍未覆盖：真实响应里的可选字段、presence 语义、`coordinate_type` 非归一化
/// 分支。要覆盖那些必须入库一份脱敏的真实响应字节，本仓目前没有。
Uint8List makeGoogleLensFixture({
  String firstWord = '日 ',
  String secondWord = '本',
  double centerX = 0.5,
  double centerY = 0.5,
  double width = 0.4,
  double height = 0.1,
  double rotation = 0,
  String? secondLineText,
  double secondLineCenterY = 0.3,
}) {
  void writeGeometry(_ProtoWriter line, double boxCenterY) {
    line.message(GoogleLensWireFields.lineGeometry, (_ProtoWriter geometry) {
      geometry.message(GoogleLensWireFields.geometryBoundingBox,
          (_ProtoWriter box) {
        box.float32(GoogleLensWireFields.boxCenterX, centerX);
        box.float32(GoogleLensWireFields.boxCenterY, boxCenterY);
        box.float32(GoogleLensWireFields.boxWidth, width);
        box.float32(GoogleLensWireFields.boxHeight, height);
        box.float32(GoogleLensWireFields.boxRotationZ, rotation);
      });
    });
  }

  final _ProtoWriter root = _ProtoWriter();
  root.message(GoogleLensWireFields.serverResponseObjectsResponse,
      (_ProtoWriter recognition) {
    recognition.message(GoogleLensWireFields.objectsResponseText,
        (_ProtoWriter text) {
      text.message(GoogleLensWireFields.textTextLayout, (_ProtoWriter layout) {
        layout.message(GoogleLensWireFields.textLayoutParagraphs,
            (_ProtoWriter paragraph) {
          paragraph.message(GoogleLensWireFields.paragraphLines,
              (_ProtoWriter line) {
            line.message(
              GoogleLensWireFields.lineWords,
              (_ProtoWriter word) =>
                  word.string(GoogleLensWireFields.wordPlainText, firstWord),
            );
            line.message(
              GoogleLensWireFields.lineWords,
              (_ProtoWriter word) => word.string(
                  GoogleLensWireFields.wordTextSeparator, secondWord),
            );
            writeGeometry(line, centerY);
          });
          if (secondLineText != null) {
            paragraph.message(GoogleLensWireFields.paragraphLines,
                (_ProtoWriter line) {
              line.message(
                GoogleLensWireFields.lineWords,
                (_ProtoWriter word) => word.string(
                    GoogleLensWireFields.wordPlainText, secondLineText),
              );
              writeGeometry(line, secondLineCenterY);
            });
          }
        });
      });
    });
  });
  return root.bytes;
}

class _ProtoWriter {
  final BytesBuilder _output = BytesBuilder(copy: false);

  Uint8List get bytes => _output.takeBytes();

  void string(int field, String value) =>
      data(field, Uint8List.fromList(utf8.encode(value)));

  void float32(int field, double value) {
    key(field, 5);
    final ByteData data = ByteData(4)..setFloat32(0, value, Endian.little);
    _output.add(data.buffer.asUint8List());
  }

  void message(int field, void Function(_ProtoWriter child) write) {
    final _ProtoWriter child = _ProtoWriter();
    write(child);
    data(field, child.bytes);
  }

  void data(int field, Uint8List value) {
    key(field, 2);
    varint(value.length);
    _output.add(value);
  }

  void key(int field, int wire) => varint((field << 3) | wire);

  void varint(int value) {
    int remaining = value;
    while (remaining >= 0x80) {
      _output.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _output.addByte(remaining);
  }
}
