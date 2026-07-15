import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG 守卫：多层卡拉 OK（同句歌词按 ASS Layer 拆成光晕/主文字/点缀三条 Dialogue）
/// 必须**同位叠画成一行**，而不是竖排堆叠成「三个字幕」。
///
/// libass 语义：碰撞（竖排避让）只发生在同层事件之间，不同层各按自带位置叠画。
/// 真实样本（Kamiina Botan S01E07 OP）：
/// - Layer 3「shadow」：`\bord5\blur10\1a&HFF&`——填充全透明，只剩模糊描边=辉光；
/// - Layer 4 主文字：`\iclip(...)`（挖掉小块，忽略近似=画全部）；
/// - Layer 5「color」：`\c&H..&\clip(...)`——点缀色只在小块路径内露出，真裁剪不支持
///   时画全条是错的 → 有同文本兄弟层时整条丢弃。
const String _kAss = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: OP - JP,A-OTF A1 Mincho Std Bold,65,&H001A1A1A,&H000000FF,&H00FFFFFF,&H00000000,0,0,0,0,100,100,1.99999,0,1,0,0,8,11,11,14,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 3,0:00:01.00,0:00:05.00,OP - JP,shadow,0,0,0,,{\bord5\blur10\1a&HFF&}めいっぱい
Dialogue: 4,0:00:01.00,0:00:05.00,OP - JP,,0,0,0,,{\iclip(m 571 46 l 573 51 552 34)}めいっぱい
Dialogue: 5,0:00:01.00,0:00:05.00,OP - JP,color,0,0,0,,{\c&H5659FF&\clip(m 571 46 l 573 51 552 34)}めいっぱい
''';

void main() {
  test(r'parser captures Layer / a fill opacity / \clip flag', () {
    final List<AudioCue> cues =
        AssParser.parseString(content: _kAss, bookKey: 'k');
    expect(cues, hasLength(3));
    expect(cues.map((c) => c.markup!.layer).toList(), <int>[3, 4, 5]);
    // \1a&HFF& → 填充全透明。
    expect(cues[0].markup!.spans.single.fillOpacity, closeTo(0.0, 0.001));
    // \iclip 不置 hasClip（画全部近似）；\clip 置位。
    expect(cues[1].markup!.hasClip, isFalse);
    expect(cues[2].markup!.hasClip, isTrue);
  });

  testWidgets('layered karaoke copies overlap in place; clip accent dropped',
      (WidgetTester tester) async {
    final List<AudioCue> cues =
        AssParser.parseString(content: _kAss, bookKey: 'k');
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(cues);
    c.debugUpdateCueForPosition(2000); // 三层同刻活跃
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ));
    await tester.pump();

    // fill 层拷贝：\clip 点缀层被丢弃 → 只剩 shadow + 主文字两份。
    final List<Element> fills = find
        .byWidgetPredicate((Widget w) =>
            w is Text && w.data == 'め' && w.style?.foreground == null)
        .evaluate()
        .toList();
    expect(fills, hasLength(2), reason: r'\clip 点缀拷贝必须丢弃（真裁剪不支持时画全条=错色）');

    // 两份拷贝必须**同位叠画**（同 top），不是竖排两行。
    final Set<String> tops = <String>{
      for (final Element e in fills)
        tester
            .getRect(find.byElementPredicate((Element x) => x == e))
            .top
            .toStringAsFixed(1),
    };
    expect(tops, hasLength(1), reason: '不同 Layer 的同句拷贝必须同位叠画成一行，不得竖排堆叠');

    // 光晕层填充全透明（\1a&HFF&）；主文字层不透明。
    final Set<double> alphas = <double>{
      for (final Element e in fills) (e.widget as Text).style!.color!.a,
    };
    expect(alphas.contains(0.0), isTrue, reason: r'\1a&HFF& 填充必须全透明');
    expect(alphas.any((double a) => a > 0.9), isTrue, reason: '主文字层必须不透明');
  });
}
