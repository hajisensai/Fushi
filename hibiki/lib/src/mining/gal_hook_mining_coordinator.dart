import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/src/mining/external_window_mining.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_window_gif.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

typedef GalHookGifCapture = Future<Uint8List?> Function({required int hwnd});
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
    this.audioFallbackDisabled = false,
    this.unmappedTokens = const <String>[],
  });

  final MineOutcome? outcome;
  final String? failureReason;
  final bool sentenceAudioMissing;
  final bool degradedToStill;
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

  Future<void> _tail = Future<void>.value();

  static Future<Uint8List?> _defaultCaptureGif({required int hwnd}) =>
      captureWindowGifBytes(hwnd: hwnd);

  static Future<Directory> _defaultCreateTempDirectory() =>
      Directory.systemTemp.createTemp('hibiki-gal-card-job-');

  Future<GalHookMiningResult> mineLine({
    required String lineId,
    required Map<String, String> fields,
    required bool compressMiningMedia,
    required BaseAnkiRepository repo,
    int? updateNoteId,
  }) {
    final Completer<GalHookMiningResult> completer =
        Completer<GalHookMiningResult>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(
          await _mineLineNow(
            lineId: lineId,
            fields: fields,
            compressMiningMedia: compressMiningMedia,
            repo: repo,
            updateNoteId: updateNoteId,
          ),
        );
      } catch (error, stack) {
        ErrorLogService.instance.log(
          'GalHookMiningCoordinator.mineLine',
          error,
          stack,
        );
        completer.complete(
          GalHookMiningResult(failureReason: error.toString()),
        );
      }
    });
    return completer.future;
  }

  Future<GalHookMiningResult> _mineLineNow({
    required String lineId,
    required Map<String, String> fields,
    required bool compressMiningMedia,
    required BaseAnkiRepository repo,
    required int? updateNoteId,
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

    Uint8List? coverBytes = await _captureGif(hwnd: window.hwnd);
    String coverName = 'external_window.gif';
    bool degradedToStill = false;
    if (coverBytes == null || coverBytes.isEmpty) {
      final WindowCaptureResult still = await _captureStill(window.hwnd);
      if (!still.ok) {
        return GalHookMiningResult(
          failureReason: still.error ?? 'game window capture failed',
        );
      }
      coverBytes = still.pngBytes;
      coverName = 'external_window.png';
      degradedToStill = true;
    }

    final String audioExtension = immersionMiningAudioExtension();
    final Uint8List? audioBytes = await _captureAudio(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: audioExtension,
    );
    final bool sentenceAudioMissing = audioBytes == null || audioBytes.isEmpty;
    if (sentenceAudioMissing && !state.allowAudioFallback) {
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
          updateNoteId: updateNoteId,
        ),
        compression: MiningMediaCompression.forCompressionEnabled(
          compressMiningMedia,
        ),
        tempDir: jobDirectory.path,
        repo: repo,
      );
      if (mined.aborted || mined.outcome is! MineOutcome) {
        return GalHookMiningResult(
          failureReason: mined.abortReason ?? 'scene card mining aborted',
          sentenceAudioMissing: sentenceAudioMissing,
          degradedToStill: degradedToStill,
        );
      }
      return GalHookMiningResult(
        outcome: mined.outcome! as MineOutcome,
        sentenceAudioMissing: sentenceAudioMissing,
        degradedToStill: degradedToStill,
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
      if (!AnkiHandlebarOptions.anyFieldConsumesToken(
        mappings,
        '{card-image}',
      )) {
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
