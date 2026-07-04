import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:image/image.dart' as img;

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

    // TODO-1147 文字模糊根因守卫：默认去色度下采样（yuvj444p）+ 近最佳 qscale（-q:v 2）。
    test('defaults to yuvj444p + -q:v 2 (TODO-1147 anti-blur)', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/i.jpg',
        audioPath: '/a.m4a',
        outputPath: '/o.mov',
      );
      expect(args, containsAllInOrder(<String>['-pix_fmt', 'yuvj444p']));
      // 近最佳 qscale 消除默认 qscale 的二次有损。
      final int qIdx = args.indexOf('-q:v');
      expect(qIdx, greaterThanOrEqualTo(0),
          reason: 'mjpeg must pin a low qscale to avoid extra JPEG loss');
      expect(args[qIdx + 1], '2');
    });

    // 移动端保守回退：调用方可显式传 yuvj420p（自编 ffmpeg-kit min 的 mjpeg encoder
    // 收 444 需真机验，未验前移动端仍走 420，靠 1080×1920 分辨率提升消模糊）。
    test('pixFmt override lets mobile fall back to yuvj420p', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/i.jpg',
        audioPath: '/a.m4a',
        outputPath: '/o.mov',
        pixFmt: 'yuvj420p',
      );
      expect(args, containsAllInOrder(<String>['-pix_fmt', 'yuvj420p']));
      expect(args, isNot(contains('yuvj444p')));
    });
  });

  // BUG-543：移动端自编 ffmpeg-kit min 变体无 png decoder（有 mjpeg decoder），此前
  // 合成命令喂 png 输入 → 帧解不出 → exit 1。根因守卫：命令必须走 image2 demuxer 且
  // 图片输入为 JPEG（`.jpg`），绝不依赖 png 解码，保证两端（桌面 ffmpeg-min / 移动
  // ffmpeg-kit min）都走已存在的 mjpeg decoder。
  group('buildFfmpegImageAudioToVideoArgs image input (BUG-543 png-free)', () {
    test('declares -f image2 demuxer before the image input', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/tmp/text.jpg',
        audioPath: '/tmp/clip.aac',
        outputPath: '/tmp/out.mov',
      );
      final int fIdx = args.indexOf('-f');
      expect(fIdx, greaterThanOrEqualTo(0),
          reason: 'must pin the input demuxer explicitly');
      expect(args[fIdx + 1], 'image2');
      // -f image2 must precede the image -i so it applies to that input.
      final int loopIdx = args.indexOf('-loop');
      expect(fIdx, lessThan(loopIdx));
    });

    test('feeds a JPEG image input (never a .png that would need png decoder)',
        () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/tmp/text.jpg',
        audioPath: '/tmp/clip.aac',
        outputPath: '/tmp/out.mov',
      );
      // The image input path is the arg right after the first '-i'.
      final int firstI = args.indexOf('-i');
      expect(firstI, greaterThanOrEqualTo(0));
      final String imageArg = args[firstI + 1];
      expect(imageArg.toLowerCase().endsWith('.jpg'), isTrue,
          reason: 'still frame must be JPEG so ffmpeg uses mjpeg decoder, '
              'never the missing png decoder');
      // No image argument in the command may be a .png.
      for (final String a in args) {
        expect(a.toLowerCase().endsWith('.png'), isFalse,
            reason: 'no .png input: mobile ffmpeg-kit min has no png decoder');
      }
    });
  });

  // BUG-543：把 Flutter 唯一能直出的 png 帧转成两端 ffmpeg 都能解的 jpeg。
  group('encodeClipTextFrameAsJpg (BUG-543 png->jpeg)', () {
    Uint8List makePngBytes() {
      final img.Image image = img.Image(width: 8, height: 8);
      img.fill(image, color: img.ColorRgb8(200, 100, 50));
      return Uint8List.fromList(img.encodePng(image));
    }

    test('re-encodes valid png bytes into decodable jpeg bytes', () {
      final Uint8List png = makePngBytes();
      final Uint8List? jpg = encodeClipTextFrameAsJpg(png);
      expect(jpg, isNotNull);
      // JPEG SOI marker 0xFFD8: proves the output is JPEG, not still PNG.
      expect(jpg!.length, greaterThan(2));
      expect(jpg[0], 0xFF);
      expect(jpg[1], 0xD8);
      // Round-trips back to a decodable image of the same dimensions.
      final img.Image? decoded = img.decodeImage(jpg);
      expect(decoded, isNotNull);
      expect(decoded!.width, 8);
      expect(decoded.height, 8);
    });

    test('returns null on undecodable bytes (caller falls back)', () {
      final Uint8List garbage = Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5]);
      expect(encodeClipTextFrameAsJpg(garbage), isNull);
    });
  });

  // TODO-1115 + BUG-543: multi-cue frame sequence must also be JPEG.
  group('buildFfmpegImageSeqAudioToVideoArgs (TODO-1115 image2 序列帧动态高亮)', () {
    test('reads a JPEG sequence via image2 (-framerate + frame_%04d.jpg)', () {
      final List<String> args = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/tmp/frames',
        audioPath: '/tmp/clip.aac',
        outputPath: '/tmp/out.mov',
        fps: 12,
      );
      // 序列帧靠 -framerate 定时（非单图 -loop 1），输入用 frame_%04d.jpg 模式。
      expect(args, containsAllInOrder(<String>['-framerate', '12']));
      expect(
        args,
        containsAllInOrder(<String>['-i', '/tmp/frames/frame_%04d.jpg']),
      );
      // 天花板守卫：绝不是单图 -loop 1 路径。
      expect(args, isNot(contains('-loop')));
    });

    test('still mjpeg video + aac audio, never libx264/concat/overlay', () {
      final List<String> args = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/f',
        audioPath: '/a.aac',
        outputPath: '/o.mov',
      );
      // ffmpeg-min 天花板：只有 mjpeg 视频编码器；无 libx264/h264/concat/overlay/drawtext。
      expect(args, containsAllInOrder(<String>['-c:v', 'mjpeg']));
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
      expect(args, isNot(contains('libx264')));
      expect(args, isNot(contains('h264')));
      expect(args, isNot(contains('concat')));
      expect(args, isNot(contains('overlay')));
      expect(args, isNot(contains('drawtext')));
      // 序列帧 vf 里也不得掺 overlay/drawtext（逐句高亮靠逐帧 PNG，非 ffmpeg filter）。
      final int vfIdx = args.indexOf('-vf');
      expect(vfIdx, greaterThanOrEqualTo(0));
      final String filter = args[vfIdx + 1];
      expect(filter, isNot(contains('overlay')));
      expect(filter, isNot(contains('drawtext')));
      expect(filter, isNot(contains('subtitles')));
    });

    test('audio-bounded (-shortest), output last, even dims scale+pad', () {
      final List<String> args = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/f',
        audioPath: '/a.aac',
        outputPath: '/out.mov',
        width: 720,
        height: 1280,
      );
      expect(args, contains('-shortest'));
      expect(args.last, '/out.mov');
      final int vfIdx = args.indexOf('-vf');
      final String filter = args[vfIdx + 1];
      expect(filter, contains('scale=720:1280'));
      expect(filter, contains('pad=720:1280'));
    });

    test('normalizes a trailing-slash frames dir without doubling', () {
      final List<String> args = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/tmp/frames/',
        audioPath: '/a.aac',
        outputPath: '/o.mov',
      );
      expect(
        args,
        containsAllInOrder(<String>['-i', '/tmp/frames/frame_%04d.jpg']),
      );
    });

    // TODO-1147：序列帧路径同样默认 yuvj444p + -q:v 2，可被移动端保守覆写为 420。
    test('seq defaults to yuvj444p + -q:v 2, mobile override to yuvj420p', () {
      final List<String> def = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/f',
        audioPath: '/a.aac',
        outputPath: '/o.mov',
      );
      expect(def, containsAllInOrder(<String>['-pix_fmt', 'yuvj444p']));
      final int qIdx = def.indexOf('-q:v');
      expect(qIdx, greaterThanOrEqualTo(0));
      expect(def[qIdx + 1], '2');

      final List<String> mobile = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/f',
        audioPath: '/a.aac',
        outputPath: '/o.mov',
        pixFmt: 'yuvj420p',
      );
      expect(mobile, containsAllInOrder(<String>['-pix_fmt', 'yuvj420p']));
      expect(mobile, isNot(contains('yuvj444p')));
    });
  });

  group('computeClipTextLayout (TODO-945 M3 layout)', () {
    const Color bg = Color(0xFF101010);
    const Color fg = Color(0xFFF0F0F0);
    // TODO-1013：逐句高亮跟随色（sasayaki）——导出卡片当整句背景衬底。
    const Color highlight = Color(0x66FFCC00);

    test(
        'default output is portrait 1080x1920 (TODO-1147 anti-blur) and carries '
        'theme colors', () {
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 6,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      // TODO-1147 根因守卫：栅格化+输出分辨率 >= 1080x1920（旧 720x1280 致文字模糊）。
      expect(layout.width, greaterThanOrEqualTo(1080));
      expect(layout.height, greaterThanOrEqualTo(1920));
      expect(layout.width, 1080);
      expect(layout.height, 1920);
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
