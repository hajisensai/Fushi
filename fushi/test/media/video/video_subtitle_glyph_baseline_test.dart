// 反馈 qMZ00M6ESi「字幕假名和文字没对齐」：字幕逐字 Text 顶对齐排行，汉字与假名
// 落到不同字体时各自的 ascent 比例不同，基线错位。修复：逐字 Text 一律挂强制
// strut（subtitleGlyphStrut），同字号的字共用 strut 字体的基线。
//
// 用两套 ascent 比例确实不同的真字体复现：主字体是仓库内 vendored 的 Noto Sans
// （只有拉丁），另一个字符只存在于回退链上的第二套字体里（测试环境没有 CJK 字体，
// 借仓库内图标字体的私用区码位，并以字幕回退链里的族名 `Noto Sans CJK JP` 注册）——
// 与 Android 上「OEM 字体只覆盖一部分字符、其余按字符各自回退到另一套字体」同构。
// 两套字体的 ascent/(ascent+descent) 分别约 0.785 / 0.917。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:material_ui/material_ui.dart';

const String _kLatinFamily = 'SubtitleBaselineLatin';

/// 字幕回退链（[subtitleCjkFontFallbacks]，非 Windows）里的族名。
const String _kFallbackFamily = 'Noto Sans CJK JP';

/// 只存在于回退字体里的字符（FushiSymbolsRounded 私用区码位，Noto Sans 无此字）。
const String _kFallbackChar = '\uE00D';

VideoPlayerController _stubWithText(String text) {
  final AudioCue cue = AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = text
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[cue]);
  c.debugUpdateCueForPosition(1);
  return c;
}

/// 字形 [Text] 渲染出的段落基线（全局 y）。
double _baselineY(WidgetTester tester, Finder textFinder) {
  final RenderParagraph rp = tester.renderObject<RenderParagraph>(
    find.descendant(of: textFinder, matching: find.byType(RichText)).first,
  );
  final double dist = rp.getDryBaseline(
    rp.constraints,
    TextBaseline.alphabetic,
  )!;
  return rp.localToGlobal(Offset(0, dist)).dy;
}

void main() {
  setUpAll(() async {
    final Uint8List bytes = File(
      '../third_party/m_extension_server/upstream_src/AndroidCompat/src/main/'
      'resources/font/NotoSans/NotoSans-VariableFont_wdth,wght.ttf',
    ).readAsBytesSync();
    final FontLoader loader = FontLoader(_kLatinFamily)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    final Uint8List fallbackBytes = File(
      'assets/icon_fonts/FushiSymbolsRounded.ttf',
    ).readAsBytesSync();
    final FontLoader fallbackLoader = FontLoader(_kFallbackFamily)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(fallbackBytes)));
    await fallbackLoader.load();
  });

  test('subtitleGlyphStrut forces the line box from the glyph style', () {
    const TextStyle style = TextStyle(
      fontFamily: 'X',
      fontFamilyFallback: <String>['Y', 'Z'],
      fontSize: 40,
      height: kVideoSubtitleLineHeight,
      fontWeight: FontWeight.w700,
    );
    final StrutStyle strut = subtitleGlyphStrut(style);
    expect(strut.forceStrutHeight, isTrue);
    expect(strut.fontFamily, 'X');
    expect(strut.fontFamilyFallback, <String>['Y', 'Z']);
    expect(strut.fontSize, 40);
    expect(strut.height, kVideoSubtitleLineHeight);
    expect(strut.fontWeight, FontWeight.w700);
  });

  testWidgets(
    'precondition: without a strut, glyphs from two fonts sit on different '
    'baselines when top-aligned',
    (WidgetTester tester) async {
      // 证明本环境里两套字体的 ascent 比例确实不同——否则下面的对齐断言是空壳。
      const TextStyle style = TextStyle(
        fontFamily: _kLatinFamily,
        fontFamilyFallback: <String>[_kFallbackFamily],
        fontSize: 40,
        height: kVideoSubtitleLineHeight,
      );
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('A', style: style),
                Text(_kFallbackChar, style: style),
              ],
            ),
          ),
        ),
      );
      final double a = _baselineY(tester, find.text('A'));
      final double other = _baselineY(tester, find.text(_kFallbackChar));
      expect((a - other).abs(), greaterThan(1.0));
    },
  );

  testWidgets(
    'subtitle glyphs falling back to different fonts share one baseline '
    '(qMZ00M6ESi)',
    (WidgetTester tester) async {
      final VideoPlayerController c = _stubWithText('A${_kFallbackChar}B');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoSubtitleOverlay(
              controller: c,
              fontFamily: _kLatinFamily,
              fontSize: 40,
            ),
          ),
        ),
      );
      await tester.pump();

      final double a = _baselineY(tester, find.text('A').first);
      final double other = _baselineY(tester, find.text(_kFallbackChar).first);
      final double b = _baselineY(tester, find.text('B').first);
      expect(other, moreOrLessEquals(a, epsilon: 0.01));
      expect(b, moreOrLessEquals(a, epsilon: 0.01));

      // 每个字形 Text 都挂了强制 strut（含描边/填充分层的任何一层）。
      final Iterable<Text> glyphs = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(VideoSubtitleOverlay),
              matching: find.byType(Text),
            ),
          )
          .where(
            (Text t) => <String>{'A', _kFallbackChar, 'B'}.contains(t.data),
          );
      expect(glyphs, isNotEmpty);
      for (final Text t in glyphs) {
        expect(
          t.strutStyle?.forceStrutHeight,
          isTrue,
          reason: 'glyph "${t.data}" must carry the forced subtitle strut',
        );
      }
    },
  );
}
