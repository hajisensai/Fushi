import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';

void main() {
  group('buildFfmpegImageAudioToVideoArgs (TODO-945 M4, mjpeg/.mov D-CODEC)',
      () {
    test('uses mjpeg video + aac audio, never libx264/mpeg4', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/tmp/text.png',
        audioPath: '/tmp/clip.m4a',
        outputPath: '/tmp/out.mov',
      );
      // D-CODEC hard fact: bundled ffmpeg only has gif/mjpeg/png video encoders
      // + aac audio. If anyone swaps to libx264/mpeg4 here it must fail loudly.
      expect(args, containsAllInOrder(<String>['-c:v', 'mjpeg']));
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
      expect(args, isNot(contains('libx264')));
      expect(args, isNot(contains('mpeg4')));
      expect(args, isNot(contains('h264')));
    });

    test('loops the static image and is audio-bounded (-loop 1 + -shortest)',
        () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/i.png',
        audioPath: '/a.m4a',
        outputPath: '/o.mov',
      );
      // The image is a single still frame looped; the audio drives duration.
      expect(args, containsAllInOrder(<String>['-loop', '1', '-i', '/i.png']));
      expect(args, contains('-shortest'));
      // Image input precedes audio input.
      final int imgIdx = args.indexOf('/i.png');
      final int audIdx = args.indexOf('/a.m4a');
      expect(imgIdx, greaterThanOrEqualTo(0));
      expect(audIdx, greaterThan(imgIdx));
    });

    test('scales+pads to the requested even dimensions, output last', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/i.png',
        audioPath: '/a.m4a',
        outputPath: '/out.mov',
        width: 720,
        height: 1280,
      );
      final int vfIdx = args.indexOf('-vf');
      expect(vfIdx, greaterThanOrEqualTo(0));
      final String filter = args[vfIdx + 1];
      expect(filter, contains('scale=720:1280'));
      expect(filter, contains('pad=720:1280'));
      // ffmpeg requires the output path as the final positional arg.
      expect(args.last, '/out.mov');
    });

    test('yuvj420p pixel format for mjpeg full-range compatibility', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/i.png',
        audioPath: '/a.m4a',
        outputPath: '/o.mov',
      );
      expect(args, containsAllInOrder(<String>['-pix_fmt', 'yuvj420p']));
    });
  });

  group('computeClipTextLayout (TODO-945 M3 layout)', () {
    const Color bg = Color(0xFF101010);
    const Color fg = Color(0xFFF0F0F0);
    // TODO-1013：逐句高亮跟随色（sasayaki）——导出卡片当整句背景衬底。
    const Color highlight = Color(0x66FFCC00);

    test('default output is portrait 720x1280 (D3) and carries theme colors',
        () {
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 6,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      expect(layout.width, 720);
      expect(layout.height, 1280);
      expect(layout.background, bg);
      expect(layout.foreground, fg);
      // TODO-1013：逐句高亮跟随色（sasayaki）必须原样透传给渲染层。
      expect(layout.highlight, highlight);
      expect(layout.vertical, isFalse);
    });

    test('long selections shrink the font (no overflow), short keep big', () {
      final AudiobookClipTextLayout shortL = computeClipTextLayout(
        textLength: 4,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.6,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      final AudiobookClipTextLayout longL = computeClipTextLayout(
        textLength: 200,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.6,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      expect(longL.fontSize, lessThan(shortL.fontSize));
      // Never collapses below the readable floor.
      expect(longL.fontSize, greaterThanOrEqualTo(18));
    });

    test('vertical writing-mode is propagated', () {
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 8,
        baseFontSize: 24,
        vertical: true,
        lineHeight: 1.6,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      expect(layout.vertical, isTrue);
    });

    test('degenerate inputs (0 length / 0 font / 0 lineHeight) stay sane', () {
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 0,
        baseFontSize: 0,
        vertical: false,
        lineHeight: 0,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      expect(layout.fontSize, greaterThan(0));
      expect(layout.lineHeight, greaterThan(0));
      expect(layout.padding, greaterThan(0));
    });
  });
}
