import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';

/// TODO-1013 守卫：收藏句/选区「导出片段」的文本卡片必须复刻有声书「逐句高亮跟随」
/// 样式——把 `AudiobookClipTextLayout.highlight`（= `ReaderThemeColors.sasayaki`，与
/// 阅读器正文 `::highlight(hoshi-sasayaki)` 同一真相源）当整句背景衬底涂在文字之下。
///
/// 这是行为测试（真跑离屏渲染管线 → 取 PNG 像素），不是字符串静态断言：断言渲染出的
/// 图里确实出现高亮衬底色的像素，且换高亮色时图会跟着变（证明 highlight 真穿到渲染）。
void main() {
  /// 在真实 Overlay 里离屏渲染卡片并解码成 RGBA 像素。
  Future<_DecodedImage> renderAndDecode(
    WidgetTester tester, {
    required String text,
    required AudiobookClipTextLayout layout,
  }) async {
    late OverlayState overlayState;
    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (BuildContext context) {
                overlayState = Overlay.of(context);
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 渲染依赖真实帧调度（scheduleFrame + post-frame）+ 真定时器，必须在 runAsync 里跑，
    // 并配合 tester.pump 推进离屏 pipeline 完成 paint（照搬 audiobook_clip_text_render_test）。
    _DecodedImage? decoded;
    await tester.runAsync(() async {
      final Future<Uint8List?> future = renderAudiobookClipTextToPng(
        overlay: overlayState,
        text: text,
        layout: layout,
      );
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final Uint8List? png = await future;
      expect(png, isNotNull, reason: '离屏渲染必须产出 PNG（渲染管线可用）。');

      final ui.Codec codec = await ui.instantiateImageCodec(png!);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData? rgba =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      decoded = _DecodedImage(
        width: frame.image.width,
        height: frame.image.height,
        rgba: rgba!.buffer.asUint8List(),
      );
      frame.image.dispose();
    });
    return decoded!;
  }

  AudiobookClipTextLayout layoutWith({
    required Color background,
    required Color foreground,
    required Color highlight,
  }) {
    return computeClipTextLayout(
      textLength: 6,
      baseFontSize: 22,
      vertical: false,
      lineHeight: 1.6,
      background: background,
      foreground: foreground,
      highlight: highlight,
      // 小图省内存/加速，仍走完整 pipeline。
      width: 160,
      height: 240,
    );
  }

  testWidgets(
    'exported clip paints the sasayaki highlight wash behind the sentence',
    (WidgetTester tester) async {
      const Color bg = Color(0xFF101010);
      const Color fg = Color(0xFFF0F0F0);
      const Color highlight = Color(0xFFFF00FF); // 醒目品红，易与 bg/fg 区分。

      final _DecodedImage img = await renderAndDecode(
        tester,
        text: '僕は学校へ',
        layout: layoutWith(
          background: bg,
          foreground: fg,
          highlight: highlight,
        ),
      );

      // 断言：渲染图里出现接近 highlight 的像素——高亮衬底真被画出来了，
      // 而不是只有 bg（近黑）/ fg（近白）。
      expect(
        img.hasPixelCloseTo(highlight),
        isTrue,
        reason: '导出卡片必须把 highlight（sasayaki 逐句高亮跟随色）画成整句背景衬底。',
      );
    },
  );

  testWidgets(
    'highlight wash tracks the input color (not hardcoded) (真穿到渲染)',
    (WidgetTester tester) async {
      // 换一个与上例完全不同的哨兵色（青）：若渲染把 highlight 真穿下去，图里应出现青，
      // 且**不该**出现上例的品红——从而证明衬底色跟随入参，不是写死的固定色。
      final _DecodedImage img = await renderAndDecode(
        tester,
        text: '僕は学校へ',
        layout: layoutWith(
          background: const Color(0xFF101010),
          foreground: const Color(0xFFF0F0F0),
          highlight: const Color(0xFF00FFFF),
        ),
      );
      expect(img.hasPixelCloseTo(const Color(0xFF00FFFF)), isTrue,
          reason: '衬底色必须跟随传入的 highlight（青）。');
      expect(img.hasPixelCloseTo(const Color(0xFFFF00FF)), isFalse,
          reason: '衬底色不是写死的品红——换成青后不该再出现品红。');
    },
  );
}

/// 解码后的 RGBA 图，带「是否存在接近某色的像素」查询。
class _DecodedImage {
  _DecodedImage({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;

  /// 图内是否存在与 [target] 每通道差 <= [tolerance] 的像素。
  bool hasPixelCloseTo(Color target, {int tolerance = 24}) {
    final int tr = (target.r * 255.0).round();
    final int tg = (target.g * 255.0).round();
    final int tb = (target.b * 255.0).round();
    for (int i = 0; i + 3 < rgba.length; i += 4) {
      final int r = rgba[i];
      final int g = rgba[i + 1];
      final int b = rgba[i + 2];
      if ((r - tr).abs() <= tolerance &&
          (g - tg).abs() <= tolerance &&
          (b - tb).abs() <= tolerance) {
        return true;
      }
    }
    return false;
  }
}
