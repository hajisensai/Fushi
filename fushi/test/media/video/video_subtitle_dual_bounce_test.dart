import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG 守卫：真实 fansub「双语.ass」暴露的两个底部双语缺陷。
///
/// ① **来回弹跳**：相邻对白（前一条 `endMs` == 后一条 `startMs`，fansub 极常见）在渲染集
///    若走**闭区间**，那一毫秒新旧两对 cue 同时活跃——竖排堆叠槽位表把后进 cue 追加到远端
///    槽，前一条退场只留下锚点侧隐形占位（step③ 只裁尾部死槽），把后一条持续顶离基线，
///    直到出现间隙才复位 → 双轨字幕在连续对白里被抬高、间隙落回，来回弹跳。修复：渲染集
///    走**半开区间**（`findActiveCueIndices(endInclusive: false)`），边界处只后一条活跃，
///    后进 cue 复用被腾空的锚点槽。守卫：跨越触边界后，续存的底部对白必须回到与前一条
///    **同一基线**（不被幻影占位抬高）。
///
/// ② **大屏塌陷重叠**：`_positionKey` 旧折叠判据 `scaledMarginV <= bottomPadding` 依赖显示
///    区高——大屏时第二语言（CH MarginV=30 缩放后 > bottomPadding）脱离基线桶、与仍折在
///    基线的第一语言各自定位却落在相邻高度、大字号盒相交（BUG-709 仅大屏回归）。修复：
///    折叠判据改用**原始 MarginV**（显示无关）。守卫：JP(MarginV=4)+CH(MarginV=30) 在
///    2160 高显示区仍竖直不重叠。
AudioCue _bottomCue(
  String text, {
  required double marginV,
  required double fontSizePx,
  required int startMs,
  required int endMs,
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
      playResY: 720,
    )
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

Rect _fillRect(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
      (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);
  return tester.getRect(fill.first);
}

Future<void> _mount(
  WidgetTester tester,
  VideoPlayerController c,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: size.width,
        height: size.height,
        child: VideoSubtitleOverlay(
          controller: c,
          respectAssStyle: true,
          onCharTap: (_, __, ___, ____) {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('① 相邻底部对白触边界后不被幻影占位抬高（不弹跳）', (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // 两对触边界对白：A[0..1000]，B[1000..2000]（B.start == A.end）。文件顺序仿 ASS：
    // 先全部 JP 后全部 CH。
    final AudioCue jpA =
        _bottomCue('あ', marginV: 4, fontSizePx: 35, startMs: 0, endMs: 1000);
    final AudioCue jpB =
        _bottomCue('い', marginV: 4, fontSizePx: 35, startMs: 1000, endMs: 2000);
    final AudioCue chA =
        _bottomCue('甲', marginV: 30, fontSizePx: 56, startMs: 0, endMs: 1000);
    final AudioCue chB = _bottomCue('乙',
        marginV: 30, fontSizePx: 56, startMs: 1000, endMs: 2000);
    c.setCues(<AudioCue>[jpA, jpB, chA, chB]);

    await _mount(tester, c, const Size(1280, 720));

    // A 段：记录 JP_A / CH_A 基线。
    c.debugUpdateCueForPosition(500);
    await tester.pump();
    final Rect jpABox = _fillRect(tester, 'あ');
    final Rect chABox = _fillRect(tester, '甲');

    // 步进穿过触边界 t=1000（旧闭区间在此产生幻影 4-cue 重叠，污染槽位）。
    c.debugUpdateCueForPosition(1000);
    await tester.pump();

    // B 段：JP_B / CH_B 必须回到与 A 段完全相同的基线（无幻影占位抬升）。
    c.debugUpdateCueForPosition(1500);
    await tester.pump();
    final Rect jpBBox = _fillRect(tester, 'い');
    final Rect chBBox = _fillRect(tester, '乙');

    expect((jpBBox.top - jpABox.top).abs(), lessThan(1.0),
        reason: 'JP 续存对白应与前一条同基线，不被幻影占位抬高（弹跳根除）');
    expect((chBBox.top - chABox.top).abs(), lessThan(1.0),
        reason: 'CH 续存对白应与前一条同基线，不弹跳');
  });

  testWidgets('② 大屏（2160 高）底部双语 JP/CH 仍不塌陷重叠', (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    final AudioCue jp =
        _bottomCue('日', marginV: 4, fontSizePx: 35, startMs: 0, endMs: 5000);
    final AudioCue ch =
        _bottomCue('中', marginV: 30, fontSizePx: 56, startMs: 0, endMs: 5000);
    c.setCues(<AudioCue>[jp, ch]);
    // 2160 高显示区：旧判据把 CH（scaledMarginV = 30 * 2160/720 = 90 > 75）判成独立位置
    // → 与 JP 重叠。原始值判据（30 <= 75）恒折叠堆叠。
    await _mount(tester, c, const Size(3840, 2160));
    c.debugUpdateCueForPosition(1000);
    await tester.pump();

    expect(c.activeCues.length, 2);
    final Rect jpBox = _fillRect(tester, '日');
    final Rect chBox = _fillRect(tester, '中');
    final bool overlap = jpBox.top < chBox.bottom && chBox.top < jpBox.bottom;
    expect(overlap, isFalse,
        reason: '大屏下 JP(MarginV=4)+CH(MarginV=30) 竖直不得相交（BUG-709 大屏不回归）');
    // CH 在 JP 上方（MarginV 大者离底更远，libass 相对次序）。
    expect(chBox.bottom, lessThanOrEqualTo(jpBox.top + 1.0),
        reason: 'CH 应堆叠在 JP 上方');
  });

  testWidgets('③ 渲染集半开区间：触边界处只后一条活跃（幻影重叠消除）', (WidgetTester tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    final AudioCue a =
        _bottomCue('前', marginV: 4, fontSizePx: 35, startMs: 0, endMs: 1000);
    final AudioCue b =
        _bottomCue('后', marginV: 4, fontSizePx: 35, startMs: 1000, endMs: 2000);
    c.setCues(<AudioCue>[a, b]);
    await _mount(tester, c, const Size(1280, 720));

    // 恰在触边界 t=1000：半开区间下前一条（end=1000）退场、后一条（start=1000）进场，
    // 活动集只 1 条，不产生幻影重叠。
    c.debugUpdateCueForPosition(1000);
    await tester.pump();
    expect(c.activeCues.length, 1, reason: '触边界处渲染集只后一条（半开区间）');
    expect(c.activeCues.single.text, '后');
  });
}
