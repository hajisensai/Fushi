import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/adts_duration.dart';

/// 合成一个 ADTS 帧：7 字节头 + [payload] 字节，采样率索引 [frequencyIndex]。
Uint8List _adtsFrame({required int frequencyIndex, int payload = 20}) {
  final int length = 7 + payload;
  final Uint8List frame = Uint8List(length);
  frame[0] = 0xFF;
  frame[1] = 0xF1; // syncword 尾 + MPEG-4 + no CRC
  frame[2] = (1 << 6) | (frequencyIndex << 2); // profile AAC-LC, freq index
  frame[3] = (length >> 11) & 0x03;
  frame[4] = (length >> 3) & 0xFF;
  frame[5] = (length & 0x07) << 5;
  frame[6] = 0xFC;
  return frame;
}

void main() {
  test('sums 1024 samples per frame at the header sample rate', () {
    final BytesBuilder builder = BytesBuilder();
    // 44100 Hz（索引 4）×  43 帧 ≈ 998 ms。
    for (int i = 0; i < 43; i++) {
      builder.add(_adtsFrame(frequencyIndex: 4));
    }
    expect(adtsDurationMs(builder.toBytes()), 998);
  });

  test('ignores a truncated trailing frame', () {
    final BytesBuilder builder = BytesBuilder();
    for (int i = 0; i < 10; i++) {
      builder.add(_adtsFrame(frequencyIndex: 3)); // 48000 Hz
    }
    builder.add(_adtsFrame(frequencyIndex: 3).sublist(0, 12));
    expect(adtsDurationMs(builder.toBytes()), (10 * 1024 * 1000) ~/ 48000);
  });

  test('returns null for non-ADTS bytes and reserved sample rates', () {
    expect(
      adtsDurationMs(
        Uint8List.fromList(<int>[0, 0, 0, 0x1C, 0x66, 0x74, 0x79, 0x70]),
      ),
      isNull,
    );
    expect(adtsDurationMs(_adtsFrame(frequencyIndex: 15)), isNull);
    expect(adtsDurationMs(Uint8List(3)), isNull);
  });

  test('frame_length 小于头长时判损坏返回 null（否则 offset 不前进 = 死循环）', () {
    // frame_length 字段写 0：偏移不会前进，缺了守卫这条断言不是失败而是**挂死**。
    final Uint8List frame = _adtsFrame(frequencyIndex: 4);
    frame[3] &= ~0x03; // frame_length 高 2 位
    frame[4] = 0;
    frame[5] &= 0x1F; // frame_length 低 3 位
    expect(adtsDurationMs(frame), isNull);

    // 边界：正好 6（< 7 字节头）同样判损坏。
    final Uint8List six = _adtsFrame(frequencyIndex: 4);
    six[3] &= ~0x03;
    six[4] = 6 >> 3;
    six[5] = (six[5] & 0x1F) | ((6 & 0x07) << 5);
    expect(adtsDurationMs(six), isNull);
  });
}
