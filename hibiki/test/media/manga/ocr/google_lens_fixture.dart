import 'dart:convert';
import 'dart:typed_data';

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
  final _ProtoWriter root = _ProtoWriter();
  root.message(2, (_ProtoWriter recognition) {
    recognition.message(3, (_ProtoWriter text) {
      text.message(1, (_ProtoWriter paragraphs) {
        paragraphs.message(1, (_ProtoWriter paragraph) {
          paragraph.message(2, (_ProtoWriter line) {
            line.message(1, (_ProtoWriter word) => word.string(2, firstWord));
            line.message(1, (_ProtoWriter word) => word.string(3, secondWord));
            line.message(2, (_ProtoWriter geometry) {
              geometry.message(1, (_ProtoWriter box) {
                box.float32(1, centerX);
                box.float32(2, centerY);
                box.float32(3, width);
                box.float32(4, height);
                box.float32(5, rotation);
              });
            });
          });
          if (secondLineText != null) {
            paragraph.message(2, (_ProtoWriter line) {
              line.message(
                1,
                (_ProtoWriter word) => word.string(2, secondLineText),
              );
              line.message(2, (_ProtoWriter geometry) {
                geometry.message(1, (_ProtoWriter box) {
                  box.float32(1, centerX);
                  box.float32(2, secondLineCenterY);
                  box.float32(3, width);
                  box.float32(4, height);
                  box.float32(5, rotation);
                });
              });
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
