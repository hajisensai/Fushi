import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// #2312：双语 SRT / VTT（原文一行 + 译文一行）在屏上并成一排。
///
/// 根因：srt / vtt 解析器把时间行之后的多行文本 `join(' ')`，渲染层只认
/// [SubtitleMarkup.lineBreakGraphemes] 分行，于是作者的行结构在解析时就丢了。
/// 修复：行间以 ASS 硬换行 `\N` 连接交给 markup 解析——plainText 仍是空格（查词 /
/// 制卡 / DB 逐字节不变），渲染层按原行分行。「尊重字幕自带样式」开关两档都要分行。
const String _bilingualSrt =
    '1\n'
    '00:00:00,000 --> 00:00:05,000\n'
    '上行\n'
    '下行\n';

const String _bilingualVtt =
    'WEBVTT\n'
    '\n'
    '00:00:00.000 --> 00:00:05.000\n'
    '上行\n'
    '下行\n';

Future<void> _mount(
  WidgetTester tester,
  VideoPlayerController c, {
  required bool respectAssStyle,
}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1920,
          height: 1080,
          child: VideoSubtitleOverlay(
            controller: c,
            respectAssStyle: respectAssStyle,
            onCharTap: (_, __, ___, ____) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Rect _fillRect(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == ch && w.style?.foreground == null,
  );
  return tester.getRect(fill.first);
}

void main() {
  test('SRT 解析：多行 cue 记录换行下标，plainText 仍以空格连接', () {
    final List<AudioCue> cues = SrtParser.parseString(
      content: _bilingualSrt,
      bookKey: 'b',
    );
    expect(cues.single.text, '上行 下行', reason: 'plainText 与旧的空格连接逐字节一致');
    expect(cues.single.markup!.lineBreakGraphemes, <int>[2]);
  });

  test('VTT 解析：多行 cue 记录换行下标，plainText 仍以空格连接', () {
    final List<AudioCue> cues = VttParser.parseString(
      content: _bilingualVtt,
      bookKey: 'b',
    );
    expect(cues.single.text, '上行 下行');
    expect(cues.single.markup!.lineBreakGraphemes, <int>[2]);
  });

  test('SRT 解析：单行 cue 不产生换行', () {
    final List<AudioCue> cues = SrtParser.parseString(
      content: '1\n00:00:00,000 --> 00:00:05,000\n一行\n',
      bookKey: 'b',
    );
    expect(cues.single.text, '一行');
    expect(cues.single.markup!.lineBreakGraphemes, isEmpty);
  });

  test('SRT 解析：跨行的 HTML 标签照常剥离且保留换行', () {
    final List<AudioCue> cues = SrtParser.parseString(
      content: '1\n00:00:00,000 --> 00:00:05,000\n<i>上行\n下行</i>\n',
      bookKey: 'b',
    );
    expect(cues.single.text, '上行 下行');
    expect(cues.single.markup!.lineBreakGraphemes, <int>[2]);
  });

  for (final bool respect in <bool>[true, false]) {
    testWidgets('渲染（respectAssStyle=$respect）：双语 SRT 两行分行显示', (
      WidgetTester tester,
    ) async {
      final List<AudioCue> cues = SrtParser.parseString(
        content: _bilingualSrt,
        bookKey: 'b',
      );
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(cues);
      await _mount(tester, c, respectAssStyle: respect);
      c.debugUpdateCueForPosition(1000);
      await tester.pump();

      final Rect up = _fillRect(tester, '上');
      final Rect down = _fillRect(tester, '下');
      expect(
        down.top,
        greaterThanOrEqualTo(up.bottom - 1),
        reason: '第二行应换到下一行，不得与第一行并成一排',
      );
      expect(
        (up.left - down.left).abs(),
        lessThan(1),
        reason: '两行各自居中（等宽 → 左缘对齐）',
      );
    });
  }
}
