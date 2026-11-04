import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/mining/external_window_mining.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/adts_duration.dart';
import 'package:fushi/src/lookup/gal_ingame_mining_binding.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';
import 'package:fushi/src/mining/galgame_window_video.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/mining_image_mode_target.dart';
import 'package:fushi_engine/media/image_mosaic.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi/src/mining/serial_job_queue.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/pages/implementations/dictionary_webview_media.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

typedef GalHookGifCapture =
    Future<GalWindowAnimatedCapture?> Function({
      required int hwnd,
      MiningAnimatedFormat format,
    });
typedef GalHookStillCapture = Future<WindowCaptureResult> Function(int hwnd);
typedef GalHookTempDirectoryFactory = Future<Directory> Function();
typedef GalHookLineLookup = TexthookerLineEntry? Function(String lineId);
typedef GalHookLineValidator = bool Function(TexthookerLineEntry entry);
typedef GalHookSessionStateLoader = GalHookSessionState Function();
typedef GalHookAudioCapture =
    Future<Uint8List?> Function({
      required String lineId,
      required String sentence,
      required String outputExtension,
    });

/// 该台词行到达时刻（hook 侧 tick 毫秒域，与录制帧同一时钟）；无时间戳返回 null。
typedef GalHookLineTimestampLookup = int? Function(String lineId);

/// 把会话录制环里 `[fromTickMs, toTickMs]` 的帧导出成 JPEG 文件（`toTickMs <= 0` =
/// 现在）。生产指向 [WindowCaptureChannel.exportWindowRecording]。
typedef GalHookRecordingExport =
    Future<WindowRecordingExport> Function({
      required int fromTickMs,
      required int toTickMs,
      required String directory,
    });

/// 录制帧 + 句子音频 → 片段（格式见 [MiningClipFormat]）。生产指向
/// [buildGalWindowVideoClip]；测试注入假编码器。
typedef GalHookVideoClipBuilder =
    Future<GalWindowVideoClip?> Function({
      required WindowRecordingExport export,
      required int? fromTickMs,
      required int toTickMs,
      Uint8List? audioBytes,
      required String audioExtension,
      required Directory workDir,
      required MiningClipFormat format,
    });

/// Host-owned screenshot frozen while this exact line was current.
class GalHookLineScreenshot {
  GalHookLineScreenshot({required this.lineId, required Uint8List pngBytes})
    : pngBytes = Uint8List.fromList(pngBytes).asUnmodifiableView();

  final String lineId;
  final Uint8List pngBytes;
}

class GalHookMiningResult {
  const GalHookMiningResult({
    this.outcome,
    this.failureReason,
    this.sentenceAudioMissing = false,
    this.degradedToStill = false,
    this.degradedToAnimated = false,
    this.staleScene = false,
    this.audioFallbackDisabled = false,
    this.unmappedTokens = const <String>[],
  });

  final MineOutcome? outcome;
  final String? failureReason;
  final bool sentenceAudioMissing;
  final bool degradedToStill;

  /// 用户选了「视频片段」但片段没做出来（录制未启动 / 帧不足 2 张 / ffmpeg 失败），
  /// 退回动图成卡时置真。再退到静图时置的是 [degradedToStill]（两者互斥）。
  final bool degradedToAnimated;

  /// 制卡的是**历史行**（非当前最新行）时置真：画面截图只能抓 mine 时刻的当前窗口帧，
  /// 无法重建历史行当时的画面，故显式标注「画面可能与该台词不对应」，供调用方提示用户
  /// （BUG-955：禁止把当前画面冒充成历史台词的画面而不告知）。
  final bool staleScene;
  final bool audioFallbackDisabled;
  final List<String> unmappedTokens;

  bool get aborted => outcome == null;
  bool get success => outcome?.result == MineResult.success;

  /// BUG-1908：制卡失败是不是**因为 Anki 里已经有这张卡**。见
  /// `MinePopupResult.duplicate` —— 浮窗据它区分「卡已存在」与「真的没制成」，
  /// 不必回查 Anki（TODO-448 禁止失败后回查把按钮翻成 ✓）。
  bool get duplicate => outcome?.result == MineResult.duplicate;

  /// 后端暂不可达（或批量制卡），卡进了本机待发队列、之后补发。浮窗画 ✓ 不回查
  /// （popup.js `reply.queued`），也不带失败原因——卡没有丢。
  bool get queued => outcome?.result == MineResult.queued;

  /// BUG-1908：[message] 是**失败时给用户看的原因**，由调用方（浮窗控制器）填入
  /// 已本地化的文案。
  ///
  /// 此前这个回程只有两个字段，宿主即便算出了「没选卡组 / 字段映射对不上 / 截图
  /// 失败」也没地方放；浮窗那边 `ankiConnect:false` 是正常 resolve、不抛，
  /// 既不进 catch 也不进 if —— 整段没有 else，用户零反馈。而 galgame 浮窗是独立的
  /// native WebView2 窗口，宿主的 Flutter toast 画在主 app 窗口的 Overlay 上，
  /// 游戏全屏时主窗在后台，那些 toast 一个也看不见。
  Map<String, Object?> toPopupReply({String? message}) => <String, Object?>{
    'ankiConnect': success,
    'noteId': success ? outcome?.noteId : null,
    if (!success && !queued && message != null && message.isNotEmpty)
      'message': message,
    if (duplicate) 'duplicate': true,
    if (queued) 'queued': true,
  };
}

/// Hook 场景卡的唯一编排入口。
///
/// 整个作业（精确行校验、画面、句音、媒体缓存、Anki 写入）串行执行且使用独立临时
/// 目录。任何一步都只消费 [lineId] 对应的数据，禁止回退到最新行或最新声音。
class GalHookMiningCoordinator {
  GalHookMiningCoordinator({
    GalHookSessionController? session,
    TexthookerService? textService,
    ImmersionMiningEngine? engine,
    GalHookGifCapture? captureGif,
    GalHookStillCapture? captureStill,
    GalHookTempDirectoryFactory? createTempDirectory,
    GalHookLineLookup? lineLookup,
    GalHookLineValidator? lineValidator,
    GalHookSessionStateLoader? stateLoader,
    GalHookAudioCapture? captureAudio,
    GalHookLineTimestampLookup? lineTimestampLookup,
    GalHookRecordingExport? exportRecording,
    GalHookVideoClipBuilder? buildVideoClip,
  }) : _session = session ?? GalHookSessionController.instance,
       _textService = textService ?? TexthookerService.instance,
       _engine = engine ?? ImmersionMiningEngine(),
       _captureGif = captureGif ?? _defaultCaptureGif,
       _captureGifUsesDefault = captureGif == null,
       _captureStill = captureStill ?? WindowCaptureChannel.captureWindow,
       _createTempDirectory =
           createTempDirectory ?? _defaultCreateTempDirectory,
       _exportRecording =
           exportRecording ?? WindowCaptureChannel.exportWindowRecording,
       _buildVideoClip = buildVideoClip ?? _defaultBuildVideoClip {
    _lineLookup = lineLookup ?? _textService.entryById;
    _lineValidator = lineValidator ?? _session.isLineInCurrentSession;
    _stateLoader = stateLoader ?? (() => _session.state);
    _captureAudio = captureAudio ?? _session.captureAudioBytes;
    _lineTimestampLookup = lineTimestampLookup ?? _session.lineTimestampMs;
  }

  static final GalHookMiningCoordinator instance = GalHookMiningCoordinator();

  final GalHookSessionController _session;
  final TexthookerService _textService;
  final ImmersionMiningEngine _engine;
  final GalHookGifCapture _captureGif;
  final bool _captureGifUsesDefault;
  final GalHookStillCapture _captureStill;
  final GalHookTempDirectoryFactory _createTempDirectory;
  final GalHookRecordingExport _exportRecording;
  final GalHookVideoClipBuilder _buildVideoClip;
  late final GalHookLineLookup _lineLookup;
  late final GalHookLineValidator _lineValidator;
  late final GalHookSessionStateLoader _stateLoader;
  late final GalHookAudioCapture _captureAudio;
  late final GalHookLineTimestampLookup _lineTimestampLookup;

  /// 采样阶段（行校验、窗口像素、句音启动）：串行，同一时刻只有一个作业读游戏窗口，
  /// 游戏内查词层的 capture lease 也就不会重叠。
  final SerialJobQueue _captureQueue = SerialJobQueue();

  /// 收尾阶段（动图编码、句音收口、词典媒体、写卡）：串行、按采样顺序执行，但与
  /// 采样队列解耦——上一张卡还在编码 / 写库时，下一张卡的画面照常立刻采。
  final SerialJobQueue _finishQueue = SerialJobQueue();

  static Future<GalWindowAnimatedCapture?> _defaultCaptureGif({
    required int hwnd,
    MiningAnimatedFormat format = MiningAnimatedFormat.gif,
  }) => captureWindowGifBytes(hwnd: hwnd, format: format);

  static Future<GalWindowVideoClip?> _defaultBuildVideoClip({
    required WindowRecordingExport export,
    required int? fromTickMs,
    required int toTickMs,
    Uint8List? audioBytes,
    required String audioExtension,
    required Directory workDir,
    required MiningClipFormat format,
  }) => buildGalWindowVideoClip(
    export: export,
    fromTickMs: fromTickMs,
    toTickMs: toTickMs,
    audioBytes: audioBytes,
    audioExtension: audioExtension,
    workDir: workDir,
    format: format,
  );

  static Future<Directory> _defaultCreateTempDirectory() =>
      Directory.systemTemp.createTemp('fushi-gal-card-job-');

  /// 单帧截图落卡前统一降采样。
  ///
  /// BUG-1473：这里以前把 `still.pngBytes` **原样**送进 Anki——1080p/4K 的无压缩
  /// PNG 通常 1.5~4 MB，而 `compression` 参数明明已经从调用方传进来了却没被用上。
  /// 视频侧同一动作走的就是 [downsampleCardScreenshotAsync]（BUG-933 把 decode/
  /// resize/encode 卸到后台 isolate，避免纯 Dart CPU 重活阻塞 UI 线程）。
  /// 语义与视频侧一致：小图/解不开时原样返回，绝不返回空。
  /// 返回 (字节, 文件名)。**文件名按实际产出的字节定**，不按意图定：
  /// [downsampleCardScreenshotAsync] 在「图本来就小 / 解不开」时**原样返回入参 PNG**，
  /// 此时若硬拼 `.jpg`，Anki 按扩展名判 MIME 就会得到「.jpg 里装 PNG」→ 图不显示。
  /// 这与本文件动图那处「文件名一律取实际产出格式」是同一条规矩。
  static Future<({Uint8List? bytes, String name})> _downsampleStill(
    Uint8List? pngBytes,
    MiningMediaCompression compression,
    MiningStillFormat stillFormat,
  ) async {
    if (pngBytes == null || pngBytes.isEmpty) {
      return (bytes: pngBytes, name: 'external_window.png');
    }
    final Uint8List out = await downsampleCardScreenshotAsync(
      pngBytes,
      maxLongEdge: compression.screenshotMaxLongEdge,
      quality: compression.screenshotQuality,
      encoding: cardScreenshotEncodingFor(stillFormat),
    );
    // 文件名仍按**实际字节**定（[stillFormatOfBytes] 就是原来手写的魔数判定，收口到
    // 一处）：降采样解不开时会原样返回入参，此时硬拼 `.jpg` 就是「.jpg 里装 PNG」。
    // 兜底 png——这条链的入参恒为窗口抓图的 PNG，与视频侧（media_kit JPEG）方向相反。
    final MiningStillFormat produced = stillFormatOfBytes(
      out,
      fallback: MiningStillFormat.png,
    );
    return (bytes: out, name: 'external_window.${produced.fileExtension}');
  }

  /// 在降采样**之前**给窗口截图打码（块大小按原图算，与对话框预览一致）。产物是
  /// PNG（截图本就是 PNG，无损），之后照常经 [_downsampleStill] 按质量档缩放编码。
  /// 解不开返回 null。
  static Future<Uint8List?> _mosaicStill(
    Uint8List? pngBytes,
    List<MiningMosaicRegion> mosaic,
  ) async {
    if (pngBytes == null || pngBytes.isEmpty) return null;
    final MosaicEncodedImage? out = await mosaicEncodedImageAsync(
      pngBytes,
      mosaic,
    );
    if (out == null) {
      ErrorLogService.instance.logDiagnostic(
        'GalHookMiningCoordinator.mosaic',
        'still not decodable, card image omitted',
      );
    }
    return out?.bytes;
  }

  /// 高级制卡对话框打开时冻结当前绑定窗口的一帧（对话框里预览 / 打码用）。没有绑定
  /// 窗口 / 抓图失败返回 null。不进制卡队列：只是一次只读截图。
  Future<Uint8List?> captureBoundWindowStill() async {
    final ExternalWindowInfo? window = _stateLoader().boundWindow;
    if (window == null) return null;
    try {
      final WindowCaptureResult still = await _captureStill(window.hwnd);
      return still.ok ? still.pngBytes : null;
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'GalHookMiningCoordinator.captureBoundWindowStill',
        error,
        stack,
      );
      return null;
    }
  }

  Future<GalHookMiningResult> mineLine({
    required String lineId,
    required Map<String, String> fields,
    String? sentenceOverride,
    GalIngameMiningBinding? occurrence,
    required MiningMediaCompression compression,
    required BaseAnkiRepository repo,
    int? updateNoteId,
    bool addTitleTag = false,
    // 缺省 gif = 旧行为逐字等价（Never break userspace）；调用方透传
    // [AppModel.galMiningImageMode]。
    VideoMiningImageMode imageMode = VideoMiningImageMode.gif,
    // 缺省 gif = 旧行为逐字等价；调用方透传 [AppModel.galMiningAnimatedFormat]（默认 avif）。
    MiningAnimatedFormat animatedFormat = MiningAnimatedFormat.gif,
    // 静图编码格式。缺省 jpg = 旧行为（BUG-1473 起 gal 截图就走降采样重编码 JPEG）；
    // 调用方透传 [AppModel.galMiningStillFormat]。
    MiningStillFormat stillFormat = MiningStillFormat.jpg,
    // 音画同步片段格式。缺省 mp4 = 旧行为；调用方透传 [AppModel.galMiningClipFormat]。
    MiningClipFormat clipFormat = MiningClipFormat.mp4H264,
    // 仅游戏内嵌 popup 的制卡入口传入。普通 texthooker/浮窗制卡没有画在游戏窗口
    // 里的查词层，不需要也不应触发这条屏障。
    GalHookCaptureLeaseFactory? captureLeaseFactory,
    GalHookLineScreenshot? providedLineScreenshot,
    // 高级制卡「打码」：相对那一帧截图的归一化区域。非空时只出静图，且在降采样前
    // 打码（见 [_mosaicStill]）；空 = 旧行为逐字等价。
    List<MiningMosaicRegion> mosaic = const <MiningMosaicRegion>[],
    // 高级制卡对话框打开时为这一行冻结的截图（对话框里打码看的就是它）。只在
    // [mosaic] 非空时使用：出卡图与预览必须是同一张图。
    GalHookLineScreenshot? previewStill,
  }) async {
    GalHookMiningResult failure(Object error, StackTrace stack) =>
        GalHookMiningResult(failureReason: error.toString());
    void logFailure(Object error, StackTrace stack) => ErrorLogService.instance
        .log('GalHookMiningCoordinator.mineLine', error, stack);
    // 两段队列都是「串行 + 永不毒化」（BUG-956）：单次制卡异常（含错误日志自身抛）
    // 不得让后续制卡永久挂起。
    //
    // 反馈 U9k4hlYaNZ / EJhUrX_mHY：以前整张卡（采样 + 句音收口 + ffmpeg 编码 + 写卡）
    // 是**一个**串行作业，第二张卡的画面要等第一张卡写完才开始抓——连续挖词时后一张
    // 卡等上十几秒，抓到的早已是别的台词，或者游戏内查词卡已经关了直接失败。现在只有
    // 必须在台词仍在屏上时做的采样留在 [_captureQueue]；收尾在 [_finishQueue] 里按
    // 采样顺序后台执行，采样队列不等它。
    final _PendingSceneCard pending = await _captureQueue
        .enqueue<_PendingSceneCard>(
          () async {
            final ({GalHookMiningResult? done, _SceneJob? job}) captured =
                await _captureSceneNow(
                  lineId: lineId,
                  fields: fields,
                  sentenceOverride: sentenceOverride,
                  occurrence: occurrence,
                  compression: compression,
                  repo: repo,
                  updateNoteId: updateNoteId,
                  addTitleTag: addTitleTag,
                  preferredImageMode: imageMode,
                  animatedFormat: animatedFormat,
                  stillFormat: stillFormat,
                  clipFormat: clipFormat,
                  captureLeaseFactory: captureLeaseFactory,
                  providedLineScreenshot: providedLineScreenshot,
                  mosaic: List<MiningMosaicRegion>.unmodifiable(mosaic),
                  previewStill: previewStill,
                );
            final _SceneJob? job = captured.job;
            if (job == null) {
              return _PendingSceneCard(
                Future<GalHookMiningResult>.value(captured.done!),
              );
            }
            // 在采样作业**之内**同步入队收尾：收尾顺序严格等于采样顺序，不靠
            // 调用方 continuation 的微任务先后。
            return _PendingSceneCard(
              _finishQueue.enqueue<GalHookMiningResult>(
                () => _finishSceneNow(job),
                buildFailure: failure,
                onError: logFailure,
              ),
            );
          },
          buildFailure: (Object error, StackTrace stack) => _PendingSceneCard(
            Future<GalHookMiningResult>.value(failure(error, stack)),
          ),
          onError: logFailure,
        );
    return pending.result;
  }

  /// 采样阶段：行校验、画面像素、句音启动。只做必须在这句台词仍在屏上时完成的事；
  /// 编码与写卡交给 [_finishSceneNow]。返回 `done`（已有结论，多为失败）或 `job`。
  Future<({GalHookMiningResult? done, _SceneJob? job})> _captureSceneNow({
    required String lineId,
    required Map<String, String> fields,
    required String? sentenceOverride,
    required GalIngameMiningBinding? occurrence,
    required MiningMediaCompression compression,
    required BaseAnkiRepository repo,
    required int? updateNoteId,
    required bool addTitleTag,
    required VideoMiningImageMode preferredImageMode,
    required MiningAnimatedFormat animatedFormat,
    required MiningStillFormat stillFormat,
    required MiningClipFormat clipFormat,
    required GalHookLineScreenshot? providedLineScreenshot,
    required GalHookCaptureLeaseFactory? captureLeaseFactory,
    required List<MiningMosaicRegion> mosaic,
    required GalHookLineScreenshot? previewStill,
  }) async {
    ({GalHookMiningResult? done, _SceneJob? job}) done(
      GalHookMiningResult result,
    ) => (done: result, job: null);

    final TexthookerLineEntry? entry = _lineLookup(lineId);
    if (entry == null || !_lineValidator(entry)) {
      return done(
        const GalHookMiningResult(
          failureReason: 'captured line is no longer available',
        ),
      );
    }
    if (providedLineScreenshot != null &&
        (providedLineScreenshot.lineId != entry.id ||
            providedLineScreenshot.pngBytes.isEmpty)) {
      return done(
        const GalHookMiningResult(
          failureReason: 'screenshot does not match captured line',
        ),
      );
    }
    if (mosaic.isNotEmpty &&
        previewStill != null &&
        (previewStill.lineId != entry.id || previewStill.pngBytes.isEmpty)) {
      // 打码位置是在那张预览图上框的：换了一行就不是同一张图，不能把码打到别的画面上。
      return done(
        const GalHookMiningResult(
          failureReason: 'screenshot does not match captured line',
        ),
      );
    }
    final GalHookSessionState state = _stateLoader();
    final ExternalWindowInfo? window = state.boundWindow;
    bool occurrenceIsCurrent() {
      if (occurrence == null) return true;
      final GalHookSessionState current = _stateLoader();
      return occurrence.resolve(
            currentSessionStartedAt: current.sessionStartedAt,
            currentTargetHwnd: current.boundWindow?.hwnd,
            selectedLines: _session.selectedSessionLines,
          ) ==
          entry.id;
    }

    if (!occurrenceIsCurrent()) {
      return done(
        const GalHookMiningResult(
          failureReason: 'captured occurrence is no longer available',
        ),
      );
    }
    if (!state.externalWindowMode || window == null) {
      return done(
        const GalHookMiningResult(failureReason: 'game window is not bound'),
      );
    }

    // 游戏内 TextRender 命中拿到的是屏上净句；选中的文本线程可能带脚本文件名、
    // hook 元数据或整句重复。lineId 仍负责锁定截图/音频生命周期，但卡片正文必须
    // 优先使用命中时的净句，不能把传感器载荷写进 Sentence。
    final String effectiveSentence = sentenceOverride?.trim().isNotEmpty == true
        ? sentenceOverride!.trim()
        : entry.text;
    final Map<String, String> effectiveFields = Map<String, String>.from(fields)
      ..['sentence'] = effectiveSentence;

    // BUG-955：截图只能抓 mine 时刻的当前窗口帧。若制卡的是历史行（非当前最新行），当前帧
    // 无法代表该台词当时的画面——显式标注 staleScene，不静默把当前画面冒充成旧台词的画面。
    final List<TexthookerLineEntry> liveEntries = _textService.entries;
    final bool staleScene =
        providedLineScreenshot == null &&
        (liveEntries.isEmpty || liveEntries.last.id != entry.id);
    if (staleScene) {
      ErrorLogService.instance.log(
        'GalHookMiningCoordinator.mineLine',
        'stale scene: mining historical line ${entry.id}; captured frame is '
            'the current window, not the frame at that line',
        StackTrace.current,
      );
    }

    // 单帧截图：GIF 模式下是降级路径，静态模式下是**主路径**。两条路径共用同一份
    // 诊断留痕（BUG-1096：WGC 光标抑制是否生效 / 是否从 Magpie 缩放窗重定向回源窗）。
    Future<WindowCaptureResult> captureStillWithDiagnostics() async {
      final WindowCaptureResult still = await _captureWithLease(
        captureLeaseFactory,
        () => _captureStill(window.hwnd),
      );
      final String? diagnostics = still.diagnostics;
      if (diagnostics != null && diagnostics.isNotEmpty) {
        ErrorLogService.instance.log(
          'galHookMineLine',
          'window capture diagnostics: $diagnostics',
          StackTrace.current,
        );
      }
      return still;
    }

    GalHookMiningResult captureFailed(WindowCaptureResult still) =>
        GalHookMiningResult(
          failureReason: still.error ?? 'game window capture failed',
        );

    // BUG-1473 — 语音抓取与下面的封面阶梯**无任何数据依赖**，故在此先启动、
    // 拿到封面后才 await：总耗时从「封面 + 音频」变成「max(封面, 音频)」。
    //
    // 视频侧 BUG-1205 已经这么做了，但 gal 走的是 providedCoverBytes /
    // providedAudioBytes 分支——进引擎时两者都已经在这个协调器里串行做完了，
    // 引擎里的并行对 gal 完全是空转。真正该并行的位置在这里。
    //
    // [_SceneAudio] 把异常暂存、取值时重抛：不这样的话封面阶梯若先抛，这个在途 Future
    // 就成了 unhandled async error（Flutter 下直接上报成崩溃）。暂存 + 重抛保持
    // 与串行版逐字一致的抛出语义。
    final String audioExtension = immersionMiningAudioExtension();
    final _SceneAudio audio = _SceneAudio(
      occurrence != null
          ? _session.captureAudioForOccurrence(
              occurrence: occurrence,
              outputExtension: audioExtension,
            )
          : _captureAudio(
              lineId: entry.id,
              // sentenceOverride only changes card text, not audio identity.
              sentence: entry.text,
              outputExtension: audioExtension,
            ),
    );
    final Future<Uint8List?> audioFuture = audio.future;

    // 同步片段只在目标模板原样渲染图片字段时可用（[resolveTargetMiningImageMode]）；
    // 必须在决定录片段还是录动图**之前**求值。主机冻结的台词帧不看模式，不必问。
    // 打了码只出静图（主机冻结帧 / 对话框预览帧 / 现抓一帧），不问模板、不录动图片段。
    final VideoMiningImageMode imageMode =
        providedLineScreenshot != null || mosaic.isNotEmpty
        ? preferredImageMode
        : await resolveTargetMiningImageMode(preferredImageMode, repo: repo);
    final _SceneCover cover = _SceneCover();
    if (mosaic.isNotEmpty) {
      // 打码：源图优先级 = 主机冻结的台词帧 > 对话框预览时冻结的那一帧 > 现抓。
      // 前两者保证「对话框里看到并打码的那张」就是进卡的那张。打码与降采样在收尾做。
      Uint8List? source =
          providedLineScreenshot?.pngBytes ?? previewStill?.pngBytes;
      if (source == null) {
        final WindowCaptureResult still = await captureStillWithDiagnostics();
        if (!still.ok) return done(captureFailed(still));
        source = still.pngBytes;
      }
      cover.stillPng = source;
      cover.mosaic = mosaic;
    } else if (providedLineScreenshot != null) {
      // Remote mining must never recapture a later scene, including through
      // the GIF/video fallback ladder. Only the host's frozen line frame enters.
      cover.stillPng = providedLineScreenshot.pngBytes;
    } else if (imageMode.isVideoClip) {
      // 视频片段：先收音频再定终点——片段必须覆盖到语音播完（captureAudio 在台词
      // 语音结束后才返回），而且音频要混流进 mp4，两件事都要求这里先 await。
      // 这与上面「音频与封面并行」不矛盾：并行只对动图 / 静图那两条链成立。
      //
      // 片段失败要在**这里**就知道，才能当场退回动图 / 静图阶梯（那两条要抓的是此刻
      // 的画面），所以片段的录制导出与混流都留在采样阶段。
      final Uint8List? earlyAudio = await audio.value();
      final GalWindowVideoClip? clip = await _captureVideoClip(
        lineId: entry.id,
        // 历史行（staleScene）的片段终点必须是**这一行不再是当前行的那一刻**，也就是
        // 下一行的时间戳。用 0（= 现在）会把从那句到现在的所有后续台词画面全拼进
        // mp4——用户拿到的是一段跑马灯，而不是那句话的画面。这与上面 staleScene 的
        // 记账是同一件事的两半：那半只是标注「画面不是当时的」，这半才真的把范围收住。
        toTickMs: _historicalLineEndTickMs(entry, liveEntries),
        audioBytes: earlyAudio,
        audioExtension: audioExtension,
        format: clipFormat,
      );
      if (clip != null) {
        cover.readyBytes = clip.bytes;
        cover.readyName = 'external_window.${clip.extension}';
        cover.synchronizedClip = clip.hasAudio;
      }
      // 片段没做出来（录制未启动 / 帧不足 / ffmpeg 失败）：退回既有动图 → 静图阶梯。
    }
    if (cover.decided) {
      // 视频片段 / 打码源图 / 主机冻结帧已就位，不再走动图 / 静图。
    } else if (imageMode.isStill) {
      // 用户主动选静态截图：直接抓单帧，**不**先试 GIF。galgame 一句台词内画面基本
      // 静止，动图多半只是把同一帧存二十遍，白白撑大卡片。这不是降级，故不置
      // degradedToStill，也就不会弹「已降级为静态图」的提示（与视频侧同语义）。
      final WindowCaptureResult still = await captureStillWithDiagnostics();
      if (!still.ok) return done(captureFailed(still));
      cover.stillPng = still.pngBytes;
    } else {
      if (_captureGifUsesDefault) {
        // 生产 GIF 路径把 lease 精确放进连续 WGC 采样循环：最后一帧落盘就恢复，
        // 不把后续可能耗时 60 秒的 ffmpeg 编码算作「正在截图」。编码本身在收尾阶段。
        //
        // 动图要覆盖整句：音频与画面本就并行采集，把「本句音频时长」作为异步目标
        // 喂给采样循环——资源音频立刻可知（按 ADTS 帧头读），引擎 PCM 要等语音
        // 播完；未知期间循环继续采样，正是语音在播的那段画面。时长写在行条目上
        // （[TexthookerService.updateLineAudio]），音频字节回来后再读一次条目。
        final Future<Duration?> targetDuration = audioFuture.then((
          Uint8List? bytes,
        ) {
          if (bytes == null || bytes.isEmpty) return null;
          final int? durationMs = occurrence == null
              ? _lineLookup(lineId)?.audioDurationMs
              : adtsDurationMs(bytes);
          return durationMs == null || durationMs <= 0
              ? null
              : Duration(milliseconds: durationMs);
        });
        final GalWindowAnimationFrames? frames =
            await sampleWindowAnimationFrames(
              hwnd: window.hwnd,
              captureLeaseFactory: captureLeaseFactory,
              targetDuration: targetDuration,
            );
        if (frames != null) {
          cover.frames = frames;
          cover.animatedFormat = animatedFormat;
          // 用户要的是视频片段，拿到的会是动图：是降级，与静图降级分开标。
          cover.degradedToAnimated = imageMode.isVideoClip;
        }
      } else {
        // 测试/替代捕获器保留原有二参数 typedef；它没有可观察的「采样完成、开始
        // 编码」边界，只能把注入的捕获 Future 当成一个采样单元。
        final GalWindowAnimatedCapture? animated = await _captureWithLease(
          captureLeaseFactory,
          () => _captureGif(hwnd: window.hwnd, format: animatedFormat),
        );
        // 文件名一律取**实际产出格式**而非用户所选：捕获内部会在编码器缺失时降级 GIF，
        // 按所选格式拼名会写出 `.avif` 里装 GIF 字节的卡（Anki 按扩展名判 MIME → 图不显示）。
        if (animated != null && animated.bytes.isNotEmpty) {
          cover.readyBytes = animated.bytes;
          cover.readyName = 'external_window.${animated.format.fileExtension}';
          cover.degradedToAnimated = imageMode.isVideoClip;
        }
      }
      if (!cover.decided) {
        final WindowCaptureResult still = await captureStillWithDiagnostics();
        if (!still.ok) return done(captureFailed(still));
        cover.stillPng = still.pngBytes;
        cover.degradedToStill = true;
        cover.degradedToAnimated = false;
      }
    }

    return (
      done: null,
      job: _SceneJob(
        entry: entry,
        effectiveSentence: effectiveSentence,
        effectiveFields: effectiveFields,
        window: window,
        state: state,
        occurrenceIsCurrent: occurrenceIsCurrent,
        staleScene: staleScene,
        audio: audio,
        audioExtension: audioExtension,
        cover: cover,
        compression: compression,
        stillFormat: stillFormat,
        repo: repo,
        updateNoteId: updateNoteId,
        addTitleTag: addTitleTag,
      ),
    );
  }

  /// 收尾阶段：编码封面、等句音收口、词典媒体落盘、写卡。在 [_finishQueue] 里按采样
  /// 顺序后台执行；采样阶段持有的帧目录在这里（含异常路径）释放。
  Future<GalHookMiningResult> _finishSceneNow(_SceneJob job) async {
    try {
      return await _finishSceneOwned(job);
    } finally {
      await job.cover.dispose();
    }
  }

  Future<GalHookMiningResult> _finishSceneOwned(_SceneJob job) async {
    final _SceneCover cover = job.cover;
    Uint8List? coverBytes = cover.readyBytes;
    String coverName = cover.readyName ?? 'external_window.gif';
    bool degradedToStill = cover.degradedToStill;
    bool degradedToAnimated = cover.degradedToAnimated;
    Uint8List? stillSource = cover.stillPng;
    final GalWindowAnimationFrames? frames = cover.frames;
    if (frames != null) {
      final GalWindowAnimatedCapture? animated =
          await encodeWindowAnimationFrames(
            frames,
            format: cover.animatedFormat,
          );
      if (animated != null && animated.bytes.isNotEmpty) {
        coverBytes = animated.bytes;
        coverName = 'external_window.${animated.format.fileExtension}';
      } else {
        // 编码失败（ffmpeg 缺失 / 超时）：用采样时 lease 之内抓到的第一帧降级成静图。
        // 不在此刻重抓窗口——收尾可能排在别的卡后面，此刻的画面早已不是这句台词。
        try {
          stillSource = await frames.firstFrame.readAsBytes();
        } on FileSystemException catch (error, stack) {
          ErrorLogService.instance.log(
            'GalHookMiningCoordinator.firstFrameFallback',
            error,
            stack,
          );
          return const GalHookMiningResult(
            failureReason: 'game window capture failed',
          );
        }
        degradedToStill = true;
        degradedToAnimated = false;
      }
    }
    if (coverBytes == null && stillSource != null) {
      if (cover.mosaic.isNotEmpty) {
        final Uint8List? masked = await _mosaicStill(stillSource, cover.mosaic);
        // masked == null：打码失败，这张卡不带图（绝不退回没打码的原图）。
        if (masked != null) {
          final ({Uint8List? bytes, String name}) shrunk =
              await _downsampleStill(masked, job.compression, job.stillFormat);
          coverBytes = shrunk.bytes;
          coverName = shrunk.name;
        }
      } else {
        final ({Uint8List? bytes, String name}) shrunk = await _downsampleStill(
          stillSource,
          job.compression,
          job.stillFormat,
        );
        coverBytes = shrunk.bytes;
        coverName = shrunk.name;
      }
    }

    // 视频片段分支已经 await 过同一个 Future；对已完成的 Future 再 await 只是取值。
    final Uint8List? audioBytes = await job.audio.value();
    final bool sentenceAudioMissing = audioBytes == null || audioBytes.isEmpty;
    // 只有最严格的 resourceOnly 才因为「没抓到音频」拒绝制卡。cleanOnly 的立场是
    // 「这句本来就没配音很正常」——旁白/心理描写句照样成卡，只是不带音频；把它也
    // 拦成制卡失败，等于逼用户在「收一段 BGM」和「这张卡做不了」之间二选一。
    if (sentenceAudioMissing &&
        job.state.audioFallbackPolicy.blocksMiningWhenMissing) {
      return const GalHookMiningResult(
        failureReason:
            'no matching game resource audio; audio fallback is disabled',
        sentenceAudioMissing: true,
        audioFallbackDisabled: true,
      );
    }
    await writeDictionaryMediaCache(
      job.effectiveFields['dictionaryMedia'] ?? '',
    );

    final ExternalWindowInfo window = job.window;
    final Directory jobDirectory = await _createTempDirectory();
    try {
      if (!job.occurrenceIsCurrent()) {
        return const GalHookMiningResult(
          failureReason: 'captured occurrence is no longer available',
        );
      }
      final ImmersionMiningResult mined = await _engine.mine(
        buildExternalWindowRequest(
          fields: job.effectiveFields,
          sentence: job.effectiveSentence,
          screenshotBytes: coverBytes,
          coverName: coverName,
          audioBytes: audioBytes,
          audioName: sentenceAudioMissing
              ? null
              : 'galgame_audio.${job.audioExtension}',
          documentTitle: window.title.isEmpty
              ? 'External window'
              : window.title,
          // BUG-1137：gal 场景卡归「游戏」分类标签（曾吃默认 video 被误标）。
          source: AnkiMiningSource.game,
          // 「自动添加书名到标签」开启时把游戏窗口标题作为标题标签（与 reader 书名 /
          // video 番名同语义，同走 sanitizeTitleTag 清洗去重）。
          bookTitleTag: job.addTitleTag && window.title.isNotEmpty
              ? window.title
              : null,
          updateNoteId: job.updateNoteId,
          stillFormat: job.stillFormat,
          synchronizedClip: cover.synchronizedClip,
          // 覆写既有卡（updateNoteId）时不新给出处：旧卡没有链接就保持没有。
          sourceLink:
              job.updateNoteId != null || _session.activityGameKey == null
              ? null
              : CardSourceLink.tryGame(gameId: _session.activityGameKey!),
        ),
        compression: job.compression,
        tempDir: jobDirectory.path,
        repo: job.repo,
      );
      if (mined.aborted || mined.outcome is! MineOutcome) {
        return GalHookMiningResult(
          failureReason: mined.abortReason ?? 'scene card mining aborted',
          sentenceAudioMissing: sentenceAudioMissing,
          degradedToStill: degradedToStill,
          degradedToAnimated: degradedToAnimated,
          staleScene: job.staleScene,
        );
      }
      final MineOutcome outcome = mined.outcome! as MineOutcome;
      // 制卡成功回写行模型：把该行标记为「已制卡」，供捕获工作台列表显示徽章。
      // 幂等（markLineMined 内部去重），覆写既有卡（updateNoteId）成功同样视作已制卡。
      //
      // BUG-1799：连同后端回传的 note id 一起记下，这行日后才能向 Anki 复核那张卡
      // 是否还活着（用户在 Anki 里删了就把徽章清掉）。覆写既有卡时 outcome 不带新 id，
      // 退回本次覆写的目标 id —— 那正是这行现在对应的那张卡。
      if (outcome.result == MineResult.success) {
        _textService.markLineMined(
          job.entry.id,
          noteId: outcome.noteId ?? job.updateNoteId,
        );
      }
      return GalHookMiningResult(
        outcome: outcome,
        sentenceAudioMissing: sentenceAudioMissing,
        degradedToStill: degradedToStill,
        degradedToAnimated: degradedToAnimated,
        staleScene: job.staleScene,
        unmappedTokens: await _unmappedTokens(
          job.repo,
          hasSentenceAudio: !sentenceAudioMissing,
        ),
      );
    } finally {
      try {
        await jobDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 视频片段：从会话录制环导出 `[台词到达 - 300ms, 现在]` 的帧，与句子音频混成 mp4。
  ///
  /// 无 hook 时间戳（纯 loopback 会话 / 历史行时间戳已淘汰）时导出整个录制环
  /// （`fromTickMs: 0`），起点交给 [buildGalWindowVideoClip] 按「音频时长 + 1 秒 /
  /// 无音频 6 秒」从终点倒推——Dart 侧拿不到 hook 的 tick 时钟，「现在」只能由导出结果
  /// 的 `nowTickMs` 告知。
  ///
  /// 已知限制：截图 lease（`captureLeaseFactory`，游戏内查词卡隐藏屏障）对录制帧无意义
  /// ——帧是过去按固定间隔录下的，制卡那一刻查词卡多半已经在最后几帧里。这里**不**
  /// 为此改 lease 逻辑；要干净帧请用动图 / 截图模式。
  ///
  /// fail-open：任一步失败返回 null，调用方降级动图 → 静图。临时目录只活在本函数内
  /// （产物字节已在内存）。
  /// 制卡目标是历史行时，片段应当在哪一刻收尾（0 = 一直录到现在，即该行仍是当前行）。
  ///
  /// 取下一行的时间戳：那正是这一行画面被替换掉的时刻。取不到（下一行没有时间戳 /
  /// 找不到该行）就退回 0，与改前行为一致——宁可多录，也不要因为算不出终点而不出片段。
  int _historicalLineEndTickMs(
    TexthookerLineEntry entry,
    List<TexthookerLineEntry> liveEntries,
  ) {
    final int at = liveEntries.indexWhere(
      (TexthookerLineEntry e) => e.id == entry.id,
    );
    if (at < 0 || at + 1 >= liveEntries.length) return 0;
    return _lineTimestampLookup(liveEntries[at + 1].id) ?? 0;
  }

  Future<GalWindowVideoClip?> _captureVideoClip({
    required String lineId,
    required int toTickMs,
    required Uint8List? audioBytes,
    required String audioExtension,
    required MiningClipFormat format,
  }) async {
    final int? lineTickMs = _lineTimestampLookup(lineId);
    final int? fromTickMs = lineTickMs == null
        ? null
        : (lineTickMs - kGalWindowVideoLeadMs).clamp(0, lineTickMs);
    Directory? recordingDir;
    try {
      recordingDir = await _createTempDirectory();
      final WindowRecordingExport export = await _exportRecording(
        fromTickMs: fromTickMs ?? 0,
        toTickMs: toTickMs,
        directory: recordingDir.path,
      );
      return await _buildVideoClip(
        export: export,
        fromTickMs: fromTickMs,
        toTickMs: toTickMs,
        audioBytes: audioBytes,
        audioExtension: audioExtension,
        workDir: recordingDir,
        format: format,
      );
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'GalHookMiningCoordinator.captureVideoClip',
        error,
        stack,
      );
      return null;
    } finally {
      if (recordingDir != null) {
        try {
          await recordingDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<List<String>> _unmappedTokens(
    BaseAnkiRepository repo, {
    required bool hasSentenceAudio,
  }) async {
    try {
      final Map<String, String> mappings =
          (await repo.loadSettings()).fieldMappings;
      if (mappings.isEmpty) return const <String>[];
      final List<String> missing = <String>[];
      if (!AnkiHandlebarOptions.anyFieldConsumesSentence(mappings)) {
        missing.add('{sentence}');
      }
      if (!AnkiHandlebarOptions.anyFieldConsumesCardImage(mappings)) {
        missing.add('{card-image}');
      }
      if (hasSentenceAudio &&
          !AnkiHandlebarOptions.anyFieldConsumesSentenceAudio(mappings)) {
        missing.add('{sentence-audio}');
      }
      if (!AnkiHandlebarOptions.anyFieldConsumesToken(mappings, '{audio}')) {
        missing.add('{audio}');
      }
      return List<String>.unmodifiable(missing);
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'GalHookMiningCoordinator.mappingDiagnostics',
        error,
        stack,
      );
      return const <String>[];
    }
  }

  static Future<T> _captureWithLease<T>(
    GalHookCaptureLeaseFactory? factory,
    Future<T> Function() capture,
  ) async {
    final GalHookCaptureLease? lease = factory == null ? null : await factory();
    try {
      return await capture();
    } finally {
      if (lease != null) await lease.release();
    }
  }
}

/// 句音采集的在途结果：异常暂存、取值时原样重抛（见 [_SceneAudio.value]）。
///
/// 采样阶段先启动、收尾阶段才取值；中间这段时间若没有监听者，一个失败的 Future 会
/// 变成 unhandled async error，所以构造时立刻挂上 catchError。
class _SceneAudio {
  _SceneAudio(Future<Uint8List?> source) {
    future = source.catchError((Object error, StackTrace stack) {
      _error = error;
      _stack = stack;
      return null;
    });
  }

  /// 永不以错误完成（错误被暂存）；给并行消费者（动图时长目标）用。
  late final Future<Uint8List?> future;
  Object? _error;
  StackTrace? _stack;

  Future<Uint8List?> value() async {
    final Uint8List? bytes = await future;
    final Object? error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stack ?? StackTrace.current);
    }
    return bytes;
  }
}

/// 采样阶段定下来的封面素材。三选一（按收尾时的处理顺序）：
/// - [frames]：已采好的动图帧，收尾编码；编码失败用第一帧降级静图；
/// - [stillPng]：单帧 PNG（含打码源图），收尾打码 / 降采样；
/// - [readyBytes]：已是成品（同步片段 / 注入捕获器产出的动图）。
class _SceneCover {
  Uint8List? readyBytes;
  String? readyName;
  bool synchronizedClip = false;
  Uint8List? stillPng;
  List<MiningMosaicRegion> mosaic = const <MiningMosaicRegion>[];
  GalWindowAnimationFrames? frames;
  MiningAnimatedFormat animatedFormat = MiningAnimatedFormat.gif;
  bool degradedToStill = false;
  bool degradedToAnimated = false;

  bool get decided => readyBytes != null || stillPng != null || frames != null;

  Future<void> dispose() async {
    await frames?.dispose();
  }
}

/// 采样阶段交给收尾阶段的全部材料。
class _SceneJob {
  _SceneJob({
    required this.entry,
    required this.effectiveSentence,
    required this.effectiveFields,
    required this.window,
    required this.state,
    required this.occurrenceIsCurrent,
    required this.staleScene,
    required this.audio,
    required this.audioExtension,
    required this.cover,
    required this.compression,
    required this.stillFormat,
    required this.repo,
    required this.updateNoteId,
    required this.addTitleTag,
  });

  final TexthookerLineEntry entry;
  final String effectiveSentence;
  final Map<String, String> effectiveFields;
  final ExternalWindowInfo window;
  final GalHookSessionState state;
  final bool Function() occurrenceIsCurrent;
  final bool staleScene;
  final _SceneAudio audio;
  final String audioExtension;
  final _SceneCover cover;
  final MiningMediaCompression compression;
  final MiningStillFormat stillFormat;
  final BaseAnkiRepository repo;
  final int? updateNoteId;
  final bool addTitleTag;
}

/// 包住收尾 Future 的壳。直接把 Future 当采样队列的结果会被 async 返回 / Completer
/// 拍平，采样队列就会一直等到写卡结束——那正是要拆掉的串行。
class _PendingSceneCard {
  const _PendingSceneCard(this.result);

  final Future<GalHookMiningResult> result;
}
