import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-833 守卫：多层卡拉 OK（同句歌词按 ASS Layer 拆成光晕/主文字/点缀三条 Dialogue）
/// 必须**同位叠画成一行**，而不是竖排堆叠成「三个字幕」；`\clip`/`\iclip` 走真矢量裁剪
/// （ClipPath），点缀层只在小块路径内露色、iclip 挖孔。
///
/// libass 语义：碰撞（竖排避让）只发生在同层事件之间，不同层各按自带位置叠画。
/// 真实样本（Kamiina Botan S01E07 OP）：
/// - Layer 3「shadow」：`\bord5\blur10\1a&HFF&`——填充全透明，只剩模糊描边=辉光；
/// - Layer 4 主文字：`\iclip(...)`（挖掉小块装饰区）；
/// - Layer 5「color」：`\c&H..&\clip(...)`——点缀色只在小块路径内露出。
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
  test(r'parser captures Layer / \1a fill opacity / \clip objects', () {
    final List<AudioCue> cues =
        AssParser.parseString(content: _kAss, bookKey: 'k');
    expect(cues, hasLength(3));
    expect(cues.map((c) => c.markup!.layer).toList(), <int>[3, 4, 5]);
    // \1a&HFF& → 填充全透明。
    expect(cues[0].markup!.spans.single.fillOpacity, closeTo(0.0, 0.001));
    // \iclip / \clip 都解析成 SubtitleClip（inverse 区分挖孔与裁剪）。
    expect(cues[0].markup!.clip, isNull);
    expect(cues[1].markup!.clip!.inverse, isTrue);
    expect(cues[2].markup!.clip!.inverse, isFalse);
    expect(cues[2].markup!.clip!.segments.first.op, SubtitleClipOp.move);
    // 坐标按 PlayRes 归一化。
    expect(cues[2].markup!.clip!.segments.first.x1, closeTo(571 / 1920, 1e-6));
  });

  test(r'parseAssClip rect / scale-drawing / bezier forms', () {
    final SubtitleClip rect = parseAssClip(
        inverse: false, inner: '0,0,960,540', playResX: 1920, playResY: 1080)!;
    expect(rect.segments, hasLength(4));
    expect(rect.segments[2].x1, closeTo(0.5, 1e-6));
    expect(rect.segments[2].y1, closeTo(0.5, 1e-6));

    // scale=2 变体：坐标除以 2^(2-1)=2。
    final SubtitleClip scaled = parseAssClip(
        inverse: false,
        inner: '2,m 192 108 l 384 108',
        playResX: 1920,
        playResY: 1080)!;
    expect(scaled.segments.first.x1, closeTo(192 / 2 / 1920, 1e-6));

    // 贝塞尔 b：三控制点。
    final SubtitleClip bez = parseAssClip(
        inverse: true,
        inner: 'm 0 0 b 10 0 10 10 0 10',
        playResX: 100,
        playResY: 100)!;
    expect(bez.inverse, isTrue);
    expect(bez.segments[1].op, SubtitleClipOp.cubic);
    expect(bez.segments[1].x3, closeTo(0.0, 1e-6));
    expect(bez.segments[1].y3, closeTo(0.1, 1e-6));

    // 垃圾输入 → null。
    expect(
        parseAssClip(
            inverse: false, inner: 'l 1 2', playResX: 100, playResY: 100),
        isNull);
  });

  testWidgets('layered karaoke copies overlap in place with real ClipPath',
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

    // 真 \clip 裁剪后三层全渲染（shadow + 主文字 + 点缀），点缀被 ClipPath 限制。
    final List<Element> fills = find
        .byWidgetPredicate((Widget w) =>
            w is Text && w.data == 'め' && w.style?.foreground == null)
        .evaluate()
        .toList();
    expect(fills, hasLength(3), reason: '三层（含裁剪点缀层）都应渲染');

    // \clip 与 \iclip 各挂一个 ClipPath（真矢量裁剪）。
    expect(
      find.descendant(
          of: find.byType(VideoSubtitleOverlay),
          matching: find.byType(ClipPath)),
      findsNWidgets(2),
    );

    // 三份拷贝必须**同位叠画**（同 top），不是竖排三行。
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
