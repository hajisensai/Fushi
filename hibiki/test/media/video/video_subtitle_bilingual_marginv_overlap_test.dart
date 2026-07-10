import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG 守卫：底部双语对白（同 `\an2`、MarginV 各异但都 <= 用户 bottomPadding）不得塌陷重叠。
///
/// 复现自真实 fansub「双语.ass」的主对白布局：`Dial_JP` MarginV=4 + `Dial_CH` MarginV=30，
/// 两条同为底部锚点、时间重叠。修复前 `_positionKey` 按原始 MarginV 把两条拆成两组，各组底部
/// 基线又被 `_paddingFor` 的 `max(bottomPadding=75, scaledMarginV)` 夹回同一 75px 基线 → 两条
/// 叠印在一起、互相压字，且逐字查词把上面那条的字误判成下面那条（hit-test 命中错 cue）。
/// 修复：底部锚点缩放后 <= bottomPadding 的 MarginV 折进同一基线桶，两条同组竖排堆叠（libass
/// 碰撞下推同效果），并按 MarginV 升序稳定排序（小的贴底、大的在上）。
AudioCue _bottomCue(
  String text, {
  required double marginV,
  required double fontSizePx,
}) {
  final SubtitleCueStyle style = SubtitleCueStyle(
    fontSizePx: fontSizePx,
    primaryColorArgb: 0xFFFFFFFF,
    anchor: const SubtitleAnchor(SubtitleVAlign.bottom, SubtitleHAlign.center),
    marginV: marginV,
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
      playResY: 720, // 显示区 720 / PlayResY 720 → 缩放 1.0，MarginV 直用像素值。
    )
    ..startMs = 0
    ..endMs = 5000;
}

Rect _fillRect(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
      (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);
  return tester.getRect(fill.first);
}

void main() {
  testWidgets('底部双语（\\an2 MarginV 4 + 30，均 < bottomPadding）不重叠、各自可查词',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // JP 小字贴底（MarginV=4），CH 大字在上（MarginV=30）。
    final AudioCue jp = _bottomCue('日', marginV: 4, fontSizePx: 35);
    final AudioCue ch = _bottomCue('中', marginV: 30, fontSizePx: 56);
    c.setCues(<AudioCue>[jp, ch]);
    c.debugUpdateCueForPosition(1000);
    expect(c.activeCues.length, 2, reason: '两条底部对白应同时活动');

    final VideoSubtitleHitTester hitTester = VideoSubtitleHitTester();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: VideoSubtitleOverlay(
            controller: c,
            respectAssStyle: true,
            hitTester: hitTester,
            onCharTap: (_, __, ___) {},
          ),
        ),
      ),
    ));
    await tester.pump();

    // 两条都渲染（各 stroke+fill 双层）。
    expect(find.text('日'), findsNWidgets(2));
    expect(find.text('中'), findsNWidgets(2));

    final Rect jpRect = _fillRect(tester, '日');
    final Rect chRect = _fillRect(tester, '中');

    // 核心：两条竖直方向**不重叠**（修复前共基线、盒相交）。
    expect(chRect.bottom, lessThanOrEqualTo(jpRect.top + 0.5),
        reason: 'CH(上) 底缘应在 JP(下) 顶缘之上，两条分离不叠印');
    // CH（MarginV 大）在 JP 之上。
    expect(chRect.center.dy, lessThan(jpRect.center.dy));

    // 跨 cue 查词：各字命中各自的 cue（修复前点 CH 会误判成 JP）。
    final SubtitleCharHit? jpHit = hitTester.hitTest(jpRect.center);
    final SubtitleCharHit? chHit = hitTester.hitTest(chRect.center);
    expect(jpHit?.sentence, '日');
    expect(chHit?.sentence, '中');
  });

  testWidgets('大 MarginV（超出 bottomPadding）仍各自 authored 高度（TODO-1341 不回归）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // 一条贴底对白（MarginV=10<75），一条高位标题（MarginV=400>75）：仍应分居两处。
    final AudioCue dialog = _bottomCue('白', marginV: 10, fontSizePx: 40);
    final AudioCue title = _bottomCue('題', marginV: 400, fontSizePx: 40);
    c.setCues(<AudioCue>[dialog, title]);
    c.debugUpdateCueForPosition(1000);
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
    final double dialogDy = tester.getCenter(find.text('白').first).dy;
    final double titleDy = tester.getCenter(find.text('題').first).dy;
    // 标题 MarginV=400 明显更高（dy 更小），与贴底对白分居，未被折进同一基线。
    expect(titleDy, lessThan(dialogDy - 200),
        reason: '大 MarginV 标题应在 authored 高位，不与贴底对白折叠');
  });
}
