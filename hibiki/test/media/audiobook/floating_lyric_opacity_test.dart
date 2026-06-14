import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';

void main() {
  // TODO-370: 悬浮字幕「文字 / 按钮底色透明度」自定义。两值都是 0..100 百分比，作用于
  // 基础 ARGB 的 alpha 通道；100 = 保持各表面历史观感（默认），调小变更透明。app 级与
  // reader 级两个样式构造点共用 FloatingLyricStyle.scaleAlpha 这唯一实现。
  group('FloatingLyricStyle.scaleAlpha', () {
    test('100% keeps the original alpha (default = unchanged look)', () {
      expect(FloatingLyricStyle.scaleAlpha(0xFF112233, 100), 0xFF112233);
      // 按钮底色基础 alpha 各主题不同（深色 0x33 / 浅色 0x1A），100% 都保持原样。
      expect(FloatingLyricStyle.scaleAlpha(0x33FFFFFF, 100), 0x33FFFFFF);
      expect(FloatingLyricStyle.scaleAlpha(0x1A000000, 100), 0x1A000000);
    });

    test('0% drops alpha to fully transparent, RGB preserved', () {
      expect(FloatingLyricStyle.scaleAlpha(0xFF112233, 0), 0x00112233);
    });

    test('50% halves the base alpha', () {
      // 0xFF (255) * 0.5 = 127.5 → round 128 = 0x80.
      expect(FloatingLyricStyle.scaleAlpha(0xFF112233, 50), 0x80112233);
      // 0x33 (51) * 0.5 = 25.5 → round 26 = 0x1A.
      expect(FloatingLyricStyle.scaleAlpha(0x33FFFFFF, 50), 0x1AFFFFFF);
    });

    test('clamps out-of-range percentages to 0..100', () {
      expect(FloatingLyricStyle.scaleAlpha(0xFF112233, 200), 0xFF112233);
      expect(FloatingLyricStyle.scaleAlpha(0xFF112233, -10), 0x00112233);
    });
  });
}
