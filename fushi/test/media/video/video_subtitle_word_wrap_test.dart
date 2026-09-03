import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(String text) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'ch'
    ..sentenceIndex = 0
    ..textFragmentId = '#s1'
    ..text = text
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

VideoPlayerController _controllerWithCue(String text) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[_cue(text)]);
  c.debugUpdateCueForPosition(100);
  return c;
}

/// 固定宽度容器里 pump overlay：宽度不足放整行时必须发生软换行。
/// 测试字体（FlutterTest/Ahem 类）每个字形 advance = fontSize，几何确定。
Future<void> _pumpConstrained(
  WidgetTester tester,
  String text, {
  required double width,
  double fontSize = 20,
}) async {
  final VideoPlayerController c = _controllerWithCue(text);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: 600,
          child: VideoSubtitleOverlay(controller: c, fontSize: fontSize),
        ),
      ),
    ),
  ));
  await tester.pump();
}

/// 按渲染几何重建可视行：收集 overlay 下所有单字符 Text 的全局 topLeft，
/// 按 dy 分行（同行顶对齐、行距 >= 字号，容差 1px）、行内按 dx 排序拼接。
List<String> _visualLines(WidgetTester tester) {
  final Iterable<Element> elements = find
      .descendant(
          of: find.byType(VideoSubtitleOverlay), matching: find.byType(Text))
      .evaluate();
  final List<({double dy, double dx, String ch})> glyphs =
      <({double dy, double dx, String ch})>[];
  for (final Element e in elements) {
    final Text t = e.widget as Text;
    final String? s = t.data;
    if (s == null || s.isEmpty) continue;
    final RenderObject? ro = e.renderObject;
    if (ro is! RenderBox || !ro.hasSize) continue;
    final Offset p = ro.localToGlobal(Offset.zero);
    glyphs.add((dy: p.dy, dx: p.dx, ch: s));
  }
  glyphs.sort((a, b) {
    final int byY = a.dy.compareTo(b.dy);
    return byY != 0 ? byY : a.dx.compareTo(b.dx);
  });
  final List<String> lines = <String>[];
  double? lineY;
  StringBuffer buf = StringBuffer();
  for (final ({double dy, double dx, String ch}) g in glyphs) {
    if (lineY == null || (g.dy - lineY).abs() > 1.0) {
      if (buf.isNotEmpty) lines.add(buf.toString());
      buf = StringBuffer();
      lineY = g.dy;
    }
    buf.write(g.ch);
  }
  if (buf.isNotEmpty) lines.add(buf.toString());
  return lines;
}

/// 把 [text] 逐 grapheme 分组后映射回子串，便于断言可读。
List<String> _groupStrings(String text) {
  final List<String> chars = text.characters.toList(growable: false);
  final List<int> indices =
      List<int>.generate(chars.length, (int i) => i, growable: false);
  return groupSubtitleGraphemesForWrap(chars, indices)
      .map((List<int> g) => g.map((int i) => chars[i]).join())
      .toList(growable: false);
}

void main() {
  group('BUG-1730 字幕软换行不得在英文单词中间断行', () {
    testWidgets('拉丁句：容器放不下整行但放得下每个单词 → 断行只发生在空格处', (WidgetTester tester) async {
      const String text = 'hello world again';
      // 20px/字形 × 17 字符 = 340px 整行；容器 200px 放不下整行，
      // 最长单词 5 字符 = 100px + 盒内边距 24px 放得下 → 必须按词断。
      await _pumpConstrained(tester, text, width: 200);

      final List<String> lines = _visualLines(tester);
      expect(lines.length, greaterThan(1), reason: '用例前提：容器宽不足放整行，必须发生软换行');
      // 每行去掉行尾附着空格后必须是完整单词的串接——拼回的词序列与原句逐词一致。
      // 修复前逐字符 Wrap 会给出 hello wo / rld agai / n 这类中词断行。
      final List<String> reassembled = <String>[];
      for (final String line in lines) {
        final String trimmed = line.trim();
        expect(trimmed, isNotEmpty);
        reassembled.addAll(trimmed.split(' '));
      }
      expect(reassembled, text.split(' '), reason: '断行只能发生在空格处，单词不得被拆开');
    });

    testWidgets('CJK 句：无空格仍逐字可断（≈libass WrapStyle 1）',
        (WidgetTester tester) async {
      const String text = 'こんにちは世界です';
      // 20px × 9 字 = 180px；容器 110px（可用 ~86px = 4 字）→ 至少 3 行。
      await _pumpConstrained(tester, text, width: 110);

      final List<String> lines = _visualLines(tester);
      expect(lines.length, greaterThan(1),
          reason: 'CJK 无空格行必须仍能逐字断行，不得因分组退化成整行溢出');
      expect(lines.join(), text, reason: '所有字符按原顺序在场');
    });
  });

  group('BUG-1730 groupSubtitleGraphemesForWrap 分组规则', () {
    test('拉丁词整组、空格附着前词尾部', () {
      expect(_groupStrings('hello world'), <String>['hello ', 'world']);
    });

    test('词内标点（撇号/连字符）不拆词', () {
      expect(_groupStrings("it's state-of-art"),
          <String>["it's ", 'state-of-art']);
    });

    test('CJK 逐字成组，混排时拉丁词仍整组', () {
      expect(_groupStrings('見るwatch中'), <String>['見', 'る', 'watch', '中']);
    });

    test('CJK 后的空格并进前一组尾部，不产生行首空格组', () {
      expect(_groupStrings('中 は'), <String>['中 ', 'は']);
    });

    test('连续空格全部附着在前词尾部', () {
      expect(_groupStrings('ab  cd'), <String>['ab  ', 'cd']);
    });

    test('不间断空格 NBSP 视为词内字符，不产生断行机会', () {
      expect(_groupStrings('a\u00A0b'), <String>['a\u00A0b']);
    });

    test('行首空格自成组（无前组可附着，与改前行为一致）', () {
      expect(_groupStrings(' ab'), <String>[' ', 'ab']);
    });
  });
}
