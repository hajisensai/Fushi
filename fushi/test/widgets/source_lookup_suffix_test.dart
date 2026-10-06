import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';

/// BUG-2899：外部入口（截屏识字 / 悬浮字幕点字）报的是原生字符串里的 UTF-16 下标，
/// 源文本条按 trim 后的字素簇渲染、按 [sourceLookupSuffixAt] 取查词后缀。两个换算都是
/// 纯函数，这里钉住它们的边界。
void main() {
  group('sourceGraphemeIndexOfUnit', () {
    test('plain text maps 1:1', () {
      expect(sourceGraphemeIndexOfUnit('今日は良い天気', 5), 5);
    });

    test('leading blanks trimmed by the strip shift the index', () {
      expect(sourceGraphemeIndexOfUnit('  今日は', 3), 1);
      expect(
        sourceGraphemeIndexOfUnit('  今日は', 0),
        0,
        reason: '点在被 trim 掉的空白上钳到首字',
      );
    });

    test('surrogate pairs and combined graphemes count once', () {
      // 𠮷 是代理对（2 个 UTF-16 码元）。
      expect(sourceGraphemeIndexOfUnit('𠮷野家', 1), 0);
      expect(sourceGraphemeIndexOfUnit('𠮷野家', 2), 1);
      // e + U+0301（组合重音符）是一个字素簇。
      final String nfd = 'cafe${String.fromCharCode(0x0301)} noir';
      expect(sourceGraphemeIndexOfUnit(nfd, 4), 3);
      expect(sourceGraphemeIndexOfUnit(nfd, 6), 5);
    });

    test('out of range clamps to the last glyph; blank is -1', () {
      expect(sourceGraphemeIndexOfUnit('天気', 99), 1);
      expect(sourceGraphemeIndexOfUnit('   ', 0), -1);
    });
  });

  group('sourceLookupSuffixAt', () {
    test('suffix starts at the tapped glyph for CJK', () {
      final ({String suffix, int start})? scan = sourceLookupSuffixAt(
        '今日は良い天気',
        5,
      );
      expect(scan?.suffix, '天気');
      expect(scan?.start, 5);
    });

    test('latin words back up to the word start', () {
      final ({String suffix, int start})? scan = sourceLookupSuffixAt(
        'hello world',
        8,
      );
      expect(scan?.suffix, 'world');
      expect(scan?.start, 6);
    });

    test('out of range returns null', () {
      expect(sourceLookupSuffixAt('天気', 2), isNull);
      expect(sourceLookupSuffixAt('天気', -1), isNull);
    });

    test('suffix never exceeds the lookup input cap', () {
      final String long = 'あ' * (kMaxLookupInputChars + 50);
      expect(sourceLookupSuffixAt(long, kMaxLookupInputChars), isNull);
      expect(
        sourceLookupSuffixAt(long, 0)?.suffix.length,
        kMaxLookupInputChars,
      );
    });
  });
}
