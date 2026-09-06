import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_clip_subtitle_burn.dart';
import 'package:fushi/src/media/video/video_clip_subtitle_image.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';

void main() {
  group('computeClipSubtitleLayout', () {
    test('scales the on-screen style up to the frame pixel grid', () {
      // 屏幕上视频区高 720 逻辑像素、字号 36；导出到 1080p ⇒ scale 1.5。
      final ClipSubtitleLayout l = computeClipSubtitleLayout(
        frame: const ClipFrameSize(1920, 1080),
        style: VideoSubtitleStyle.defaults,
        viewportHeight: 720,
      );

      expect(l.scale, 1.5);
      expect(l.fontSize, 36 * 1.5);
      expect(l.bottomPadding, 75 * 1.5);
      expect(l.shadowThickness, VideoSubtitleStyle.defaultShadowThickness * 1.5);
      expect(l.maxWidth, 1920 * kClipSubtitleMaxWidthFraction);
    });

    test('keeps the subtitle at the same fraction of the frame either way', () {
      // 「所见即所得」的真正不变式：无论导出 1080p 还是 720p，字幕高度占画面的
      // 比例都等于它在屏幕上占视频区的比例。分辨率变了字幕相对大小不该变。
      const VideoSubtitleStyle style = VideoSubtitleStyle.defaults;
      const double viewport = 600;

      final ClipSubtitleLayout hd = computeClipSubtitleLayout(
        frame: const ClipFrameSize(1920, 1080),
        style: style,
        viewportHeight: viewport,
      );
      final ClipSubtitleLayout sd = computeClipSubtitleLayout(
        frame: const ClipFrameSize(1280, 720),
        style: style,
        viewportHeight: viewport,
      );

      expect(hd.fontSize / 1080, closeTo(sd.fontSize / 720, 1e-9));
      expect(hd.bottomPadding / 1080, closeTo(sd.bottomPadding / 720, 1e-9));
    });

    test('falls back instead of producing a zero or infinite scale', () {
      // viewportHeight 拿不到时 scale 会变成 0 或无穷：前者渲染出一张空图，
      // 后者把字放大到糊满整屏。两种都比「字幕大小略有出入」糟得多。
      for (final double bad in <double>[0, -1]) {
        final ClipSubtitleLayout l = computeClipSubtitleLayout(
          frame: const ClipFrameSize(1920, 1080),
          style: VideoSubtitleStyle.defaults,
          viewportHeight: bad,
        );
        expect(
          l.scale,
          1080 / kClipSubtitleFallbackViewportHeight,
          reason: 'viewportHeight=$bad',
        );
        expect(l.fontSize, greaterThan(0));
        expect(l.fontSize.isFinite, isTrue);
      }
    });

    test('honours a user-tuned font size and position', () {
      final ClipSubtitleLayout l = computeClipSubtitleLayout(
        frame: const ClipFrameSize(1920, 1080),
        style: VideoSubtitleStyle.defaults
            .copyWith(fontSize: 48, bottomPadding: 120),
        viewportHeight: 1080,
      );

      expect(l.scale, 1.0);
      expect(l.fontSize, 48);
      expect(l.bottomPadding, 120);
    });

    test('uses the default thickness when the user left it unset', () {
      // shadowThickness 为 null = 「跟随全局 UI 缩放」，1.0 时就是默认值；
      // 直接当 0 用会渲染出没有投影的字幕，暗背景上糊成一片。
      expect(VideoSubtitleStyle.defaults.shadowThickness, isNull);
      final ClipSubtitleLayout l = computeClipSubtitleLayout(
        frame: const ClipFrameSize(1920, 1080),
        style: VideoSubtitleStyle.defaults,
        viewportHeight: 1080,
      );
      expect(l.shadowThickness, VideoSubtitleStyle.defaultShadowThickness);
    });
  });

  group('renderClipSubtitlePng', () {
    testWidgets('renders a full-frame PNG at the video resolution',
        (WidgetTester tester) async {
      Uint8List? png;
      await tester.runAsync(() async {
        png = await renderClipSubtitlePng(
          text: 'おーい みんな もうすぐ年明けだぞ',
          frame: const ClipFrameSize(640, 360),
          style: VideoSubtitleStyle.defaults,
          viewportHeight: 360,
        );
      });

      expect(png, isNotNull);
      expect(png!.length, greaterThan(0));
      // PNG 魔数，确认真是 PNG 而不是别的字节。
      expect(png!.sublist(0, 8),
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      // IHDR 的宽高（大端 32 位，偏移 16/20）必须**等于视频分辨率**——overlay 到
      // 0:0 全靠这一点，尺寸不符会让字幕被拉伸或裁掉。
      final ByteData bd = ByteData.sublistView(png!);
      expect(bd.getUint32(16), 640);
      expect(bd.getUint32(20), 360);
    });

    testWidgets('blank text yields null instead of a fully transparent frame',
        (WidgetTester tester) async {
      // 全透明的图只会白白多占一个 overlay 节点（还挤占命令行长度预算）。
      await tester.runAsync(() async {
        expect(
          await renderClipSubtitlePng(
            text: '   ',
            frame: const ClipFrameSize(640, 360),
            style: VideoSubtitleStyle.defaults,
            viewportHeight: 360,
          ),
          isNull,
        );
        expect(
          await renderClipSubtitlePng(
            text: '',
            frame: const ClipFrameSize(640, 360),
            style: VideoSubtitleStyle.defaults,
            viewportHeight: 360,
          ),
          isNull,
        );
      });
    });

    testWidgets('a long line wraps instead of running off the frame',
        (WidgetTester tester) async {
      // 换行走 TextPainter 的 maxWidth（画面宽的 90%）。测试字体是 Ahem，每个字符
      // 宽度恰好等于字号，所以「一定会超宽」的输入是可构造的：这里断言的是渲染不
      // 抛、且仍产出整帧图（换行后文本更高，底部锚定要能容纳）。
      Uint8List? png;
      await tester.runAsync(() async {
        png = await renderClipSubtitlePng(
          text: 'あ' * 200,
          frame: const ClipFrameSize(640, 360),
          style: VideoSubtitleStyle.defaults,
          viewportHeight: 360,
        );
      });

      expect(png, isNotNull);
      final ByteData bd = ByteData.sublistView(png!);
      expect(bd.getUint32(16), 640);
      expect(bd.getUint32(20), 360);
    });
  });
}
