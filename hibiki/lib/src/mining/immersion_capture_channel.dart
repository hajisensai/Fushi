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

/// BUG-1416：静态帧模式下「取片段里的哪一刻」。[offsetMs] 是**片段内偏移**（毫秒，t=0 起）。
///
/// [exact] = 这个偏移是由真实时间信息换算出来的（制卡时刻 / 句首的视频时间 − 片段时间基锚点）。
/// false = 换算所需的时间信息没随请求传下来（老版扩展），只能退到片段起点 —— 仍是静态帧（用户
/// 选的就是静态帧），但**不是**制卡那一刻的帧。调用方据此写诊断日志，不静默糊弄过去。
typedef ClipStillTarget = ({int offsetMs, bool exact});

/// 抽单帧的注入点（默认 [extractVideoFrameViaFfmpeg] 真身，测试注入假件）。逐参对齐真身。
///
/// 与 `immersion_mining_engine.dart` 的 `FrameExtractor` 分开声明，因为这条路必须显式下发
/// [decodeFromStart]：录制片段是无 Cues 索引的 MediaRecorder webm，输入定位取不准帧。
typedef ClipFrameExtractor = Future<String?> Function({
  required String inputPath,
  required String outputPath,
  double atSeconds,
  bool decodeFromStart,
  FfmpegFailureReporter? onFailure,
  String? tlsPinSha256,
});

/// 纯函数：把用户的图片模式偏好 + 请求里的三个**视频时间**换算成片段内偏移。可单测。
///
/// 返回 null = 不取静态帧（用户选动图）→ 调用方走既有动图链，行为逐字不变。
///
/// 三个时间同处「视频时间」基（`video.currentTime`），故减法直接成立；[clipAnchorMs] 是片段
/// t=0 对应的视频时间，由扩展实测下发（见 [ImmersionMinePayload.clipAnchorMs] —— 绝不能假设
/// 它等于句首，seek 落定/缓冲/起播推进量都在里面）。
///
/// 结果夹到 `[0, durationMs]`：durationMs 是墙钟时长，本就是真实时长的**上界**，夹取只挡住
/// 明显越界的脏输入，不引入偏移。
ClipStillTarget? resolveClipStillTarget({
  required VideoMiningImageMode imageMode,
  required int? clipAnchorMs,
  required int? cueStartMs,
  required int? mineAtMs,
  required int durationMs,
}) {
  if (!imageMode.isStill) return null;
  final int? targetVideoMs = switch (imageMode) {
    // 用户拍板：「按制卡时候的时间来」——制卡那一刻的视频时间，不是句首、更不是片段首帧。
    VideoMiningImageMode.currentFrame => mineAtMs,
    VideoMiningImageMode.subtitleStart => cueStartMs,
    VideoMiningImageMode.gif => null,
  };
  if (clipAnchorMs == null || targetVideoMs == null) {
    return (offsetMs: 0, exact: false);
  }
  final int raw = targetVideoMs - clipAnchorMs;
  final int upper = durationMs > 0 ? durationMs : 0;
  return (offsetMs: raw.clamp(0, upper), exact: true);
}

class ImmersionCaptureResult {
  const ImmersionCaptureResult({
    this.gifBytes,
    this.audioBytes,
    this.error,
    this.animatedFormat = MiningAnimatedFormat.gif,
    this.coverIsStill = false,
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

  /// BUG-1416：[gifBytes] 里装的是**单帧 JPEG**（用户选了静态帧），不是动图。
  ///
  /// 为什么不新开一个 `stillBytes` 字段：[gifBytes] 就是这条链路的「封面字节」通道，
  /// 分成两个字段会让每个下游都长出一对 if。字节走原通道，用这个布尔说明它是什么——
  /// 与 [animatedFormat] 同样是「实际产出物的自描述」。
  /// [animatedFormat] 在本值为 true 时不参与文件名（封面是 `.jpg`）。
  final bool coverIsStill;

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
  final bool coverFromCapture = useCapture && cap.gifBytes != null;
  final bool coverIsAnimated = coverFromCapture && !cap.coverIsStill;
  // BUG-1416：三种封面各自的名字（Anki 按扩展名判 MIME）。片段里抽的静态帧与 2A 截图都是
  // JPEG，但分开命名——媒体库里一眼看得出这张卡的封面是哪条路产出的。
  final String coverName = coverIsAnimated
      ? 'netflix_clip.${cap.animatedFormat.fileExtension}'
      : coverFromCapture
          ? 'netflix_frame.jpg'
          : 'netflix_shot.jpg';
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
    providedCoverName: coverName,
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
/// BUG-1416：[stillTarget] 非 null（用户选了静态帧）时**不编动图**，改在片段内
/// [ClipStillTarget.offsetMs] 处抽一帧 JPEG 当封面（音频照抽，两种模式一致）。用户拍板
/// 「肯定是按制卡时候的时间来」——所以取的不是片段首帧，而是制卡那一刻在片段里的位置。
/// 偏移换算见 [resolveClipStillTarget]；取帧走 `decodeFromStart`（录制片段无 Cues 索引，
/// 输入定位会落到最近关键帧）。
///
/// [gifExtractor] / [audioExtractor] / [frameExtractor] 供测试注入，默认指向 ffmpeg 真身。
Future<ImmersionCaptureResult> transcodeClipToCapture(
  Uint8List clipBytes, {
  required int durationMs,
  required MiningMediaCompression compression,
  required String tempDir,
  MiningAnimatedFormat format = MiningAnimatedFormat.gif,
  ClipStillTarget? stillTarget,
  GifExtractor gifExtractor = extractClipGifViaFfmpeg,
  AudioExtractor audioExtractor = extractAudioSegmentViaFfmpeg,
  ClipFrameExtractor frameExtractor = extractVideoFrameViaFfmpeg,
}) async {
  final Directory dir = Directory('$tempDir/nf_clip_${clipBytes.length}');
  await dir.create(recursive: true);
  try {
    final File clip = File('${dir.path}/clip.webm');
    await clip.writeAsBytes(clipBytes, flush: true);
    final int endMs = durationMs > 0 ? durationMs : 6000;
    // 静态帧模式：片段内定点抽一帧，**不进** extractAnimatedClipWithFallback（既是行为正确
    // 性，也避免顶格档动图编码那种大体积开销 —— 静态帧不吃 gifFps/gifWidth）。
    final String? framePath = stillTarget == null
        ? null
        : await frameExtractor(
            inputPath: clip.path,
            outputPath: '${dir.path}/clip_frame.jpg',
            atSeconds: stillTarget.offsetMs / 1000.0,
            decodeFromStart: true,
          );
    // 输出扩展名由每次尝试的格式补（ffmpeg 按扩展名选 muxer），故这里只给不含扩展名的前缀。
    final AnimatedClipExtraction? animated = stillTarget != null
        ? null
        : await extractAnimatedClipWithFallback(
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
    // 封面字节走同一个通道（[ImmersionCaptureResult.gifBytes]），是不是静态帧由
    // coverIsStill 说明——不为静态帧另开一条并行字段/分支。
    final String? coverPath = framePath ?? animated?.path;
    final Uint8List? cover =
        coverPath != null ? await File(coverPath).readAsBytes() : null;
    final Uint8List? audio =
        audioPath != null ? await File(audioPath).readAsBytes() : null;
    if (cover == null && audio == null) {
      return const ImmersionCaptureResult(
          error: 'clip transcode produced nothing');
    }
    return ImmersionCaptureResult(
      gifBytes: cover,
      audioBytes: audio,
      // 实际产出格式（可能已降级），不是用户所选。cover==null / 静态帧时不参与文件名。
      animatedFormat: animated?.format ?? MiningAnimatedFormat.gif,
      coverIsStill: framePath != null,
    );
  } catch (e) {
    return ImmersionCaptureResult(error: 'clip transcode failed: $e');
  } finally {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}
