import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/mining/external_window_mining.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/mining/serial_job_queue.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/pages/implementations/dictionary_webview_media.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

typedef GalHookGifCapture = Future<GalWindowAnimatedCapture?> Function({
  required int hwnd,
  MiningAnimatedFormat format,
});
typedef GalHookStillCapture = Future<WindowCaptureResult> Function(int hwnd);
typedef GalHookTempDirectoryFactory = Future<Directory> Function();
typedef GalHookLineLookup = TexthookerLineEntry? Function(String lineId);
typedef GalHookLineValidator = bool Function(TexthookerLineEntry entry);
typedef GalHookSessionStateLoader = GalHookSessionState Function();
typedef GalHookAudioCapture = Future<Uint8List?> Function({
  required String lineId,
  required String sentence,
  required String outputExtension,
});

class GalHookMiningResult {
  const GalHookMiningResult({
    this.outcome,
    this.failureReason,
    this.sentenceAudioMissing = false,
    this.degradedToStill = false,
    this.staleScene = false,
    this.audioFallbackDisabled = false,
    this.unmappedTokens = const <String>[],
  });

  final MineOutcome? outcome;
  final String? failureReason;
  final bool sentenceAudioMissing;
  final bool degradedToStill;

  /// 制卡的是**历史行**（非当前最新行）时置真：画面截图只能抓 mine 时刻的当前窗口帧，
  /// 无法重建历史行当时的画面，故显式标注「画面可能与该台词不对应」，供调用方提示用户
  /// （BUG-955：禁止把当前画面冒充成历史台词的画面而不告知）。
  final bool staleScene;
  final bool audioFallbackDisabled;
  final List<String> unmappedTokens;

  bool get aborted => outcome == null;
  bool get success => outcome?.result == MineResult.success;

  Map<String, Object?> toPopupReply() => <String, Object?>{
        'ankiConnect': success,
        'noteId': success ? outcome?.noteId : null,
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
  })  : _session = session ?? GalHookSessionController.instance,
        _textService = textService ?? TexthookerService.instance,
        _engine = engine ?? ImmersionMiningEngine(),
        _captureGif = captureGif ?? _defaultCaptureGif,
        _captureStill = captureStill ?? WindowCaptureChannel.captureWindow,
        _createTempDirectory =
            createTempDirectory ?? _defaultCreateTempDirectory {
    _lineLookup = lineLookup ?? _textService.entryById;
    _lineValidator = lineValidator ?? _session.isLineInCurrentSession;
    _stateLoader = stateLoader ?? (() => _session.state);
    _captureAudio = captureAudio ?? _session.captureAudioBytes;
  }

  static final GalHookMiningCoordinator instance = GalHookMiningCoordinator();

  final GalHookSessionController _session;
  final TexthookerService _textService;
  final ImmersionMiningEngine _engine;
  final GalHookGifCapture _captureGif;
  final GalHookStillCapture _captureStill;
  final GalHookTempDirectoryFactory _createTempDirectory;
  late final GalHookLineLookup _lineLookup;
  late final GalHookLineValidator _lineValidator;
  late final GalHookSessionStateLoader _stateLoader;
  late final GalHookAudioCapture _captureAudio;

  final SerialJobQueue _miningQueue = SerialJobQueue();

  static Future<GalWindowAnimatedCapture?> _defaultCaptureGif({
    required int hwnd,
    MiningAnimatedFormat format = MiningAnimatedFormat.gif,
  }) =>
      captureWindowGifBytes(hwnd: hwnd, format: format);

  static Future<Directory> _defaultCreateTempDirectory() =>
      Directory.systemTemp.createTemp('hibiki-gal-card-job-');

  Future<GalHookMiningResult> mineLine({
    required String lineId,
    required Map<String, String> fields,
    required MiningMediaCompression compression,
    required BaseAnkiRepository repo,
    int? updateNoteId,
    bool addTitleTag = false,
    // 缺省 gif = 旧行为逐字等价（Never break userspace）；调用方透传
    // [AppModel.galMiningImageMode]。
    VideoMiningImageMode imageMode = VideoMiningImageMode.gif,
    // 缺省 gif = 旧行为逐字等价；调用方透传 [AppModel.galMiningAnimatedFormat]（默认 avif）。
    MiningAnimatedFormat animatedFormat = MiningAnimatedFormat.gif,
  }) {
    // 串行化 + 永不毒化（BUG-956）：单次制卡异常（含错误日志自身抛）不得让后续制卡永久挂起。
    return _miningQueue.enqueue<GalHookMiningResult>(
      () => _mineLineNow(
        lineId: lineId,
        fields: fields,
        compression: compression,
        repo: repo,
        updateNoteId: updateNoteId,
        addTitleTag: addTitleTag,
        imageMode: imageMode,
        animatedFormat: animatedFormat,
      ),
      buildFailure: (Object error, StackTrace stack) =>
          GalHookMiningResult(failureReason: error.toString()),
      onError: (Object error, StackTrace stack) => ErrorLogService.instance.log(
        'GalHookMiningCoordinator.mineLine',
        error,
        stack,
      ),
    );
  }

  Future<GalHookMiningResult> _mineLineNow({
    required String lineId,
    required Map<String, String> fields,
    required MiningMediaCompression compression,
    required BaseAnkiRepository repo,
    required int? updateNoteId,
    required bool addTitleTag,
    required VideoMiningImageMode imageMode,
    required MiningAnimatedFormat animatedFormat,
  }) async {
    final TexthookerLineEntry? entry = _lineLookup(lineId);
    if (entry == null || !_lineValidator(entry)) {
      return const GalHookMiningResult(
        failureReason: 'captured line is no longer available',
      );
    }
    final GalHookSessionState state = _stateLoader();
    final ExternalWindowInfo? window = state.boundWindow;
    if (!state.externalWindowMode || window == null) {
      return const GalHookMiningResult(
        failureReason: 'game window is not bound',
      );
    }

    final Map<String, String> effectiveFields = Map<String, String>.from(fields)
      ..['sentence'] = entry.text;
    await writeDictionaryMediaCache(
      effectiveFields['dictionaryMedia'] ?? '',
    );

    // BUG-955：截图只能抓 mine 时刻的当前窗口帧。若制卡的是历史行（非当前最新行），当前帧
    // 无法代表该台词当时的画面——显式标注 staleScene，不静默把当前画面冒充成旧台词的画面。
    final List<TexthookerLineEntry> liveEntries = _textService.entries;
    final bool staleScene =
        liveEntries.isEmpty || liveEntries.last.id != entry.id;
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
      final WindowCaptureResult still = await _captureStill(window.hwnd);
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

    Uint8List? coverBytes;
    String coverName = 'external_window.gif';
    bool degradedToStill = false;
    if (imageMode.isStill) {
      // 用户主动选静态截图：直接抓单帧，**不**先试 GIF。galgame 一句台词内画面基本
      // 静止，动图多半只是把同一帧存二十遍，白白撑大卡片。这不是降级，故不置
      // degradedToStill，也就不会弹「已降级为静态图」的提示（与视频侧同语义）。
      final WindowCaptureResult still = await captureStillWithDiagnostics();
      if (!still.ok) {
        return GalHookMiningResult(
          failureReason: still.error ?? 'game window capture failed',
        );
      }
      coverBytes = still.pngBytes;
      coverName = 'external_window.png';
    } else {
      final GalWindowAnimatedCapture? animated = await _captureGif(
        hwnd: window.hwnd,
        format: animatedFormat,
      );
      // 文件名一律取**实际产出格式**而非用户所选：捕获内部会在编码器缺失时降级 GIF，
      // 按所选格式拼名会写出 `.avif` 里装 GIF 字节的卡（Anki 按扩展名判 MIME → 图不显示）。
      coverBytes = animated?.bytes;
      if (animated != null) {
        coverName = 'external_window.${animated.format.fileExtension}';
      }
      if (coverBytes == null || coverBytes.isEmpty) {
        final WindowCaptureResult still = await captureStillWithDiagnostics();
        if (!still.ok) {
          return GalHookMiningResult(
            failureReason: still.error ?? 'game window capture failed',
          );
        }
        coverBytes = still.pngBytes;
        coverName = 'external_window.png';
        degradedToStill = true;
      }
    }

    final String audioExtension = immersionMiningAudioExtension();
    final Uint8List? audioBytes = await _captureAudio(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: audioExtension,
    );
    final bool sentenceAudioMissing = audioBytes == null || audioBytes.isEmpty;
    // 只有最严格的 resourceOnly 才因为「没抓到音频」拒绝制卡。cleanOnly 的立场是
    // 「这句本来就没配音很正常」——旁白/心理描写句照样成卡，只是不带音频；把它也
    // 拦成制卡失败，等于逼用户在「收一段 BGM」和「这张卡做不了」之间二选一。
    if (sentenceAudioMissing &&
        state.audioFallbackPolicy.blocksMiningWhenMissing) {
      return const GalHookMiningResult(
        failureReason:
            'no matching game resource audio; audio fallback is disabled',
        sentenceAudioMissing: true,
        audioFallbackDisabled: true,
      );
    }

    final Directory jobDirectory = await _createTempDirectory();
    try {
      final ImmersionMiningResult mined = await _engine.mine(
        buildExternalWindowRequest(
          fields: effectiveFields,
          sentence: entry.text,
          screenshotBytes: coverBytes,
          coverName: coverName,
          audioBytes: audioBytes,
          audioName:
              sentenceAudioMissing ? null : 'galgame_audio.$audioExtension',
          documentTitle:
              window.title.isEmpty ? 'External window' : window.title,
          // BUG-1137：gal 场景卡归「游戏」分类标签（曾吃默认 video 被误标）。
          source: AnkiMiningSource.game,
          // 「自动添加书名到标签」开启时把游戏窗口标题作为标题标签（与 reader 书名 /
          // video 番名同语义，同走 sanitizeTitleTag 清洗去重）。
          bookTitleTag:
              addTitleTag && window.title.isNotEmpty ? window.title : null,
          updateNoteId: updateNoteId,
        ),
        compression: compression,
        tempDir: jobDirectory.path,
        repo: repo,
      );
      if (mined.aborted || mined.outcome is! MineOutcome) {
        return GalHookMiningResult(
          failureReason: mined.abortReason ?? 'scene card mining aborted',
          sentenceAudioMissing: sentenceAudioMissing,
          degradedToStill: degradedToStill,
          staleScene: staleScene,
        );
      }
      final MineOutcome outcome = mined.outcome! as MineOutcome;
      // 制卡成功回写行模型：把该行标记为「已制卡」，供捕获工作台列表显示徽章。
      // 幂等（markLineMined 内部去重），覆写既有卡（updateNoteId）成功同样视作已制卡。
      if (outcome.result == MineResult.success) {
        _textService.markLineMined(entry.id);
      }
      return GalHookMiningResult(
        outcome: outcome,
        sentenceAudioMissing: sentenceAudioMissing,
        degradedToStill: degradedToStill,
        staleScene: staleScene,
        unmappedTokens: await _unmappedTokens(
          repo,
          hasSentenceAudio: !sentenceAudioMissing,
        ),
      );
    } finally {
      try {
        await jobDirectory.delete(recursive: true);
      } catch (_) {}
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
}
