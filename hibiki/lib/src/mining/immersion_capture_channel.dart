import 'dart:io';

import 'package:flutter/services.dart';

import 'package:hibiki/src/mining/immersion_mining_engine.dart'
    show
        AnimatedClipExtraction,
        AudioExtractor,
        GifExtractor,
        extractAnimatedClipWithFallback;
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;

/// 第二层B（TODO-1000）：驱动后台专用软解 WebView2 实例抓 Netflix 片段音画。仅 Windows。
/// native 缺失（未构建 / 非 Windows）时 [capture] 返回 error，seam 降级为 2A 截图卡。
abstract final class ImmersionCaptureChannel {
  static const MethodChannel _channel =
      MethodChannel('app.hibiki.reader/immersion_capture');

  static Future<ImmersionCaptureResult> capture({
    required String netflixVideoId,
    required int clipStartMs,
    required int clipEndMs,
    int fps = 8,
    int width = 320,
  }) async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'capture',
        <String, Object?>{
          'videoId': netflixVideoId,
          'startMs': clipStartMs,
          'endMs': clipEndMs,
          'fps': fps,
          'width': width,
        },
      );
      return ImmersionCaptureResult.fromMap(r ?? const <Object?, Object?>{});
    } on PlatformException catch (e) {
      return ImmersionCaptureResult(error: e.message ?? 'capture failed');
    } on MissingPluginException {
      return const ImmersionCaptureResult(
          error: 'immersion_capture unavailable');
    }
  }
}

class ImmersionCaptureResult {
  const ImmersionCaptureResult({
    this.gifBytes,
    this.audioBytes,
    this.error,
    this.animatedFormat = MiningAnimatedFormat.gif,
  });

  /// 动图封面字节。字段名与 MethodChannel 的 wire key `gifBytes` 一样是历史名，**不代表
  /// 内容一定是 GIF**——实际格式看 [animatedFormat]。wire key 是 native 契约，冻结不改。
  final Uint8List? gifBytes;
  final Uint8List? audioBytes;
  final String? error;

  /// [gifBytes] **实际被编码成的**格式（不是用户选的那个）。
  ///
  /// 必须随字节一起带出来：[transcodeClipToCapture] 在首选格式的编码器缺失时会降级 GIF，
  /// 调用方若按用户偏好拼文件名，就会写出 `netflix_clip.avif` 里装 GIF 字节的卡（Anki 按
  /// 扩展名判 MIME → 封面显示不出来）。与 galgame 侧 `GalWindowAnimatedCapture` 同形。
  ///
  /// 默认 [MiningAnimatedFormat.gif]：截图降级（无动图）与 native 后台实例路径都只可能
  /// 是 GIF，此时该字段不参与文件名（见 [buildImmersionRequest] 的 `coverIsAnimated`）。
  final MiningAnimatedFormat animatedFormat;

  bool get ok => error == null;

  /// native 后台软解实例（[ImmersionCaptureChannel.capture]）的 wire 契约里只有 GIF 字节，
  /// 没有格式字段 —— 那条链路的编码在 native 侧写死 GIF。故这里恒取默认 gif，不去猜。
  /// 将来 native 支持多格式时，在 wire 上补 `format` 键并在此解析。
  static ImmersionCaptureResult fromMap(Map<Object?, Object?> m) =>
      ImmersionCaptureResult(
        gifBytes: m['gifBytes'] as Uint8List?,
        audioBytes: m['audioBytes'] as Uint8List?,
        error: m['error'] as String?,
      );
}

/// 纯函数：给定 payload + 后台抓取结果 → 引擎请求。可单测降级逻辑。
///
/// [cap] `ok` 时优先用后台抓的 GIF/音频（GIF 缺则回落截图）；失败时降级为 2A 截图卡
/// （无音频，requireAudio=false 不中止）。任何情况下 mediaSource=null（Netflix 无本地源）。
///
/// TODO-1303：[audioExpected] 由调用方按来源判定「这条来源本应带音频」——录制片段
/// （[ImmersionMinePayload.clipBytes] 非空，Netflix 播放必有音轨）恒为 true。为 true 时
/// [requireAudio]=true → 引擎在最终无音频（转码/抓取丢音轨）时中止，不再静默降级成无声
/// 卡还报成功（「只本应有音频却失败才算失败」）。为 false（2A 截图卡 / 后台软解不可用）时
/// [requireAudio]=false → 截图卡本就无音频，不算失败。旧实现按 `audio != null` 推 requireAudio
/// 是自毁的——音频恰好丢时反而关掉了守卫。
ImmersionMiningRequest buildImmersionRequest(
  ImmersionMinePayload p,
  ImmersionCaptureResult cap, {
  required bool audioExpected,
}) {
  final bool useCapture = cap.ok;
  final Uint8List? cover =
      useCapture ? (cap.gifBytes ?? p.screenshotBytes) : p.screenshotBytes;
  final bool coverIsAnimated = useCapture && cap.gifBytes != null;
  final Uint8List? audio = useCapture ? cap.audioBytes : null;
  return ImmersionMiningRequest(
    fields: p.fields,
    mediaSource: null,
    clipStartMs: 0,
    clipEndMs: 0,
    sentence: p.sentence,
    cueSentence: p.cueSentence,
    documentTitle: p.documentTitle ?? 'Netflix',
    source: AnkiMiningSource.video,
    providedCoverBytes: cover,
    // 扩展名跟随**实际产出格式**，不是用户所选：编码器缺失时捕获内部已降级 GIF，按所选
    // 格式拼名会写出 `.avif` 里装 GIF 字节的卡（Anki 按扩展名判 MIME → 封面不显示）。
    providedCoverName: coverIsAnimated
        ? 'netflix_clip.${cap.animatedFormat.fileExtension}'
        : 'netflix_shot.jpg',
    providedAudioBytes: audio,
    providedAudioName: audio == null
        ? null
        : 'netflix_audio.${immersionMiningAudioExtension()}',
    requireAudio: audioExpected,
  );
}

/// TODO-1000：把浏览器扩展在播放中录到的字幕片段（webm/mp4 字节）用 ffmpeg 转 GIF + 抽音频，
/// 组成 [ImmersionCaptureResult]（Netflix 唯一「不回放」的 GIF 来源）。复用已验证的
/// [extractClipGifViaFfmpeg] / [extractAudioSegmentViaFfmpeg]。
/// 转码失败（黑帧/无音轨/ffmpeg 不可用）返回 error，seam 降级为截图卡。
///
/// 录到的片段本身即整句：扩展 Netflix 批量录制 seek 到句首 → 播到字幕变化(=句末)停录，片段边界
/// 即句子边界；且全自动回放（无查词交互、光标/字幕已隐藏），帧里本就无鼠标/弹窗。故整段转码
/// [0, durationMs]，不做段内窗裁剪。
/// V16#4：之前本函数的段内时间窗 + GIF 收口偏移参数是无来源死代码（扩展 mineClip 从不发这些偏
/// 移，Netflix clip 一直回落整段），已删。若将来加入「实时查词捕获」模型（非批量、播放中查词冻结
/// 帧），届时再重新引入段内句子窗 + GIF 收口到查词交互前的偏移；批量录制路径不适用。
///
/// [format] 是用户的动图格式偏好（`video_mining_animated_format`）。这条链路过去把输出
/// 硬写成 `clip.gif` 且不传 format，导致扩展制卡恒出 GIF、完全不吃偏好；现在与 app 内
/// 视频、YouTube 共用 [extractAnimatedClipWithFallback]，格式与编码参数成对下发，编码器
/// 缺失（移动端 ffmpeg-kit 无 libsvtav1/libwebp）时自动降级 GIF 并**同时换回 GIF 的封顶
/// 参数**，产出格式经 [ImmersionCaptureResult.animatedFormat] 带回给文件名。
///
/// [gifExtractor] / [audioExtractor] 供测试注入，默认指向 ffmpeg 真身。
Future<ImmersionCaptureResult> transcodeClipToCapture(
  Uint8List clipBytes, {
  required int durationMs,
  required MiningMediaCompression compression,
  required String tempDir,
  MiningAnimatedFormat format = MiningAnimatedFormat.gif,
  GifExtractor gifExtractor = extractClipGifViaFfmpeg,
  AudioExtractor audioExtractor = extractAudioSegmentViaFfmpeg,
}) async {
  final Directory dir = Directory('$tempDir/nf_clip_${clipBytes.length}');
  await dir.create(recursive: true);
  try {
    final File clip = File('${dir.path}/clip.webm');
    await clip.writeAsBytes(clipBytes, flush: true);
    final int endMs = durationMs > 0 ? durationMs : 6000;
    // 输出扩展名由每次尝试的格式补（ffmpeg 按扩展名选 muxer），故这里只给不含扩展名的前缀。
    final AnimatedClipExtraction? animated =
        await extractAnimatedClipWithFallback(
      format: format,
      inputPath: clip.path,
      startMs: 0,
      endMs: endMs,
      outputPathStem: '${dir.path}/clip',
      compression: compression,
      extractor: gifExtractor,
    );
    final String? audioPath = await audioExtractor(
      inputPath: clip.path,
      startMs: 0,
      endMs: endMs,
      outputPath: '${dir.path}/clip.${immersionMiningAudioExtension()}',
      audioChannels: compression.audioChannels,
      audioBitrate: compression.audioBitrate,
    );
    final Uint8List? gif =
        animated != null ? await File(animated.path).readAsBytes() : null;
    final Uint8List? audio =
        audioPath != null ? await File(audioPath).readAsBytes() : null;
    if (gif == null && audio == null) {
      return const ImmersionCaptureResult(
          error: 'clip transcode produced nothing');
    }
    return ImmersionCaptureResult(
      gifBytes: gif,
      audioBytes: audio,
      // 实际产出格式（可能已降级），不是用户所选。gif==null 时不参与文件名。
      animatedFormat: animated?.format ?? MiningAnimatedFormat.gif,
    );
  } catch (e) {
    return ImmersionCaptureResult(error: 'clip transcode failed: $e');
  } finally {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}
