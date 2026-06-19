import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show
        ChapterProgressTarget,
        isValidFontData,
        readerColorToCssRgba,
        resolveChapterProgressForGlobalOffset;

/// TODO-575 批1: 阅读器 god 文件凿出的三个纯函数的真行为测（替换脆弱源码扫描）。
/// 三个不变量：
///  1. readerColorToCssRgba —— 5 处 rgba 生成统一后的契约（通道 clamp、alpha 默认
///     用 c.a、override 钉死硬编码）。
///  2. isValidFontData —— 字体容器魔数表。
///  3. resolveChapterProgressForGlobalOffset —— 全局字符偏移→(章, 章内进度) 查表，
///     含退出再进位置往返不动点。
void main() {
  group('readerColorToCssRgba', () {
    test('默认 alpha 用 c.a，通道四舍五入到 0-255', () {
      // 纯红、不透明：r=1.0→255, g=b=0→0, a=1.0→"1.00"。
      const Color red = Color.from(alpha: 1.0, red: 1.0, green: 0.0, blue: 0.0);
      expect(readerColorToCssRgba(red), 'rgba(255,0,0,1.00)');
    });

    test('小数 alpha 用 toStringAsFixed(2)', () {
      const Color semi =
          Color.from(alpha: 0.5, red: 0.0, green: 0.0, blue: 0.0);
      expect(readerColorToCssRgba(semi), 'rgba(0,0,0,0.50)');
    });

    test('通道四舍五入：0.5 → round 到最近偶/远（Dart round 向远离零）', () {
      // 0.5*255 = 127.5 → round() = 128（Dart double.round 半值向远离零）。
      const Color mid = Color.from(alpha: 1.0, red: 0.5, green: 0.5, blue: 0.5);
      expect(readerColorToCssRgba(mid), 'rgba(128,128,128,1.00)');
    });

    test('alphaOverride 钉死 0.98（caret 焦点环契约），忽略 c.a', () {
      // c.a=0.3 必须被 override 0.98 顶掉。
      const Color accent =
          Color.from(alpha: 0.3, red: 1.0, green: 1.0, blue: 0.0);
      expect(
        readerColorToCssRgba(accent, alphaOverride: 0.98),
        'rgba(255,255,0,0.98)',
      );
    });

    test('alphaOverride 钉死 0.34（custom 高亮契约），忽略 c.a', () {
      const Color primary =
          Color.from(alpha: 1.0, red: 0.0, green: 0.0, blue: 1.0);
      expect(
        readerColorToCssRgba(primary, alphaOverride: 0.34),
        'rgba(0,0,255,0.34)',
      );
    });

    test('通道 clamp 上界：>1.0 的越界通道夹到 255（安全网）', () {
      // 越界值理论不出现，但 clamp 是统一契约：保证不产出 >255 的脏值。
      const Color over =
          Color.from(alpha: 1.0, red: 2.0, green: -1.0, blue: 0.5);
      expect(readerColorToCssRgba(over), 'rgba(255,0,128,1.00)');
    });

    test('旧 caret 内联与新 override 等价（合法 0-1 通道下 clamp 不改变结果）', () {
      // 旧 caret 不 clamp：rgba(round(r*255),...,0.98)。合法 [0,1] 通道下，
      // clamp(0,255) 是恒等操作 → 与新 override 版逐字符一致。
      const Color accent =
          Color.from(alpha: 1.0, red: 0.2, green: 0.4, blue: 0.6);
      final String legacy =
          'rgba(${(accent.r * 255).round()},${(accent.g * 255).round()},'
          '${(accent.b * 255).round()},0.98)';
      expect(readerColorToCssRgba(accent, alphaOverride: 0.98), legacy);
    });

    test('旧歌词闭包内联与新默认版等价（合法通道）', () {
      const Color c = Color.from(alpha: 0.87, red: 0.1, green: 0.9, blue: 0.3);
      final String legacy =
          'rgba(${(c.r * 255).round()},${(c.g * 255).round()},'
          '${(c.b * 255).round()},${c.a.toStringAsFixed(2)})';
      expect(readerColorToCssRgba(c), legacy);
    });
  });

  group('isValidFontData', () {
    Uint8List sig(int b0, int b1, int b2, int b3,
            [List<int> rest = const []]) =>
        Uint8List.fromList(<int>[b0, b1, b2, b3, ...rest]);

    test('TrueType 0x00010000 通过', () {
      expect(isValidFontData(sig(0x00, 0x01, 0x00, 0x00)), isTrue);
    });

    test('OpenType-CFF "OTTO" 通过', () {
      expect(isValidFontData(sig(0x4F, 0x54, 0x54, 0x4F)), isTrue);
    });

    test('WOFF "wOFF" 通过', () {
      expect(isValidFontData(sig(0x77, 0x4F, 0x46, 0x46)), isTrue);
    });

    test('WOFF2 "wOF2" 通过', () {
      expect(isValidFontData(sig(0x77, 0x4F, 0x46, 0x32)), isTrue);
    });

    test('TTC "ttcf" 通过', () {
      expect(isValidFontData(sig(0x74, 0x74, 0x63, 0x66)), isTrue);
    });

    test('魔数后跟随真实文件体仍通过（只看头 4 字节）', () {
      expect(
        isValidFontData(sig(0x00, 0x01, 0x00, 0x00, <int>[0xDE, 0xAD, 0xBE])),
        isTrue,
      );
    });

    test('非字体魔数（如 PNG 头）拒绝', () {
      expect(isValidFontData(sig(0x89, 0x50, 0x4E, 0x47)), isFalse);
    });

    test('零字节头拒绝', () {
      expect(isValidFontData(sig(0x00, 0x00, 0x00, 0x00)), isFalse);
    });

    test('少于 4 字节拒绝（边界）', () {
      expect(isValidFontData(Uint8List.fromList(<int>[])), isFalse);
      expect(isValidFontData(Uint8List.fromList(<int>[0x00])), isFalse);
      expect(
        isValidFontData(Uint8List.fromList(<int>[0x00, 0x01, 0x00])),
        isFalse,
      );
    });
  });

  group('resolveChapterProgressForGlobalOffset', () {
    // 三章书：长度 [100, 200, 50]，累积起始 [0, 100, 300]，总 350。
    const List<int> charCounts = <int>[100, 200, 50];
    const List<int> cumulative = <int>[0, 100, 300];

    test('空表 → (0, 0)', () {
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(<int>[], <int>[], 42);
      expect(t.chapter, 0);
      expect(t.progress, 0.0);
    });

    test('章首 offset → 该章 progress 0', () {
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(cumulative, charCounts, 100);
      expect(t.chapter, 1);
      expect(t.progress, 0.0);
    });

    test('章中 offset → 比例进度', () {
      // 第 1 章起始 100、长 200，offset 200 → (200-100)/200 = 0.5。
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(cumulative, charCounts, 200);
      expect(t.chapter, 1);
      expect(t.progress, closeTo(0.5, 1e-9));
    });

    test('第一章内', () {
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(cumulative, charCounts, 25);
      expect(t.chapter, 0);
      expect(t.progress, closeTo(0.25, 1e-9));
    });

    test('落在最后一章', () {
      // 第 2 章起始 300、长 50，offset 325 → (325-300)/50 = 0.5。
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(cumulative, charCounts, 325);
      expect(t.chapter, 2);
      expect(t.progress, closeTo(0.5, 1e-9));
    });

    test('offset 超过总字数 → 钳在最后一章、progress clamp 到 1', () {
      // offset 9999 → 最后一章 (9999-300)/50 = 193.98 → clamp 1.0。
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(cumulative, charCounts, 9999);
      expect(t.chapter, 2);
      expect(t.progress, 1.0);
    });

    test('负 offset → 第 0 章、progress clamp 到 0', () {
      // 0 章起始 0、长 100，offset -5 → (-5)/100 = -0.05 → clamp 0.0。
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(cumulative, charCounts, -5);
      expect(t.chapter, 0);
      expect(t.progress, 0.0);
    });

    test('零长章节 → progress 0（不除零）', () {
      const List<int> counts = <int>[0, 100];
      const List<int> cum = <int>[0, 0];
      // 两章累积都从 0 起：offset 0 命中最后一个 <=0 的章（索引 1），长 100。
      final ChapterProgressTarget t =
          resolveChapterProgressForGlobalOffset(cum, counts, 0);
      expect(t.chapter, 1);
      expect(t.progress, 0.0);
    });

    test('退出再进位置往返不动点：absolutePos → resolve → 同章同进度', () {
      // 模拟 _absoluteCharPosition：在第 1 章、章内进度 0.5 时退出。
      // absolutePos = cumulative[1] + round(0.5 * charCounts[1]) = 100 + 100 = 200。
      const int currentChapter = 1;
      const double savedProgress = 0.5;
      final int absolutePos = cumulative[currentChapter] +
          (savedProgress * charCounts[currentChapter]).round();
      // 重新进入：resolve(absolutePos) 必须回到同一章、同一进度（不动点）。
      final ChapterProgressTarget t = resolveChapterProgressForGlobalOffset(
          cumulative, charCounts, absolutePos);
      expect(t.chapter, currentChapter);
      expect(t.progress, closeTo(savedProgress, 1e-9));
    });

    test('往返不动点（首章 0.25 + 末章 0.8）', () {
      for (final (int ch, double prog) in <(int, double)>[
        (0, 0.25),
        (2, 0.8),
      ]) {
        final int absolutePos =
            cumulative[ch] + (prog * charCounts[ch]).round();
        final ChapterProgressTarget t = resolveChapterProgressForGlobalOffset(
            cumulative, charCounts, absolutePos);
        expect(t.chapter, ch);
        expect(t.progress, closeTo(prog, 0.02), reason: '章 $ch 进度 $prog 往返失真');
      }
    });
  });
}
