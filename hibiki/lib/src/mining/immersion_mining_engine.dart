import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';

/// 注入式抽取器（默认指向 desktop_audio_clipper.dart 真身，测试注入假件）。逐参对齐真身。
typedef GifExtractor = Future<String?> Function({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int fps,
  int width,
  FfmpegFailureReporter? onFailure,
});
typedef AudioExtractor = Future<String?> Function({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  FfmpegFailureReporter? onFailure,
  int audioChannels,
  String audioBitrate,
});
typedef FrameExtractor = Future<String?> Function({
  required String inputPath,
  required String outputPath,
  double atSeconds,
  FfmpegFailureReporter? onFailure,
});

/// TODO-1314（B5）：把远端 audio-only DASH 流物化到本地临时文件（yt-dlp 式 range 分片下载）
/// 的注入点。默认指向 [materializeRemoteAudioViaRangeDownload] 真身；测试注入假件。
typedef RemoteAudioMaterializer = Future<String?> Function({
  required String audioUrl,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
});

/// 统一沉浸制卡引擎。降级阶梯与 `_mineVideoCard`（lookup_mining.part.dart L285-441）一致：
/// GIF 主 → 单帧降级 → 当前解码帧兜底；音频段；requireAudio 且缺音频则中止；组 context 落卡。
///
/// 媒体抽取全走「输入路径/URL + 毫秒」，绝不 seek/干扰前台播放器。
class ImmersionMiningEngine {
  ImmersionMiningEngine({
    GifExtractor? gifExtractor,
    AudioExtractor? audioExtractor,
    FrameExtractor? frameExtractor,
    RemoteAudioMaterializer? audioMaterializer,
  })  : _gif = gifExtractor ?? extractClipGifViaFfmpeg,
        _audio = audioExtractor ?? extractAudioSegmentViaFfmpeg,
        _frame = frameExtractor ?? extractVideoFrameViaFfmpeg,
        _materialize = audioMaterializer ?? _defaultAudioMaterializer;

  final GifExtractor _gif;
  final AudioExtractor _audio;
  final FrameExtractor _frame;
  final RemoteAudioMaterializer _materialize;

  /// 默认物化器：包一层 [materializeRemoteAudioViaRangeDownload]（补齐其额外可选参数）。
  static Future<String?> _defaultAudioMaterializer({
    required String audioUrl,
    required String outputPath,
    FfmpegFailureReporter? onFailure,
  }) =>
      materializeRemoteAudioViaRangeDownload(
        audioUrl: audioUrl,
        outputPath: outputPath,
        onFailure: onFailure,
      );

  /// 纯函数：判断 [s] 是否为远端 http(s) 输入（audio-only DASH 分离流 URL）。
  static bool _isRemoteHttp(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  Future<ImmersionMiningResult> mine(
    ImmersionMiningRequest req, {
    required MiningMediaCompression compression,
    required String tempDir,
    required BaseAnkiRepository repo,
    FfmpegFailureReporter? onFailure,
  }) async {
    String? coverPath;
    bool degradedToStill = false;

    if (req.providedCoverBytes != null) {
      coverPath = await _writeBytes(
          tempDir,
          req.providedCoverName ?? 'immersion_cover.gif',
          req.providedCoverBytes!);
    }

    final String? src = req.mediaSource;

    if (coverPath == null && src != null && req.hasRange) {
      coverPath = await _gif(
        inputPath: src,
        startMs: req.clipStartMs,
        endMs: req.clipEndMs,
        outputPath: '$tempDir/immersion_clip.gif',
        fps: compression.gifFps,
        width: compression.gifWidth,
        onFailure: onFailure,
      );
    }
    if (coverPath == null && src != null) {
      final String? framePath = await _frame(
        inputPath: src,
        outputPath: '$tempDir/immersion_frame.jpg',
        atSeconds: req.clipStartMs / 1000.0,
        onFailure: onFailure,
      );
      if (framePath != null) {
        coverPath = framePath;
        degradedToStill = true;
      }
    }
    if (coverPath == null && req.stillFallback != null) {
      final Uint8List? shot = await req.stillFallback!();
      if (shot != null) {
        final Uint8List small = downsampleCardScreenshot(
          shot,
          maxLongEdge: compression.screenshotMaxLongEdge,
          quality: compression.screenshotQuality,
        );
        coverPath = await _writeBytes(tempDir, 'immersion_shot.jpg', small);
        // 无区间(无cue)截当前帧不算降级，不弹「降级为静态」OSD。
        degradedToStill = req.hasRange;
      }
    }

    // 音频段抽取源：优先独立 audioSource（YouTube 分离音频流），否则用视频源（本地/muxed）。
    final String? audioSrc = req.audioSource ?? src;
    String? audioPath;
    if (req.providedAudioBytes != null) {
      audioPath = await _writeBytes(
          tempDir,
          req.providedAudioName ??
              'immersion_audio.${immersionMiningAudioExtension()}',
          req.providedAudioBytes!);
    } else if (audioSrc != null && req.hasRange) {
      // TODO-1314（B5）：audio-only DASH 分离流（req.audioSource 非空且为远端 http = YouTube
      // 分离音频轨）的 ffmpeg HTTP `-ss` seek 会被 googlevideo 限速 stall→120s 超时→无句子音频
      // （TODO-1301 曾用 muxed 绕行）。改为先用 yt-dlp 式 range 分片下载把整段音频物化到本地
      // 临时文件、再对**本地文件**裁——本地 seek 即时、无网络 stall，根治 audio-only 不可 seek，
      // 去掉对 muxed 的硬依赖。muxed 路径（audioSource==null → audioSrc==mediaSource，HTTP seek
      // 只下小段、效率更高）不走物化、保持不变。物化失败回退直接对 URL 裁（best-effort，不劣于旧）。
      String cutInput = audioSrc;
      String? materialized;
      if (req.audioSource != null && _isRemoteHttp(req.audioSource!)) {
        materialized = await _materialize(
          audioUrl: req.audioSource!,
          outputPath: '$tempDir/immersion_audio_src',
          onFailure: onFailure,
        );
        if (materialized != null) cutInput = materialized;
      }
      audioPath = await _audio(
        inputPath: cutInput,
        startMs: req.clipStartMs,
        endMs: req.clipEndMs,
        outputPath:
            '$tempDir/immersion_audio.${immersionMiningAudioExtension()}',
        audioStreamIndex: req.audioStreamIndex,
        audioStreamCount: req.audioStreamCount,
        audioChannels: compression.audioChannels,
        audioBitrate: compression.audioBitrate,
        onFailure: onFailure,
      );
      // 物化的整段音频临时文件用完即删（裁好的 immersion_audio.* 才是产物）。
      if (materialized != null) {
        try {
          File(materialized).deleteSync();
        } catch (_) {}
      }
    }

    // TODO-1303：无音频中止——需要音频却最终没有音轨（不建无音频卡）。音频来自两条路：
    //   ① 区间抽取路径（[hasRange]，YouTube/本地视频）——抽取失败 → audioPath==null。
    //   ② provided 字节路径（Netflix 录制片段/后台软解，无 range 但有 providedCoverBytes）
    //      ——本应带 [providedAudioBytes] 却为空（转码/抓取丢音轨）→ audioPath==null。
    // 两条都要中止，回带原因供远端制卡写错误日志 + 回传诊断（BUG：制卡失败报成功）。
    // in-app 视频「无 cue」路径（requireAudio 默认 true、无 range、走 stillFallback、
    // providedCoverBytes==null）不落任一分支 → 不中止，仍出静帧卡（Never break userspace）。
    final bool viaProvidedBytes =
        req.providedCoverBytes != null && !req.hasRange;
    if (req.requireAudio &&
        audioPath == null &&
        (req.hasRange || viaProvidedBytes)) {
      return const ImmersionMiningResult(
          aborted: true, abortReason: 'required audio missing');
    }
    // TODO-1303：空壳卡兜底——既无封面又无音频（截图/GIF/音频全失败），不建卡。这正是
    // 「降级空壳卡仍报成功」的根：任何来源下都不该产出无媒体的卡。
    if (coverPath == null && audioPath == null) {
      return const ImmersionMiningResult(
          aborted: true, abortReason: 'no cover and no audio produced');
    }

    final AnkiMiningContext context = AnkiMiningContext(
      sentence: req.sentence,
      cueSentence: req.cueSentence,
      documentTitle: req.documentTitle,
      coverPath: coverPath,
      sasayakiAudioPath: audioPath,
      source: req.source,
      bookTitleTag: req.bookTitleTag,
    );

    final MineOutcome outcome = req.updateNoteId == null
        ? await repo.mineEntry(
            rawPayloadJson: jsonEncode(req.fields), context: context)
        : await repo.updateMinedNote(
            noteId: req.updateNoteId!,
            rawPayloadJson: jsonEncode(req.fields),
            context: context);

    return ImmersionMiningResult(
        aborted: false, outcome: outcome, degradedToStill: degradedToStill);
  }

  Future<String> _writeBytes(String dir, String name, Uint8List bytes) async {
    final File f = File('$dir/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }
}
