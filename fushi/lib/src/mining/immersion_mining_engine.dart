import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/mining/serial_job_queue.dart';

/// 注入式抽取器（默认指向 desktop_audio_clipper.dart 真身，测试注入假件）。逐参对齐真身。
typedef GifExtractor = Future<String?> Function({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int fps,
  int width,
  MiningAnimatedFormat format,
  bool diagnosticOnly,
  FfmpegFailureReporter? onFailure,
  String? tlsPinSha256,
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
  String? tlsPinSha256,
});
typedef FrameExtractor = Future<String?> Function({
  required String inputPath,
  required String outputPath,
  double atSeconds,
  FfmpegFailureReporter? onFailure,
  String? tlsPinSha256,
});

/// TODO-1314（B5）：把远端 audio-only DASH 流物化到本地临时文件（yt-dlp 式 range 分片下载）
/// 的注入点。默认指向 [materializeRemoteAudioViaRangeDownload] 真身；测试注入假件。
typedef RemoteAudioMaterializer = Future<String?> Function({
  required String audioUrl,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
});

/// 动图抽取产物：文件路径 + **实际编码成的格式**。
///
/// 格式必须与路径一起带出来，不能让调用方按「用户选了什么」去拼文件名——
/// [extractAnimatedClipWithFallback] 内部会在首选格式编码失败时降级 GIF，两者可以不一致。
/// 按所选格式拼名就会写出 `netflix_clip.avif` 里装着 GIF 字节的卡：Anki 按扩展名判 MIME，
/// 图片直接显示不出来。与 galgame 侧的 `GalWindowAnimatedCapture` 同形。
typedef AnimatedClipExtraction = ({String path, MiningAnimatedFormat format});

/// 把 `[startMs, endMs)` 抽成动图，按 [format] 自己声明的降级链（[MiningAnimatedFormat
/// .encodeAttempts]）逐个尝试：首选用户所选格式，失败换 GIF 再试一次。
///
/// 这不是「重试掩盖症状」——两次调用的**参数不同**，第二次是能力降级：移动端 ffmpeg-kit
/// 与旧版捆绑 ffmpeg 没有 libsvtav1 / libwebp 编码器（见 `tool/ffmpeg-min/
/// build-ffmpeg-min.sh`），首选格式必然失败而 GIF 恒可用。降级只做一级。
///
/// **格式与编码参数成对**：每次尝试的 fps / 宽度 / 输出扩展名一律取自 `attempt` 自己
/// （[MiningAnimatedFormat.capFps] / [MiningAnimatedFormat.capWidth] /
/// [MiningAnimatedFormat.fileExtension]），绝不沿用上一次尝试的值。[compression] 的
/// `gifFps`/`gifWidth` 在顶格档是按**用户所选格式**解析出来的（AVIF = 24fps/1440px），
/// 原样转喂 GIF 就是 BUG-1039 复发。夹取对三种格式、四个档位一致（低档的有限值本就低于
/// 任何上限，代入后不变），不是「谁是特例」的分支。
///
/// [outputPathStem] 是**不含扩展名**的输出路径前缀，扩展名由每次尝试的格式补上（ffmpeg
/// 按扩展名选 muxer）。三条来路（app 内视频 / YouTube / Netflix 录制片段）共用本函数，
/// 不各持一份会漂开的循环。[extractor] 供测试注入。
///
/// 全部尝试都失败返回 null，调用方据此走各自的下一级降级（单帧截图等）。
Future<AnimatedClipExtraction?> extractAnimatedClipWithFallback({
  required MiningAnimatedFormat format,
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPathStem,
  required MiningMediaCompression compression,
  GifExtractor extractor = extractClipGifViaFfmpeg,
  FfmpegFailureReporter? onFailure,
  String? tlsPinSha256,
}) async {
  final List<MiningAnimatedFormat> attempts = format.encodeAttempts;
  for (final MiningAnimatedFormat attempt in attempts) {
    final String? out = await extractor(
      inputPath: inputPath,
      startMs: startMs,
      endMs: endMs,
      outputPath: '$outputPathStem.${attempt.fileExtension}',
      fps: attempt.capFps(compression.gifFps),
      width: attempt.capWidth(compression.gifWidth),
      format: attempt,
      // 还有降级尝试在后面 → 这次失败是预期内的能力探测，只记诊断日志（否则捆绑
      // ffmpeg 缺编码器时，每制一张卡都往用户可见错误日志里塞一条「错误」）。
      diagnosticOnly: attempt != attempts.last,
      onFailure: onFailure,
      tlsPinSha256: tlsPinSha256,
    );
    if (out != null) return (path: out, format: attempt);
  }
  return null;
}

/// BUG-1664：中止原因 = 症状 + 根因。[symptom] 是稳定的机器可读短语（既有调用方/测试
/// 按它断言，前缀不变 → Never break userspace），[rootCause] 是抽取层已经算好的精确
/// 摘要（ffmpeg 启动失败 / 非零退出 + stderr 等）。根因为空（真没抽取过，如 provided
/// 字节路径丢音轨）时原样返回症状，与旧行为逐字相同。
///
/// 截断到 [_kRootCauseMaxChars]：这串会经 `/api/mine` 的 `message` 一路走到浏览器
/// 扩展的 toast，ffmpeg 的 stderr 摘要可能很长，整段糊上去反而没人看。
String _withRootCause(String symptom, String? rootCause) {
  final String cause = rootCause?.trim() ?? '';
  if (cause.isEmpty) return symptom;
  final String clipped = cause.length > _kRootCauseMaxChars
      ? '${cause.substring(0, _kRootCauseMaxChars)}…'
      : cause;
  return '$symptom ($clipped)';
}

/// 见 [_withRootCause]：拼进中止原因的根因摘要上限。
const int _kRootCauseMaxChars = 300;

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

  /// 所有沉浸制卡共享同一条事务队列。抽媒体会写固定的临时文件名，AnkiConnect 也只有
  /// 一个 GUI 端点；必须把「抽 GIF/音频 → 上传 → add/update note」整体串行化。队列是
  /// 进程级而非页面级，因此本地 pushReplacement 或远端原地换集都不会丢掉已入队任务。
  static final SerialJobQueue _sharedMiningQueue = SerialJobQueue();

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

  /// BUG-1205 — 封面与句子音频是两条**互不依赖**的 ffmpeg 抽取，历史实现串行 await
  /// （封面阶梯跑完才开始抽音频），耗时直接相加。用户把「图片/GIF 清晰度」调到最高档时
  /// GIF 单项就要数秒（BUG-1039 实测：4 秒区间 6 秒 / 7.7 MB），串行让整次制卡雪上加霜。
  /// 现在音频在封面阶梯**之前**启动、末尾才 await，两条重叠，总耗时 ≈ max 而非 sum。
  ///
  /// [onCoverFailure] / [onAudioFailure] 是 BUG-1205 的另一半：调用方过去靠 **onFailure
  /// 的调用顺序**区分「首个=GIF 失败、末个=音频失败」（lookup_mining.part.dart 的
  /// `gifFailure ??= summary`）。并行后顺序不再确定，靠顺序区分必然串味——故按**来源**
  /// 分流，语义由参数名承载而不是时序。[onFailure] 保留为「任一来源」的合流回调，既有
  /// 调用点（app_model 的 YouTube/Netflix、gal coordinator）零改动。
  Future<ImmersionMiningResult> mine(
    ImmersionMiningRequest req, {
    required MiningMediaCompression compression,
    required FutureOr<String> tempDir,
    required BaseAnkiRepository repo,
    FfmpegFailureReporter? onFailure,
    FfmpegFailureReporter? onCoverFailure,
    FfmpegFailureReporter? onAudioFailure,
  }) {
    final ImmersionMiningRequest frozenRequest = req.frozen();
    return _sharedMiningQueue.enqueueRethrowing<ImmersionMiningResult>(
      () async {
        final String resolvedTempDir = await tempDir;
        return _mineNow(
          frozenRequest,
          compression: compression,
          tempDir: resolvedTempDir,
          repo: repo,
          onFailure: onFailure,
          onCoverFailure: onCoverFailure,
          onAudioFailure: onAudioFailure,
        );
      },
    );
  }

  Future<ImmersionMiningResult> _mineNow(
    ImmersionMiningRequest req, {
    required MiningMediaCompression compression,
    required String tempDir,
    required BaseAnkiRepository repo,
    FfmpegFailureReporter? onFailure,
    FfmpegFailureReporter? onCoverFailure,
    FfmpegFailureReporter? onAudioFailure,
  }) async {
    String? coverPath;
    bool degradedToStill = false;

    // 按来源分流的两个上报口：各自先喂专属回调，再合流进 [onFailure]（保持既有语义）。
    // BUG-1664：两个上报口流经的**精确**失败摘要（含 `ffmpeg launch failed:
    // executable=ffmpeg; errorCode=2; message=No such file or directory`）过去只
    // 进调用方的诊断日志，中止却回一句常量 'required audio missing'——症状而非根因。
    // 结果：macOS/Linux 上没有 ffmpeg 时，浏览器扩展批量制卡整批失败，用户（和排查
    // 的人）只能看到「已处理 0 · 失败 N」，必须翻到沙盒容器里的 error_log.txt 才知道
    // 是缺 ffmpeg。这里就地留存**首个**摘要（首个最接近根因；后续多为它的连锁反应），
    // 供下方 abort 时并进 abortReason，让根因一路走到用户眼前。
    String? firstCoverFailure;
    String? firstAudioFailure;

    void reportCover(String summary) {
      firstCoverFailure ??= summary;
      onCoverFailure?.call(summary);
      onFailure?.call(summary);
    }

    void reportAudio(String summary) {
      firstAudioFailure ??= summary;
      onAudioFailure?.call(summary);
      onFailure?.call(summary);
    }

    if (req.providedCoverBytes != null) {
      coverPath = await _writeBytes(
          tempDir,
          req.providedCoverName ?? 'immersion_cover.gif',
          req.providedCoverBytes!);
    }

    final String? src = req.mediaSource;

    // 三种封面来源封成本地闭包（各自带前置守卫，源不可用即返 null）。三个 [VideoMiningImageMode]
    // 只是它们的不同优先级排列，把原来手写的三段 `if (coverPath == null && ...)` 阶梯归一成
    // 「一张优先级表」——GIF 模式排列与旧代码逐字等价（Never break userspace），静态模式只是
    // 换个排列且不置 degradedToStill（用户主动选静态图，非降级）。
    //
    // 抽字幕区间动图（GIF）到临时文件；无 src / 无区间 → null。
    Future<String?> tryGif() async {
      if (src == null || !req.hasRange) return null;
      // 首选用户所选格式、失败降级 GIF 的那条链（含每次尝试重新夹取 fps/宽度/扩展名）
      // 收在 [extractAnimatedClipWithFallback] 里，与 Netflix 录制片段共用同一份实现。
      // GIF 也失败才轮到下面既有的单帧降级阶梯。
      final AnimatedClipExtraction? animated =
          await extractAnimatedClipWithFallback(
        format: req.animatedFormat,
        inputPath: src,
        startMs: req.clipStartMs,
        endMs: req.clipEndMs,
        outputPathStem: '$tempDir/immersion_clip',
        compression: compression,
        extractor: _gif,
        onFailure: reportCover,
        tlsPinSha256: req.mediaSourceTlsPinSha256,
      );
      return animated?.path;
    }

    // 抽字幕 cue 起始时间点的单帧；无 src → null。
    Future<String?> tryStartFrame() async {
      if (src == null) return null;
      return _frame(
        inputPath: src,
        outputPath: '$tempDir/immersion_frame.jpg',
        atSeconds: req.clipStartMs / 1000.0,
        onFailure: reportCover,
        tlsPinSha256: req.mediaSourceTlsPinSha256,
      );
    }

    // 当前解码帧（`controller.screenshot`，点词已自动暂停）→ 降采样写盘；无 stillFallback → null。
    Future<String?> tryCurrentFrame() async {
      if (req.stillFallback == null) return null;
      final Uint8List? shot = await req.stillFallback!();
      if (shot == null) return null;
      // BUG-933：降采样（decode/resize/encodeJpg）卸到后台 isolate，避免 1080p/4K
      // 截图的纯 Dart CPU 重活阻塞 UI 线程（制卡「未响应」根因之一）。
      final Uint8List small = await downsampleCardScreenshotAsync(
        shot,
        maxLongEdge: compression.screenshotMaxLongEdge,
        quality: compression.screenshotQuality,
      );
      return _writeBytes(tempDir, 'immersion_shot.jpg', small);
    }

    // BUG-1205 — 音频抽取与下面的封面阶梯**无任何数据依赖**，故在此先启动、末尾才
    // await：两条 ffmpeg 重叠跑，总耗时从「封面 + 音频」变成「max(封面, 音频)」。
    // 封面阶梯内部的优先级顺序（GIF → 起点帧 → 当前帧）完全不动——那才是真依赖。
    //
    // catchError 把异常暂存后照常在末尾重抛：不这样的话，封面阶梯若先抛出，这个已在
    // 途的 Future 就成了 unhandled async error（Flutter 下直接上报成崩溃）。暂存 +
    // 重抛保持与串行版逐字一致的抛出语义。
    final String? audioSrc = req.audioSource ?? src;
    Object? audioError;
    StackTrace? audioStack;
    final Future<String?> audioFuture = _resolveAudioPath(
      req,
      compression: compression,
      tempDir: tempDir,
      audioSrc: audioSrc,
      reportAudio: reportAudio,
    ).catchError((Object e, StackTrace st) {
      audioError = e;
      audioStack = st;
      return null;
    });

    if (coverPath == null) {
      switch (req.imageMode) {
        case VideoMiningImageMode.gif:
          // 现状阶梯：GIF 主 → 起点单帧降级 → 当前帧兜底（逐字等价于旧三段 if）。
          coverPath = await tryGif();
          if (coverPath == null) {
            coverPath = await tryStartFrame();
            if (coverPath != null) degradedToStill = true;
          }
          if (coverPath == null) {
            coverPath = await tryCurrentFrame();
            // 无区间(无cue)截当前帧不算降级，不弹「降级为静态」OSD。
            if (coverPath != null) degradedToStill = req.hasRange;
          }
        case VideoMiningImageMode.subtitleStart:
          // 用户选「字幕开头截图」：起点单帧优先，失败退当前帧。主动选静态图，非降级。
          coverPath = await tryStartFrame();
          coverPath ??= await tryCurrentFrame();
        case VideoMiningImageMode.currentFrame:
          // 用户选「制卡时截图」：当前解码帧优先，失败退起点单帧。主动选静态图，非降级。
          coverPath = await tryCurrentFrame();
          coverPath ??= await tryStartFrame();
      }
    }

    // BUG-1205：收割上面已并行跑完的音频抽取（异常在此重抛，语义与串行版一致）。
    final String? audioPath = await audioFuture;
    if (audioError != null) {
      Error.throwWithStackTrace(audioError!, audioStack!);
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
      return ImmersionMiningResult(
          aborted: true,
          abortReason:
              _withRootCause('required audio missing', firstAudioFailure));
    }
    // TODO-1303：空壳卡兜底——既无封面又无音频（截图/GIF/音频全失败），不建卡。这正是
    // 「降级空壳卡仍报成功」的根：任何来源下都不该产出无媒体的卡。
    if (coverPath == null && audioPath == null) {
      // 封面与音频**都**没出来时，两条链的首个摘要通常是同一个根因（例如 ffmpeg 缺失
      // 会同时打死两条）。取封面优先只是取一个稳定顺序，null 时自动退到音频那条。
      return ImmersionMiningResult(
          aborted: true,
          abortReason: _withRootCause('no cover and no audio produced',
              firstCoverFailure ?? firstAudioFailure));
    }

    final AnkiMiningContext context = AnkiMiningContext(
      sentence: req.sentence,
      cueSentence: req.cueSentence,
      documentTitle: req.documentTitle,
      coverPath: coverPath,
      sentenceAudioPath: audioPath,
      source: req.source,
      bookTitleTag: req.bookTitleTag,
      collectionTag: req.collectionTag,
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

  /// BUG-1205 — 句子音频落地路径的解析，从 [mine] 内联体**原样**抽出（provided 字节 →
  /// 互联 host 端裁 → ffmpeg-over-URL，逐行不变），只为让它能作为一个 Future 与封面阶梯
  /// 并行。这里不做任何策略改动：所有既有优先级、回退和临时文件清理都保持原样。
  ///
  /// [audioSrc] 由调用方按「独立 audioSource（YouTube 分离音频流）优先，否则视频源」算好。
  Future<String?> _resolveAudioPath(
    ImmersionMiningRequest req, {
    required MiningMediaCompression compression,
    required String tempDir,
    required String? audioSrc,
    required FfmpegFailureReporter reportAudio,
  }) async {
    String? audioPath;
    if (req.providedAudioBytes != null) {
      return _writeBytes(
          tempDir,
          req.providedAudioName ??
              'immersion_audio.${immersionMiningAudioExtension()}',
          req.providedAudioBytes!);
    }
    if (audioSrc == null || !req.hasRange) return null;

    // BUG-1004：互联 host（LAN Hibiki 库）远端流优先走 **host 端裁**——host 用本地文件裁好
    // 句子音频再经已鉴权/钉扎的下载通道回传，client 全程不用 ffmpeg 抓远端流，从根上绕开
    // 「client ffmpeg 打不开 host 自签 https / token 流」的整类失败（见 BUG-891 残余缺口：
    // 移动端自编 ffmpeg-kit 的 TLS pin 仍会因指纹缺失/URL 编码/网络脆弱而 I/O error）。命中
    // 远端 http(s) 源且注入了裁切器时先试；成功即用，返回 null（老 host 无 clipaudio 端点/
    // 网络失败）则落到下方现有 ffmpeg-over-URL 抽取（Never break userspace）。
    if (req.remoteAudioClipper != null && _isRemoteHttp(audioSrc)) {
      audioPath = await req.remoteAudioClipper!(
        startMs: req.clipStartMs,
        endMs: req.clipEndMs,
        // host 裁出的是 adts aac；命名 .aac 与内容一致（AnkiDroid/桌面直收）。
        outputPath: '$tempDir/immersion_audio_host.aac',
      );
    }
    // host 端裁未命中（非互联 host / 老 host 无 clipaudio 端点 / 裁切失败）时回退现有
    // ffmpeg-over-URL 抽取（YouTube 物化 + 直连 ffmpeg 抽取，含 BUG-891 的 tls pin）。
    if (audioPath != null) return audioPath;

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
        onFailure: reportAudio,
      );
      if (materialized != null) cutInput = materialized;
    }
    audioPath = await _audio(
      inputPath: cutInput,
      startMs: req.clipStartMs,
      endMs: req.clipEndMs,
      outputPath: '$tempDir/immersion_audio.${immersionMiningAudioExtension()}',
      audioStreamIndex: req.audioStreamIndex,
      audioStreamCount: req.audioStreamCount,
      audioChannels: compression.audioChannels,
      audioBitrate: compression.audioBitrate,
      onFailure: reportAudio,
      // BUG-891：cutInput 若是物化后的本地文件（YouTube）pin 被 buildFfmpegRemoteInputArgs
      // 的远端判定忽略；Hibiki muxed 时 cutInput 是远端 https host，pin 生效。
      tlsPinSha256: req.mediaSourceTlsPinSha256,
    );
    // 物化的整段音频临时文件用完即删（裁好的 immersion_audio.* 才是产物）。
    if (materialized != null) {
      try {
        File(materialized).deleteSync();
      } catch (_) {}
    }
    return audioPath;
  }

  Future<String> _writeBytes(String dir, String name, Uint8List bytes) async {
    final File f = File('$dir/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }
}
