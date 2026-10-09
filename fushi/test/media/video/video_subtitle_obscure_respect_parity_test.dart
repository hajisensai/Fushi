import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-2971（未复现）：用户报「外挂 .ass + 关掉『尊重字幕自带样式』时字幕遮蔽=模糊
/// 不生效、字幕清晰；打开开关后模糊生效」。
///
/// 本文件把那条报告落成 overlay 层的**行为契约**：同一份典型字幕组 ASS（OP 卡拉 OK
/// 光晕层 + 主文字层 + 对白），在 respectAssStyle 开 / 关两种状态下，遮蔽三态
/// （模糊 / 隐藏 / 显形）必须表现一致——
///  ① 播放中：每个字形都在遮蔽视觉之下（模糊=遮蔽 sigma 的 [ImageFiltered]，
///     隐藏=Opacity(0)），且离屏像素里没有任何清晰的亮字形；
///  ② 暂停（「暂停或悬停时显形」开）：两种状态同样显形；
///  ③ 指针不在字幕上：不显形；指针停在字幕上：显形；
///  ④ 副字幕遮蔽与主字幕对称。
///
/// overlay 层两种状态都满足（见 docs/bugs/BUG-2971 的排查记录），若真机仍复现，
/// 差异必在 overlay 之外（字幕文件内容 / 播放态 / 引擎合成），本文件守住 overlay 这一层
/// 不在两条路径间分叉。
const String _kAss = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Hiragino Maru Gothic ProN,72,&H00FFFFFF,&H000000FF,&H00000000,&H7F000000,0,0,0,0,100,100,0,0,1,4,2,2,60,60,50,1
Style: OP,A-OTF Maru Folk Pro H,60,&H00FFFFFF,&H00FF8000,&H00402000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,8,30,30,30,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Comment: 0,0:00:01.00,0:00:05.00,OP,,0,0,0,karaoke,{\k20}冷{\k20}た{\k20}く{\k30}変わってゆく{\k40}われらの城は
Dialogue: 0,0:00:01.00,0:00:05.00,OP,,0,0,0,fx,{\fad(150,150)\blur4\1a&HFF&\3c&HFF8000&}{\k20}冷{\k20}た{\k20}く{\k30}変わってゆく{\k40}われらの城は
Dialogue: 1,0:00:01.00,0:00:05.00,OP,,0,0,0,fx,{\fad(150,150)}{\k20}冷{\k20}た{\k20}く{\k30}変わってゆく{\k40}われらの城は
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,そうだね\Nまた明日
''';

List<AudioCue> _parse(String bookKey) => AssParser.parseString(
    content: _kAss, bookKey: bookKey, includeDrawings: true);

const double _kFontSize = 40;

VideoPlayerController _controller({bool secondary = false}) {
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  c.setCues(_parse('main'));
  if (secondary) c.setSecondaryCues(_parse('secondary'));
  c.debugSetPositionForTesting(2000);
  c.debugUpdateCueForPosition(2000);
  c.debugSetIsPlayingForTesting(true);
  return c;
}

final GlobalKey _boundary = GlobalKey();

Future<void> _pump(
  WidgetTester tester,
  VideoPlayerController c, {
  required bool respect,
  bool blur = false,
  bool hide = false,
  bool secondaryBlur = false,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: RepaintBoundary(
        key: _boundary,
        child: SizedBox(
          width: 1280,
          height: 720,
          child: VideoSubtitleOverlay(
            controller: c,
            blurEnabled: blur,
            subtitleHidden: hide,
            secondaryBlurEnabled: secondaryBlur,
            respectAssStyle: respect,
            textColor: Colors.white,
            fontSize: _kFontSize,
            shadowThickness: 2,
            onCharTap: (String a, int b, Rect r, AudioCue cue) {},
            onHoverChanged: (_) {},
          ),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 16));
}

/// 字幕树里所有字形 [Text]（不含任何别的文本）。
List<Element> _glyphs() => find
    .descendant(
        of: find.byType(VideoSubtitleOverlay), matching: find.byType(Text))
    .evaluate()
    .toList();

/// [e] 是否在遮蔽层的模糊之下（sigma 与 [VideoSubtitleOverlay.obscureBlurSigma] 一致；
/// 字幕自带 `\blur` 的 ImageFiltered sigma 不同，不会被误认）。
bool _underObscureBlur(Element e) {
  final double sigma = VideoSubtitleOverlay.obscureBlurSigma(_kFontSize);
  final ui.ImageFilter want = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
  bool found = false;
  e.visitAncestorElements((Element a) {
    final Widget w = a.widget;
    if (w is ImageFiltered && w.imageFilter == want) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

bool _underOpacityZero(Element e) {
  bool found = false;
  e.visitAncestorElements((Element a) {
    final Widget w = a.widget;
    if (w is Opacity && w.opacity == 0) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// 离屏像素里「清晰亮字形」的像素数：白字被遮蔽 sigma 糊开后峰值远低于 230。
Future<int> _crispBrightPixels(WidgetTester tester) async {
  int bright = 0;
  await tester.runAsync(() async {
    final RenderRepaintBoundary rb =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image img = await rb.toImage();
    final ByteData data = (await img.toByteData())!;
    for (int p = 0; p < data.lengthInBytes; p += 4) {
      if (data.getUint8(p) > 230 &&
          data.getUint8(p + 1) > 230 &&
          data.getUint8(p + 2) > 230) {
        bright++;
      }
    }
    img.dispose();
  });
  return bright;
}

void main() {
  for (final bool respect in <bool>[false, true]) {
    group('respectAssStyle=$respect', () {
      testWidgets('播放中 + 模糊：每个字形都在遮蔽模糊之下，像素里无清晰亮字',
          (WidgetTester tester) async {
        final VideoPlayerController c = _controller();
        addTearDown(c.dispose);
        await _pump(tester, c, respect: respect, blur: true);

        final List<Element> glyphs = _glyphs();
        expect(glyphs, isNotEmpty);
        expect(glyphs.where((Element e) => !_underObscureBlur(e)), isEmpty,
            reason: '有字形漏在遮蔽模糊之外 = 用户看到的清晰字幕');
        expect(await _crispBrightPixels(tester), 0);
      });

      testWidgets('不遮蔽时像素里确有清晰亮字（像素判据本身有效）', (WidgetTester tester) async {
        final VideoPlayerController c = _controller();
        addTearDown(c.dispose);
        await _pump(tester, c, respect: respect);

        expect(await _crispBrightPixels(tester), greaterThan(0));
      });

      testWidgets('播放中 + 隐藏：每个字形都在 Opacity(0) 之下', (WidgetTester tester) async {
        final VideoPlayerController c = _controller();
        addTearDown(c.dispose);
        await _pump(tester, c, respect: respect, hide: true);

        final List<Element> glyphs = _glyphs();
        expect(glyphs, isNotEmpty);
        expect(glyphs.where((Element e) => !_underOpacityZero(e)), isEmpty);
        expect(await _crispBrightPixels(tester), 0);
      });

      testWidgets('暂停：两种状态同样显形', (WidgetTester tester) async {
        final VideoPlayerController c = _controller();
        addTearDown(c.dispose);
        c.debugSetIsPlayingForTesting(false);
        await _pump(tester, c, respect: respect, blur: true);

        expect(_glyphs().where(_underObscureBlur), isEmpty);
      });

      testWidgets('指针离开字幕不显形，停在字幕上才显形', (WidgetTester tester) async {
        final VideoPlayerController c = _controller();
        addTearDown(c.dispose);
        await _pump(tester, c, respect: respect, blur: true);

        final TestGesture mouse =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1270, 10));
        addTearDown(mouse.removePointer);
        await tester.pump();
        expect(_glyphs().where((Element e) => !_underObscureBlur(e)), isEmpty,
            reason: '指针在画面角落：不应显形');

        await mouse.moveTo(tester.getCenter(find.text('そ').first));
        await tester.pump();
        expect(_glyphs().where(_underObscureBlur), isEmpty,
            reason: '悬停显形：该层整层揭开');

        await mouse.moveTo(const Offset(1270, 10));
        await tester.pump();
        expect(_glyphs().where((Element e) => !_underObscureBlur(e)), isEmpty,
            reason: '移开即复原遮蔽');
      });

      testWidgets('副字幕模糊与主字幕对称（主不遮、副遮）', (WidgetTester tester) async {
        final VideoPlayerController c = _controller(secondary: true);
        addTearDown(c.dispose);
        await _pump(tester, c, respect: respect, secondaryBlur: true);

        final List<Element> glyphs = _glyphs();
        final int blurred = glyphs.where(_underObscureBlur).length;
        expect(blurred, greaterThan(0), reason: '副字幕层必须被遮蔽模糊');
        expect(blurred, lessThan(glyphs.length), reason: '主字幕层不遮蔽');
      });
    });
  }
}
