import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_export.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:image/image.dart' as img;

void main() {
  group('buildFfmpegImageAudioToVideoArgs (TODO-945 M4, H.264/.mp4)', () {
    // TODO-2357：**全平台统一 libx264**，参数表不再有平台开关。移动端 ffmpeg-kit 已重编
    // 入 x264（--enable-gpl --enable-x264，AAR 实证含 `libx264` 精确串 + `x264 - core`
    // 版本串）。此前的移动 mpeg4 回退（BUG-1322）规格上限低于 1080×1920，编得出但设备
    // 可能解不了且 ffmpeg 仍 exit 0（静默产坏文件）；更早的 mjpeg（30 秒 ≈ 200MB + 大量
    // 移动播放器无解码器 → 黑屏，BUG-809）同型。两者都绝不得再作输出编码器。
    test('all platforms use libx264 + aac, never mpeg4/mjpeg', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/tmp/text.jpg',
        audioPath: '/tmp/clip.aac',
        outputPath: '/tmp/out.mp4',
      );
      expect(args, containsAllInOrder(<String>['-c:v', 'libx264']));
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
      expect(args, isNot(contains('mpeg4')));
      expect(args, isNot(contains('mjpeg')));
      // 硬件编码器同样不得出现：当前两端 ffmpeg 均未编入（iOS --disable-videotoolbox /
      // Android --disable-mediacodec），写进去就是运行时 Unknown encoder。
      expect(args, isNot(contains('h264_videotoolbox')));
      expect(args, isNot(contains('h264_mediacodec')));
      expect(args, isNot(contains('h264_v4l2m2m')));
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

    // TODO-2357：H.264 钉 crf 20（高质量近视觉无损）+ preset veryfast + yuv420p
    // （全平台硬解基线色度，也是 H.264 High profile 的基线要求）+ faststart。
    // `-q:v` 是 mpeg4/mjpeg 的 qscale，H.264 用 crf——它回流即说明编码器被换回去了。
    test('pins -preset veryfast + -crf 20 + yuv420p + faststart, no qscale', () {
      final List<String> args = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/i.jpg',
        audioPath: '/a.aac',
        outputPath: '/o.mp4',
      );
      expect(args, containsAllInOrder(<String>['-preset', 'veryfast']));
      expect(args, containsAllInOrder(<String>['-crf', '20']));
      expect(args, containsAllInOrder(<String>['-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(<String>['-movflags', '+faststart']));
      expect(args, isNot(contains('-q:v')));
      // 旧 mjpeg 的 yuvj* 色域不得回流。
      expect(args, isNot(contains('yuvj444p')));
      expect(args, isNot(contains('yuvj420p')));
    });

    // TODO-2357 承重守卫：单图与序列帧两条合成路径必须产出**逐字节相同**的编码器参数段。
    // 此前两条路径各自透传 h264 开关，PR#607 的变异实测就抓到过「只改一条」的空洞
    // （useH264 改 true 而序列帧路径仍绑 isDesktop，57 个测试无人报警）。参数表统一到
    // 单一常量后，这条断言把「两条路径不得再分叉」钉死。
    test('static and sequence paths emit identical codec args (TODO-2357)', () {
      final List<String> still = buildFfmpegImageAudioToVideoArgs(
        imagePath: '/i.jpg',
        audioPath: '/a.aac',
        outputPath: '/o.mp4',
      );
      final List<String> seq = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/frames',
        audioPath: '/a.aac',
        outputPath: '/o.mp4',
      );
      List<String> codecSegment(List<String> args) {
        final int start = args.indexOf('-c:v');
        expect(start, greaterThanOrEqualTo(0));
        return args.sublist(start, start + 10);
      }

      expect(codecSegment(still), codecSegment(seq));
      expect(codecSegment(still), contains('libx264'));
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

    test('seq uses libx264 + aac, never mpeg4/mjpeg/concat/overlay', () {
      final List<String> args = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/f',
        audioPath: '/a.aac',
        outputPath: '/o.mp4',
      );
      // TODO-2357：序列帧路径与单图路径同走 libx264（全平台）；两端 ffmpeg 均无
      // concat/overlay/drawtext filter（逐句高亮靠逐帧 JPEG，非 ffmpeg filter）。
      expect(args, containsAllInOrder(<String>['-c:v', 'libx264']));
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
      expect(args, isNot(contains('mpeg4')));
      expect(args, isNot(contains('mjpeg')));
      expect(args, isNot(contains('concat')));
      expect(args, isNot(contains('overlay')));
      expect(args, isNot(contains('drawtext')));
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

    // TODO-2357：序列帧路径同样钉 H.264 的 crf/preset，mpeg4 的 qscale 不得回流。
    test('seq pins -crf 20 + yuv420p + faststart, no qscale', () {
      final List<String> def = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/f',
        audioPath: '/a.aac',
        outputPath: '/o.mp4',
      );
      expect(def, containsAllInOrder(<String>['-pix_fmt', 'yuv420p']));
      expect(def, containsAllInOrder(<String>['-movflags', '+faststart']));
      expect(def, containsAllInOrder(<String>['-crf', '20']));
      expect(def, isNot(contains('-q:v')));
      expect(def, isNot(contains('yuvj444p')));
      expect(def, isNot(contains('yuvj420p')));
    });

    // BUG-809：序列帧路径（逐句高亮跟随）是「30 秒 200MB」的主战场：动态路径把母帧按
    // 帧计划复制成大量连续重复帧，mjpeg 每帧都是独立整张 JPEG（无帧间压缩）故体积巨大；
    // libx264 的 P 帧把重复帧压到近零字节。TODO-2357 起移动端亦然。
    test('seq keeps interframe libx264 + faststart while reading frames', () {
      final List<String> args = buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: '/f',
        audioPath: '/a.aac',
        outputPath: '/o.mp4',
        fps: 24,
      );
      expect(args, containsAllInOrder(<String>['-c:v', 'libx264']));
      expect(args, containsAllInOrder(<String>['-crf', '20']));
      expect(args, containsAllInOrder(<String>['-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(<String>['-movflags', '+faststart']));
      // 仍读序列帧（-framerate），不退化成单图 -loop 1。
      expect(args, containsAllInOrder(<String>['-framerate', '24']));
      expect(args, isNot(contains('-loop')));
      // H.264 路径不掺 mjpeg 的 qscale。
      expect(args, isNot(contains('mjpeg')));
      expect(args, isNot(contains('-q:v')));
    });
  });

  group('computeClipTextLayout (TODO-945 M3 layout)', () {
    const Color bg = Color(0xFF101010);
    const Color fg = Color(0xFFF0F0F0);
    // TODO-1013：逐句高亮跟随色（sasayaki）——导出卡片当整句背景衬底。
    const Color highlight = Color(0x66FFCC00);

    test(
        'horizontal default output is landscape 1920x1080 (TODO-1147) and '
        'carries theme colors', () {
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 6,
        baseFontSize: 22,
        vertical: false,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      // TODO-1147 用户回访「分辨率不对」：横排文字默认横屏 1920×1080（此前统一
      // 竖屏 1080×1920）。像素总量不低于旧 1080×1920（防模糊守卫保持）。
      expect(layout.width, 1920);
      expect(layout.height, 1080);
      expect(layout.background, bg);
      expect(layout.foreground, fg);
      // TODO-1013：逐句高亮跟随色（sasayaki）必须原样透传给渲染层。
      expect(layout.highlight, highlight);
      expect(layout.vertical, isFalse);
    });

    test('vertical default output is portrait 1080x1920 (TODO-1147)', () {
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 6,
        baseFontSize: 22,
        vertical: true,
        lineHeight: 1.65,
        background: bg,
        foreground: fg,
        highlight: highlight,
      );
      // 竖排保持竖屏 1080×1920（默认手机竖屏标准尺寸，防模糊守卫保持）。
      expect(layout.width, 1080);
      expect(layout.height, 1920);
      expect(layout.vertical, isTrue);
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
