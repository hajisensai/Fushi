/// 漫画有声书「导出片段视频」（反馈 pZhONQTAap）：画面 = 那一句所在的漫画页（静止），
/// 音频 = 那一句的成品音频片段（与制卡句子音频同一套留白，见
/// [resolveMangaLineAudioClip]）。
///
/// 不另起一套 ffmpeg 管线：裁音频复用 [extractAudioSegmentViaFfmpeg]，页图重编码 JPEG
/// 复用 [encodeClipTextFrameAsJpgAsync]（BUG-543 的 JPEG 输入契约），图 + 音频合成复用
/// 小说有声书的 [synthAudiobookClipVideoViaFfmpeg]（全平台 H.264、显式 -map、按时长
/// `-t`、产物两路流核验），交付复用 `audiobook_clip_delivery.dart`。这里只做漫画特有
/// 的部分：按页图比例定输出尺寸、把几步串起来。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fushi_engine/media/video/ffmpeg_backend.dart'
    show FfmpegBackend;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show extractAudioSegmentViaFfmpeg;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_clip_export.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_mining.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 输出视频长边上限（与小说片段视频的 1080×1920 同一量级）。
const int kMangaClipVideoMaxSide = 1920;

/// 失败在哪一步（日志与测试用；用户看到的统一是「片段导出失败」）。
enum MangaAudioClipExportFailure {
  /// 页图读不出尺寸 / 重编码 JPEG 失败。
  pageImage,

  /// 裁句子音频失败。
  audioClip,

  /// 图 + 音频合成失败（详情见 [MangaAudioClipExportResult.synthFailure]）。
  synth,
}

/// 合成结果：成功带 [videoPath]（在调用方给的工作目录里），失败带 [failure]。
class MangaAudioClipExportResult {
  const MangaAudioClipExportResult.success(String this.videoPath)
    : failure = null,
      synthFailure = null;

  const MangaAudioClipExportResult.failure(
    MangaAudioClipExportFailure this.failure, {
    this.synthFailure,
  }) : videoPath = null;

  final String? videoPath;
  final MangaAudioClipExportFailure? failure;
  final AudiobookClipSynthFailure? synthFailure;

  bool get isSuccess => videoPath != null;
}

/// 按页图像素尺寸定输出视频尺寸：保持页图比例，长边不超过 [maxSide]（小图不放大），
/// 两边都取偶数（yuv420p 要求）且不小于 2。尺寸非法时退回 1080×1920 竖屏。
({int width, int height}) mangaClipVideoSize({
  required int imageWidth,
  required int imageHeight,
  int maxSide = kMangaClipVideoMaxSide,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) return (width: 1080, height: 1920);
  final double scale = math.min(
    1.0,
    maxSide / math.max(imageWidth, imageHeight),
  );
  int even(double v) => math.max(2, (v.floor() ~/ 2) * 2);
  return (width: even(imageWidth * scale), height: even(imageHeight * scale));
}

/// 裁音频这一步（生产 = [extractAudioSegmentViaFfmpeg]，测试注入假实现）。
typedef MangaClipAudioExtractor =
    Future<String?> Function({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
    });

Future<String?> _extractWithFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
}) => extractAudioSegmentViaFfmpeg(
  inputPath: inputPath,
  startMs: startMs,
  endMs: endMs,
  outputPath: outputPath,
);

/// 读编码图片的像素尺寸（只解析头，不解码像素）。读不出返回 null。
Future<({int width, int height})?> _encodedImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (width: descriptor.width, height: descriptor.height);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('MangaAudioClipExport.pageSize', error, stack);
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// 把 [pageBytes]（那一句所在页的原图字节，任意可解码格式）+ [clip]（那一句的成品
/// 音频区间）合成为 [workDir] 里的 `clip.mp4`。中间产物（`page.jpg` / `clip.aac`）
/// 无论成败都清掉；成品视频与 [workDir] 归调用方交付后清理。绝不对调用方抛。
Future<MangaAudioClipExportResult> synthMangaAudioClipVideo({
  required Uint8List pageBytes,
  required MangaMiningAudioClip clip,
  required Directory workDir,
  MangaClipAudioExtractor extractAudio = _extractWithFfmpeg,
  FfmpegBackend? backend,
}) async {
  final File image = File(p.join(workDir.path, 'page.jpg'));
  final File audio = File(p.join(workDir.path, 'clip.aac'));
  final String videoPath = p.join(workDir.path, 'clip.mp4');
  final int startMs = clip.range.startMs;
  final int endMs = clip.range.endMs;
  try {
    final ({int width, int height})? pageSize = await _encodedImageSize(
      pageBytes,
    );
    final Uint8List? jpg = pageSize == null
        ? null
        : await encodeClipTextFrameAsJpgAsync(pageBytes, quality: 92);
    if (pageSize == null || jpg == null) {
      ErrorLogService.instance.log(
        'MangaAudioClipExport.pageImage',
        'page image unusable (bytes=${pageBytes.length}, '
            'sized=${pageSize != null}, page=${clip.line.page})',
        StackTrace.current,
      );
      return const MangaAudioClipExportResult.failure(
        MangaAudioClipExportFailure.pageImage,
      );
    }
    await workDir.create(recursive: true);
    await image.writeAsBytes(jpg, flush: true);

    final String? audioPath = await extractAudio(
      inputPath: clip.inputPath,
      startMs: startMs,
      endMs: endMs,
      outputPath: audio.path,
    );
    if (audioPath == null) {
      ErrorLogService.instance.log(
        'MangaAudioClipExport.audioClip',
        'sentence audio clip failed (startMs=$startMs, endMs=$endMs, '
            'input=${clip.inputPath}, line=${clip.line.lineId})',
        StackTrace.current,
      );
      return const MangaAudioClipExportResult.failure(
        MangaAudioClipExportFailure.audioClip,
      );
    }

    final ({int width, int height}) size = mangaClipVideoSize(
      imageWidth: pageSize.width,
      imageHeight: pageSize.height,
    );
    final AudiobookClipSynthResult synth =
        await synthAudiobookClipVideoViaFfmpeg(
          imagePath: image.path,
          audioPath: audioPath,
          outputPath: videoPath,
          // BUG-2940：时长取裁音频用的同一对毫秒值，不靠 `-shortest`。
          durationMs: endMs - startMs,
          width: size.width,
          height: size.height,
          backend: backend,
          timeout: Duration(milliseconds: 3 * 60 * 1000 + (endMs - startMs)),
        );
    if (!synth.isSuccess) {
      ErrorLogService.instance.log(
        'MangaAudioClipExport.synth',
        'video synth failed: ${synth.failure} ${synth.detail ?? ''}',
        StackTrace.current,
      );
      return MangaAudioClipExportResult.failure(
        MangaAudioClipExportFailure.synth,
        synthFailure: synth.failure,
      );
    }
    return MangaAudioClipExportResult.success(videoPath);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('MangaAudioClipExport', error, stack);
    return const MangaAudioClipExportResult.failure(
      MangaAudioClipExportFailure.synth,
    );
  } finally {
    for (final File f in <File>[image, audio]) {
      try {
        if (await f.exists()) await f.delete();
      } on Object catch (_) {}
    }
  }
}
