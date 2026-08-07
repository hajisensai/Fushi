import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/hibiki_byte_format.dart';

void main() {
  group('HibikiByteFormat.bytes', () {
    test('null → —（未知大小占位）', () {
      expect(HibikiByteFormat.bytes(null), '—');
    });

    test('B 档整数不带小数', () {
      expect(HibikiByteFormat.bytes(0), '0 B');
      expect(HibikiByteFormat.bytes(512), '512 B');
      expect(HibikiByteFormat.bytes(1023), '1023 B');
    });

    test('KB/MB/GB 保留 1 位小数', () {
      expect(HibikiByteFormat.bytes(1024), '1.0 KB');
      expect(HibikiByteFormat.bytes(1536), '1.5 KB');
      expect(HibikiByteFormat.bytes(5 * 1024 * 1024), '5.0 MB');
      expect(HibikiByteFormat.bytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('GB 封顶不再升档', () {
      expect(
        HibikiByteFormat.bytes(2048 * 1024 * 1024 * 1024),
        '2048.0 GB',
      );
    });

    test('负值保留符号并正常换档', () {
      expect(HibikiByteFormat.bytes(-512), '-512 B');
      expect(HibikiByteFormat.bytes(-2048), '-2.0 KB');
    });
  });

  group('HibikiByteFormat.speed', () {
    test('null / 负值 / 非有限 → —', () {
      expect(HibikiByteFormat.speed(null), '—');
      expect(HibikiByteFormat.speed(-1), '—');
      expect(HibikiByteFormat.speed(double.infinity), '—');
      expect(HibikiByteFormat.speed(double.nan), '—');
    });

    test('速率 = bytes 文案 + /s 后缀', () {
      expect(HibikiByteFormat.speed(1536), '1.5 KB/s');
      expect(HibikiByteFormat.speed(0), '0 B/s');
    });
  });
}
