import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-840 守卫：双语底部对白（日文 + 中文，同为底部锚点、时间重叠，但 `_positionKey` 因
/// **ASS Layer 不同**或 **MarginL/R 不同**把两条拆成两组）不得叠印糊字。libass 语义：同位
/// 不同文本的底部事件竖排避让；同文本的多层拷贝（卡拉OK特效层）才同位叠画。
///
/// 修复前：JP layer0 + CH layer1（都 \an2 底部、MarginV 小）→ 两组各自定位却落在同一
/// `max(bottomPadding, ...)` 基线 → 叠印。修复：文本互异的底部基线折叠组合并成一个堆叠组
/// （竖排分行）；同文本的仍分组同位叠画。
AudioCue _bottomCue(
  String text, {
  double marginV = 0,
  double marginL = 0,
  int layer = 0,
  required double fontSizePx,
}) {
  final SubtitleCueStyle style = SubtitleCueStyle(
    fontSizePx: fontSizePx,
    primaryColorArgb: 0xFFFFFFFF,
    anchor: const SubtitleAnchor(SubtitleVAlign.bottom, SubtitleHAlign.center),
    marginV: marginV,
    marginL: marginL,
  );
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = text
    ..markup = SubtitleMarkup(
      plainText: text,
      spans: const <SubtitleSpan>[],
      anchor:
          const SubtitleAnchor(SubtitleVAlign.bottom, SubtitleHAlign.center),
      cueStyle: style,
      playResY: 720, // 显示区 720 / PlayResY 720 → 缩放 1.0。
      layer: layer,
    )
    ..startMs = 0
    ..endMs = 5000;
}

Rect _fillRect(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
      (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);
  return tester.getRect(fill.first);
}

Set<String> _fillTops(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
      (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);
  return <String>{
    for (final Element e in fill.evaluate())
      tester
          .getRect(find.byElementPredicate((Element x) => x == e))
          .top
          .toStringAsFixed(1),
  };
}

Future<void> _pumpOverlay(WidgetTester tester, VideoPlayerController c) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1280,
        height: 720,
        child: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('双语底部对白跨 Layer（JP layer0 + CH layer1）竖排分行、不叠印',
      (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // 日文贴底一层、中文另一层，都 \an2、MarginV 小（都 < bottomPadding=75）。
    final AudioCue jp = _bottomCue('日', marginV: 4, layer: 0, fontSizePx: 35);
    final AudioCue ch = _bottomCue('中', marginV: 4, layer: 1, fontSizePx: 35);
    c.setCues(<AudioCue>[jp, ch]);
    c.debugUpdateCueForPosition(1000);
    expect(c.activeCues.length, 2);

    await _pumpOverlay(tester, c);

    final Rect jpRect = _fillRect(tester, '日');
    final Rect chRect = _fillRect(tester, '中');
    // 两条竖直不重叠（修复前跨 Layer 拆组、共基线叠印）。
    expect(chRect.bottom, lessThanOrEqualTo(jpRect.top + 0.5),
        reason: '中(上) 底缘应在 日(下) 顶缘之上，两条分离不叠印');
  });

  testWidgets('双语底部对白跨 MarginL（水平边距不同、同为中心锚）竖排分行、不叠印',
      (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    final AudioCue jp = _bottomCue('日', marginV: 4, marginL: 0, fontSizePx: 35);
    final AudioCue ch =
        _bottomCue('中', marginV: 4, marginL: 40, fontSizePx: 35);
    c.setCues(<AudioCue>[jp, ch]);
    c.debugUpdateCueForPosition(1000);
    await _pumpOverlay(tester, c);

    final Rect jpRect = _fillRect(tester, '日');
    final Rect chRect = _fillRect(tester, '中');
    expect(chRect.bottom, lessThanOrEqualTo(jpRect.top + 0.5),
        reason: 'MarginL 各异的底部双语也应竖排避让');
  });

  testWidgets('同文本多层拷贝（卡拉OK特效层）在底部基线仍同位叠画、不被误拆成两行',
      (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // 同句 'め' 拆两层（光晕层 + 主文字层），都 \an2 底部——应同位叠画成一行特效。
    final AudioCue glow = _bottomCue('め', marginV: 4, layer: 3, fontSizePx: 40);
    final AudioCue main = _bottomCue('め', marginV: 4, layer: 4, fontSizePx: 40);
    c.setCues(<AudioCue>[glow, main]);
    c.debugUpdateCueForPosition(1000);
    await _pumpOverlay(tester, c);

    // 两份 'め' 拷贝必须同位叠画（同 top），不得因合并逻辑被竖排成两行。
    expect(_fillTops(tester, 'め'), hasLength(1),
        reason: '同文本的多层拷贝必须同位叠画成一行（BUG-833 不回归）');
  });
}
