import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';

void main() {
  group('FushiByteFormat.bytes', () {
    test('null → —（未知大小占位）', () {
      expect(FushiByteFormat.bytes(null), '—');
    });

    test('B 档整数不带小数', () {
      expect(FushiByteFormat.bytes(0), '0 B');
      expect(FushiByteFormat.bytes(512), '512 B');
      expect(FushiByteFormat.bytes(1023), '1023 B');
    });

    test('KB/MB/GB 保留 1 位小数', () {
      expect(FushiByteFormat.bytes(1024), '1.0 KB');
      expect(FushiByteFormat.bytes(1536), '1.5 KB');
      expect(FushiByteFormat.bytes(5 * 1024 * 1024), '5.0 MB');
      expect(FushiByteFormat.bytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('GB 封顶不再升档', () {
      expect(
        FushiByteFormat.bytes(2048 * 1024 * 1024 * 1024),
        '2048.0 GB',
      );
    });

    test('负值保留符号并正常换档', () {
      expect(FushiByteFormat.bytes(-512), '-512 B');
      expect(FushiByteFormat.bytes(-2048), '-2.0 KB');
    });
  });

  group('FushiByteFormat.speed', () {
    test('null / 负值 / 非有限 → —', () {
      expect(FushiByteFormat.speed(null), '—');
      expect(FushiByteFormat.speed(-1), '—');
      expect(FushiByteFormat.speed(double.infinity), '—');
      expect(FushiByteFormat.speed(double.nan), '—');
    });

    test('速率 = bytes 文案 + /s 后缀', () {
      expect(FushiByteFormat.speed(1536), '1.5 KB/s');
      expect(FushiByteFormat.speed(0), '0 B/s');
    });
  });
}
