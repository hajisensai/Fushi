// BUG-2538：ASS `\p` 矢量绘图曾被解析器整条丢弃——绘图正文不进 plainText 是对的
// （TODO-799），但丢完后 plainText 为空、整条 Dialogue 被 `continue` 跳过，招牌的白底
// 遮罩（`{\1c&HFFFFFF&\p1}m 0 0 l ...`）在 Fushi 里根本不存在，被遮的原文透出来、手写
// 字看着糊成一团。本组钉死：绘图命令解析成归一化路径 + 包围盒 + 样式快照；只有播放
// 路径（includeDrawings）才把它当 cue 产出。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

const String _kHead = r'''
[Script Info]
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
Style: Sign,Arial,40,&H00000000,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

const String _kMask =
    r'Dialogue: 0,0:00:01.00,0:00:04.00,Sign,,0,0,0,,{\an7\pos(100,50)\1c&HFFFFFF&\p1}m 0 0 l 200 0 200 100 0 100{\p0}';
const String _kLine =
    r'Dialogue: 1,0:00:01.00,0:00:04.00,Default,,0,0,0,,That is why.';

void main() {
  group('parseSubtitleMarkup：\\p 绘图', () {
    test('绘图命令 → 归一化路径 + 包围盒；正文不进 plainText', () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\an7\pos(100,50)\1c&HFFFFFF&\p1}m 0 0 l 200 0 200 100 0 100{\p0}',
        playResX: 1280,
        playResY: 720,
      );
      expect(m.plainText, isEmpty, reason: '坐标串不是文字（TODO-799 不回退）');
      final SubtitleDrawing d = m.drawing!;
      expect(d.segments.first.op, SubtitleClipOp.move);
      expect(d.segments, hasLength(4));
      expect(d.minX, closeTo(0, 1e-9));
      expect(d.maxX, closeTo(200 / 1280, 1e-9));
      expect(d.maxY, closeTo(100 / 720, 1e-9));
      expect(d.widthFraction * 1280, closeTo(200, 1e-6));
      expect(d.heightFraction * 720, closeTo(100, 1e-6));
      // 样式快照：\1c 白填充挂在 drawingStyle 上（grapheme 区间为空）。
      expect(m.drawingStyle!.colorArgb, 0xFFFFFFFF);
      expect(m.drawingStyle!.startGrapheme, 0);
      expect(m.drawingStyle!.endGrapheme, 0);
      expect(m.posFraction!.xFraction, closeTo(100 / 1280, 1e-9));
    });

    test('\\p2 坐标除以 2^(n-1)；\\pbo 记为基线偏移', () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\p2\pbo10}m 0 0 l 400 0 400 200 0 200',
        playResX: 1280,
        playResY: 720,
      );
      final SubtitleDrawing d = m.drawing!;
      expect(d.maxX * 1280, closeTo(200, 1e-6), reason: '400 ÷ 2 = 200');
      expect(d.maxY * 720, closeTo(100, 1e-6));
      expect(d.baselineOffsetFraction * 720, closeTo(5, 1e-6),
          reason: '\\pbo 与坐标同用绘图单位（÷2）');
    });

    test('贝塞尔 b 命令进包围盒；包围盒偏离原点时 min 不为 0', () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\p1}m 100 100 b 150 50 250 50 300 100 l 300 200 100 200',
        playResX: 1280,
        playResY: 720,
      );
      final SubtitleDrawing d = m.drawing!;
      expect(d.minX * 1280, closeTo(100, 1e-6));
      expect(d.minY * 720, closeTo(50, 1e-6), reason: '控制点参与包围盒');
      expect(d.segments.any((s) => s.op == SubtitleClipOp.cubic), isTrue);
    });

    test('绘图后接文字：文字照常成 plainText，绘图也保留', () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\p1}m 0 0 l 10 0 10 10{\p0}あ',
        playResX: 1280,
        playResY: 720,
      );
      expect(m.plainText, 'あ');
      expect(m.drawing, isNotNull);
    });

    test('无 PlayRes（srt/vtt）或空命令串 → drawing 为 null', () {
      expect(parseSubtitleMarkup(r'{\p1}m 0 0 l 1 1').drawing, isNull);
      expect(
          parseSubtitleMarkup(r'{\p1}{\p0}あ', playResX: 100, playResY: 100)
              .drawing,
          isNull);
      expect(
          parseSubtitleMarkup(r'{\p1}l 0 0 1 1', playResX: 100, playResY: 100)
              .drawing,
          isNull,
          reason: '首命令不是 m 视为非法');
    });
  });

  group('AssParser.parseString(includeDrawings)', () {
    test('默认不产出无正文的绘图事件（字幕列表 / 制卡 / 落库不见空行）', () {
      final List<AudioCue> cues =
          AssParser.parseString(content: '$_kHead$_kMask\n$_kLine\n', bookKey: 'b');
      expect(cues.map((c) => c.text), <String>['That is why.']);
    });

    test('includeDrawings:true 产出绘图 cue：text 空、isRenderOnly、markup.drawing 非空', () {
      final List<AudioCue> cues = AssParser.parseString(
          content: '$_kHead$_kMask\n$_kLine\n',
          bookKey: 'b',
          includeDrawings: true);
      expect(cues, hasLength(2));
      final AudioCue mask = cues.firstWhere((c) => c.text.isEmpty);
      expect(mask.isRenderOnly, isTrue);
      expect(mask.markup!.drawing, isNotNull);
      expect(mask.markup!.layer, 0);
      expect(cues.firstWhere((c) => c.text.isNotEmpty).isRenderOnly, isFalse);
    });

    test('同一起始时间按文件序稳定排序（z 序依赖它，BUG-2539）', () {
      final StringBuffer sb = StringBuffer(_kHead);
      for (int i = 0; i < 40; i++) {
        sb.writeln('Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,L$i');
      }
      final List<AudioCue> cues =
          AssParser.parseString(content: sb.toString(), bookKey: 'b');
      expect(cues.map((c) => c.text).toList(),
          List<String>.generate(40, (int i) => 'L$i'));
      expect(cues.map((c) => c.sentenceIndex).toList(),
          List<int>.generate(40, (int i) => i));
    });
  });
}
