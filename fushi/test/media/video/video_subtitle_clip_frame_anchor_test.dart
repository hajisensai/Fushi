import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-1775 守卫：带静态 `\clip` 的无 \pos ASS 事件必须在**帧空间**按 Alignment+Margin
/// 绝对定位（libass 语义），与 `\clip` 映射（fit:contain 视频内容矩形）同一几何。
///
/// 用户片源真值（神稲ぼたん S01E08 .ja.ass，PlayRes 1920x1080）：同句歌词由左右分屏
/// 两条 Dialogue 拼成——layer0 `{\clip(0,920,960,1080)}` + layer1
/// `{\clip(960,920,1920,1080)}`，样式 \an2、MarginV 5/12。mpv 里两条同位叠画、左右
/// 无缝拼成一行；修复前 Hibiki 把它们锚到「用户底距 + 控制条避让」的容器基线，与固定
/// 在帧上的 clip 边带脱节：两半错位断开、字形被 clip 竖向边拦腰裁半。
AudioCue _clipCue(
  String text, {
  required int layer,
  required double marginV,
  required SubtitleClip? clip,
  double fontSizePx = 60,
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
      anchor: const SubtitleAnchor(
        SubtitleVAlign.bottom,
        SubtitleHAlign.center,
      ),
      cueStyle: style,
      playResX: 1920,
      playResY: 1080,
      layer: layer,
      clip: clip,
    )
    ..startMs = 0
    ..endMs = 5000;
}

/// E08 真值的左右半屏 clip（PlayRes 1920x1080 归一成分数）。
SubtitleClip _halfClip({required bool left}) => SubtitleClip(
  inverse: false,
  segments: left
      ? const <SubtitleClipSegment>[
          SubtitleClipSegment.move(0, 920 / 1080),
          SubtitleClipSegment.line(0.5, 920 / 1080),
          SubtitleClipSegment.line(0.5, 1),
          SubtitleClipSegment.line(0, 1),
        ]
      : const <SubtitleClipSegment>[
          SubtitleClipSegment.move(0.5, 920 / 1080),
          SubtitleClipSegment.line(1, 920 / 1080),
          SubtitleClipSegment.line(1, 1),
          SubtitleClipSegment.line(0.5, 1),
        ],
);

Set<String> _fillTops(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == ch && w.style?.foreground == null,
  );
  return <String>{
    for (final Element e in fill.evaluate())
      tester
          .getRect(find.byElementPredicate((Element x) => x == e))
          .top
          .toStringAsFixed(1),
  };
}

Rect _fillRect(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == ch && w.style?.foreground == null,
  );
  return tester.getRect(fill.first);
}

Future<void> _pumpOverlay(
  WidgetTester tester,
  VideoPlayerController c, {
  ValueListenable<bool>? controlsVisible,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: VideoSubtitleOverlay(
            controller: c,
            respectAssStyle: true,
            controlsVisible: controlsVisible,
            controlsBottomReserve: 140,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('resolveClipCueAnchorFraction（libass 排版语义纯函数）', () {
    SubtitleMarkup markup({
      SubtitleAnchor? anchor,
      double? marginV,
      double? marginL,
      double? marginR,
      double? playResX = 1920,
      double? playResY = 1080,
    }) => SubtitleMarkup(
      plainText: 'x',
      spans: const <SubtitleSpan>[],
      anchor: anchor,
      cueStyle: SubtitleCueStyle(
        anchor: anchor,
        marginV: marginV,
        marginL: marginL,
        marginR: marginR,
      ),
      playResX: playResX,
      playResY: playResY,
    );

    test(r'\an2 底部居中：y = 1 - MarginV/PlayResY，x = 0.5（E08 真值）', () {
      final SubtitlePos p = resolveClipCueAnchorFraction(
        markup(
          anchor: const SubtitleAnchor(
            SubtitleVAlign.bottom,
            SubtitleHAlign.center,
          ),
          marginV: 12,
        ),
      );
      expect(p.xFraction, closeTo(0.5, 1e-9));
      expect(p.yFraction, closeTo(1 - 12 / 1080, 1e-9));
    });

    test(r'\an8 顶部：y = MarginV/PlayResY；\an5 中部：y=0.5 且 MarginV 不参与', () {
      final SubtitlePos top = resolveClipCueAnchorFraction(
        markup(
          anchor: const SubtitleAnchor(
            SubtitleVAlign.top,
            SubtitleHAlign.center,
          ),
          marginV: 54,
        ),
      );
      expect(top.yFraction, closeTo(54 / 1080, 1e-9));
      final SubtitlePos mid = resolveClipCueAnchorFraction(
        markup(
          anchor: const SubtitleAnchor(
            SubtitleVAlign.middle,
            SubtitleHAlign.center,
          ),
          marginV: 54,
        ),
      );
      expect(mid.yFraction, closeTo(0.5, 1e-9));
    });

    test('左/右对齐吃 MarginL/MarginR；居中偏移 (L-R)/2', () {
      final SubtitlePos left = resolveClipCueAnchorFraction(
        markup(
          anchor: const SubtitleAnchor(
            SubtitleVAlign.bottom,
            SubtitleHAlign.left,
          ),
          marginL: 192,
        ),
      );
      expect(left.xFraction, closeTo(0.1, 1e-9));
      final SubtitlePos right = resolveClipCueAnchorFraction(
        markup(
          anchor: const SubtitleAnchor(
            SubtitleVAlign.bottom,
            SubtitleHAlign.right,
          ),
          marginR: 192,
        ),
      );
      expect(right.xFraction, closeTo(0.9, 1e-9));
      final SubtitlePos center = resolveClipCueAnchorFraction(
        markup(
          anchor: const SubtitleAnchor(
            SubtitleVAlign.bottom,
            SubtitleHAlign.center,
          ),
          marginL: 192,
          marginR: 0,
        ),
      );
      expect(center.xFraction, closeTo(0.5 + 0.05, 1e-9));
    });

    test('缺 PlayRes / 无边距时按 0 边距（贴帧边不炸）', () {
      final SubtitlePos p = resolveClipCueAnchorFraction(
        markup(
          anchor: const SubtitleAnchor(
            SubtitleVAlign.bottom,
            SubtitleHAlign.center,
          ),
          marginV: 12,
          playResY: null,
        ),
      );
      expect(p.yFraction, closeTo(1.0, 1e-9));
    });
  });

  group('clipGroupFingerprint（值指纹）', () {
    test('等值不同对象 → 同串；不同矩形 → 不同串；\\iclip 与 \\clip 不同', () {
      final SubtitleClip a = _halfClip(left: true);
      final SubtitleClip b = _halfClip(left: true);
      final SubtitleClip r = _halfClip(left: false);
      expect(identical(a, b), isFalse);
      expect(clipGroupFingerprint(a), clipGroupFingerprint(b));
      expect(clipGroupFingerprint(a), isNot(clipGroupFingerprint(r)));
      final SubtitleClip inv = SubtitleClip(
        inverse: true,
        segments: a.segments,
      );
      expect(clipGroupFingerprint(inv), isNot(clipGroupFingerprint(a)));
    });
  });

  group(r'左右分屏 \clip 卡拉OK（E08 OP 真值形状）', () {
    testWidgets(r'两条同文本异 clip 层同位叠画在帧空间底缘，不落用户基线、不被拆行', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugVideoWidthOverride = 1280;
      c.debugVideoHeightOverride = 720;
      final AudioCue l = _clipCue(
        'め',
        layer: 0,
        marginV: 5,
        clip: _halfClip(left: true),
      );
      final AudioCue r = _clipCue(
        'め',
        layer: 1,
        marginV: 5,
        clip: _halfClip(left: false),
      );
      c.setCues(<AudioCue>[l, r]);
      c.debugUpdateCueForPosition(1000);
      expect(c.activeCues.length, 2);

      await _pumpOverlay(tester, c);

      // 同位叠画：两份拷贝 top 相同（修复前两组各自 padding/避让状态错位断开）。
      expect(_fillTops(tester, 'め'), hasLength(1), reason: '左右半屏两层必须同位叠画拼成一行');
      // 帧空间底缘：容器 720 == 视频内容高，MarginV 5 按 720/1080 缩放 ≈ 3.3px，
      // 字形底应贴 720-3.3≈716.7，而不是用户基线 720-75=645（修复前的位置）。
      final Rect glyph = _fillRect(tester, 'め');
      expect(
        glyph.bottom,
        greaterThan(700),
        reason: '必须锚在帧底缘（libass），不得落在用户 bottomPadding 基线',
      );
      // 作者裁剪真的生效：两组各自被 ClipPath 包裹（框架自身可能另有 ClipPath，取下限）。
      expect(find.byType(ClipPath), findsAtLeastNWidgets(2));
    });

    testWidgets(r'控制条可见也不避让：clip 窗固定在帧上，dodge 会把字推出窗外', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> controlsVisible = ValueNotifier<bool>(true);
      addTearDown(controlsVisible.dispose);
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugVideoWidthOverride = 1280;
      c.debugVideoHeightOverride = 720;
      c.setCues(<AudioCue>[
        _clipCue('め', layer: 0, marginV: 5, clip: _halfClip(left: true)),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c, controlsVisible: controlsVisible);
      await tester.pumpAndSettle();

      final Rect glyph = _fillRect(tester, 'め');
      expect(
        glyph.bottom,
        greaterThan(700),
        reason: '控制条 reserve=140 不得把 clip 字幕抬离作者位（会被 clip 边带裁半）',
      );
    });

    testWidgets('视频未解码（分辨率未知）回退历史锚点路径，字幕仍渲染不炸', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _clipCue('め', layer: 0, marginV: 5, clip: _halfClip(left: true)),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c);

      expect(find.text('め'), findsWidgets);
    });
  });
}
