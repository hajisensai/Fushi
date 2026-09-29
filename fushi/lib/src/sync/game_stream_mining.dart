import 'dart:collection';
import 'dart:io';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

typedef GameStreamSnapshotMiner =
    Future<GalHookMiningResult> Function(
      GameStreamMineRequest request,
      GalHookLineScreenshot screenshot,
    );

/// Windows host adapter. Screenshots stay in this bounded memory cache and are
/// never supplied by the phone or uploaded to it. Missing historical frames are
/// an explicit failure; neither current-window nor latest-audio fallback exists.
class FushiGameStreamMiningAdapter {
  FushiGameStreamMiningAdapter({
    GalHookMiningCoordinator? coordinator,
    required BaseAnkiRepository Function() repository,
    required MiningMediaCompression Function() compression,
    this.imageMode = VideoMiningImageMode.currentFrame,
    this.animatedFormat = MiningAnimatedFormat.gif,
    this.stillFormat = MiningStillFormat.jpg,
    bool Function()? addTitleTag,
    GalHookLineLookup? lineLookup,
    String? Function()? currentLineId,
    GalHookLineValidator? lineValidator,
    GalHookStillCapture? captureStill,
    GameStreamSnapshotMiner? mineSnapshot,
    bool Function()? isWindows,
    this.maxSnapshots = 16,
    this.maxSnapshotBytes = 32 * 1024 * 1024,
  }) : assert(maxSnapshots > 0),
       assert(maxSnapshotBytes > 0),
       _coordinator = coordinator ?? GalHookMiningCoordinator.instance,
       _repository = repository,
       _compression = compression,
       _addTitleTag = addTitleTag ?? (() => false),
       _lineLookup = lineLookup ?? TexthookerService.instance.entryById,
       _currentLineId = currentLineId ?? _latestLineId,
       _lineValidator =
           lineValidator ??
           GalHookSessionController.instance.isLineInCurrentSession,
       _captureStill = captureStill ?? WindowCaptureChannel.captureWindow,
       _mineSnapshot = mineSnapshot,
       _isWindows = isWindows ?? (() => Platform.isWindows);

  final GalHookMiningCoordinator _coordinator;
  final BaseAnkiRepository Function() _repository;
  final MiningMediaCompression Function() _compression;
  final bool Function() _addTitleTag;
  final GalHookLineLookup _lineLookup;
  final String? Function() _currentLineId;
  final GalHookLineValidator _lineValidator;
  final GalHookStillCapture _captureStill;
  final GameStreamSnapshotMiner? _mineSnapshot;
  final bool Function() _isWindows;
  // Existing constructor preferences are retained; remote media is deliberately
  // frozen still imagery even when the local mining preference is GIF/video.
  final VideoMiningImageMode imageMode;
  final MiningAnimatedFormat animatedFormat;
  final MiningStillFormat stillFormat;
  final int maxSnapshots;
  final int maxSnapshotBytes;
  final LinkedHashMap<String, GalHookLineScreenshot> _snapshots =
      LinkedHashMap<String, GalHookLineScreenshot>();
  final Map<String, String> _snapshotTexts = <String, String>{};
  final Map<String, _LineCaptureJob> _capturing = <String, _LineCaptureJob>{};
  int _snapshotBytes = 0;
  int _generation = 0;

  GameStreamMineHandler get handler => mine;

  static String? _latestLineId() {
    final List<TexthookerLineEntry> entries =
        TexthookerService.instance.entries;
    return entries.isEmpty ? null : entries.last.id;
  }

  bool _matches(GameStreamTextEvent line, {bool requireCurrent = false}) {
    final TexthookerLineEntry? entry = _lineLookup(line.lineId);
    return entry != null &&
        entry.text == line.text &&
        _lineValidator(entry) &&
        (!requireCurrent || _currentLineId() == entry.id);
  }

  /// Called when the host publishes a Hook line. A line transition during WGC
  /// invalidates the captured image instead of attributing a newer frame to it.
  Future<bool> captureLine(
    GameStreamTextEvent line, {
    required int hwnd,
  }) async {
    if (!_isWindows() || hwnd <= 0 || !_matches(line, requireCurrent: true)) {
      return false;
    }
    if (_snapshotTexts[line.lineId] == line.text) {
      return true;
    }
    final GalHookLineScreenshot? outdated = _snapshots.remove(line.lineId);
    if (outdated != null) _snapshotBytes -= outdated.pngBytes.length;
    _snapshotTexts.remove(line.lineId);
    final int generation = _generation;
    final _LineCaptureRequest request = _LineCaptureRequest(line, hwnd);
    _LineCaptureJob? job = _capturing[line.lineId];
    if (job == null) {
      job = _LineCaptureJob(line.lineId, generation, request);
      _capturing[line.lineId] = job;
      job.done = _captureLatest(job);
    } else {
      // Progressive Hook updates retain their lineId. Keep only the newest
      // request while WGC is busy; dropping it would leave the final sentence
      // without a snapshot when the older frame is rejected below.
      job.pending = request;
    }
    await job.done;
    return generation == _generation &&
        _snapshotTexts[line.lineId] == line.text &&
        _snapshots.containsKey(line.lineId);
  }

  Future<void> _captureLatest(_LineCaptureJob job) async {
    try {
      while (job.generation == _generation && job.pending != null) {
        final _LineCaptureRequest request = job.pending!;
        job.pending = null;
        final GameStreamTextEvent line = request.line;
        if (!_matches(line, requireCurrent: true) ||
            _snapshotTexts[line.lineId] == line.text) {
          continue;
        }
        final WindowCaptureResult frame;
        try {
          frame = await _captureStill(request.hwnd);
        } catch (_) {
          // A distinct newer request supersedes a failed old capture. Never
          // retry the failed request itself or let a cleared job start again.
          if (job.generation == _generation && job.pending != null) continue;
          rethrow;
        }
        if (job.generation != _generation) return;
        if (!frame.ok ||
            frame.pngBytes == null ||
            !_matches(line, requireCurrent: true)) {
          continue;
        }
        final int byteCount = frame.pngBytes!.length;
        if (byteCount > maxSnapshotBytes) continue;
        while (_snapshots.isNotEmpty &&
            (_snapshots.length >= maxSnapshots ||
                _snapshotBytes + byteCount > maxSnapshotBytes)) {
          final String expiredId = _snapshots.keys.first;
          _snapshotBytes -= _snapshots.remove(expiredId)!.pngBytes.length;
          _snapshotTexts.remove(expiredId);
        }
        _snapshots[line.lineId] = GalHookLineScreenshot(
          lineId: line.lineId,
          pngBytes: frame.pngBytes!,
        );
        _snapshotBytes += byteCount;
        _snapshotTexts[line.lineId] = line.text;
      }
    } finally {
      // A stopped session may already have begun a new capture with the same id.
      if (identical(_capturing[job.lineId], job)) _capturing.remove(job.lineId);
    }
  }

  /// Stop/session-change invalidates both stored and still in-flight images.
  void clear() {
    _generation++;
    _snapshots.clear();
    _snapshotTexts.clear();
    _capturing.clear();
    _snapshotBytes = 0;
  }

  Future<GameStreamMineResult> mine(
    GameStreamMineRequest request,
    GameStreamTextEvent line,
  ) async {
    if (!_isWindows()) {
      return const GameStreamMineResult(
        ok: false,
        detail: GameStreamMineDetail.windowsOnly,
        message: '远程游戏制卡仅由 Windows 主机执行',
      );
    }
    if (request.lineId != line.lineId || !_matches(line)) {
      return const GameStreamMineResult(
        ok: false,
        detail: GameStreamMineDetail.lineExpired,
        message: '该台词已经过期，未执行制卡',
      );
    }
    if (request.sentence != line.text) {
      return const GameStreamMineResult(
        ok: false,
        detail: GameStreamMineDetail.sentenceMismatch,
        message: '台词内容已变化，未执行制卡',
      );
    }
    final GalHookLineScreenshot? screenshot = _snapshots[request.lineId];
    if (screenshot == null || _snapshotTexts[line.lineId] != line.text) {
      return const GameStreamMineResult(
        ok: false,
        detail: GameStreamMineDetail.snapshotMissing,
        message: '该台词的对应画面未保存或已过期，未执行制卡',
      );
    }
    final Map<String, String> fields = gameStreamHostMineFields(request.fields);
    final GameStreamMineRequest safeRequest = GameStreamMineRequest(
      sessionId: request.sessionId,
      clientId: request.clientId,
      lineId: request.lineId,
      sentence: line.text,
      fields: fields,
    );
    final GalHookMiningResult result = _mineSnapshot != null
        ? await _mineSnapshot(safeRequest, screenshot)
        : await _coordinator.mineLine(
            lineId: safeRequest.lineId,
            fields: fields,
            sentenceOverride: line.text,
            compression: _compression(),
            repo: _repository(),
            addTitleTag: _addTitleTag(),
            imageMode: VideoMiningImageMode.currentFrame,
            stillFormat: stillFormat,
            providedLineScreenshot: screenshot,
          );
    // 失败原文**不出主机**：`GalHookMiningResult.failureReason` 有一条路是
    // `error.toString()`（gal_hook_mining_coordinator.dart 的 buildFailure），里面会带
    // 本机绝对路径（FileSystemException）、AnkiConnect 的主机名/端口（SocketException）
    // 之类。这条结果随后原样回给手机，等于把主机内情推到局域网对端。原文只进本机
    // 日志，远端拿到的是通用文案 + 枚举化 detail。
    if (!result.success && !result.duplicate && result.failureReason != null) {
      ErrorLogService.instance.log(
        'GameStream.mine',
        'host mining failed: ${result.failureReason}',
        StackTrace.current,
      );
    }
    return GameStreamMineResult(
      ok: result.success,
      message: result.success
          ? result.sentenceAudioMissing
                ? '制卡完成，但该台词没有可用的对应语音'
                : '制卡完成'
          : result.duplicate
          ? 'Anki 中已有对应卡片'
          : '主机制卡失败',
      detail: result.duplicate
          ? GameStreamMineDetail.duplicate
          : result.success && result.sentenceAudioMissing
          ? GameStreamMineDetail.sentenceAudioMissing
          : result.success
          ? null
          : result.audioFallbackDisabled
          ? GameStreamMineDetail.audioFallbackDisabled
          : result.aborted
          ? GameStreamMineDetail.captureFailed
          : GameStreamMineDetail.hostError,
    );
  }
}

/// Machine codes in [GameStreamMineResult.detail]; the receiver localizes
/// them. The host's raw failure text never leaves the host.
abstract final class GameStreamMineDetail {
  static const String duplicate = 'duplicate';
  static const String sentenceAudioMissing = 'sentence_audio_missing';
  static const String audioFallbackDisabled = 'audio_fallback_disabled';
  static const String captureFailed = 'capture_failed';
  static const String lineExpired = 'line_expired';
  static const String sentenceMismatch = 'sentence_mismatch';
  static const String snapshotMissing = 'line_snapshot_missing';
  static const String hostError = 'host_error';
  static const String windowsOnly = 'windows_only';
}

/// Popup text fields the host accepts from a receiver. These are exactly the
/// keys `assets/popup/popup.js` sends for a term (plus the legacy short names
/// early receivers used), so a remote card carries the same reading, pitch,
/// frequency and glossary fields as one mined on the host itself.
///
/// Media is constrained: `dictionaryMedia` only names entries inside the
/// host's own dictionaries (read through FushiDicts, never a filesystem path),
/// and `audio` must be an http(s) URL or an inline `data:audio/` URI — the
/// server route has already re-resolved phone-local and host-token refs. The
/// sentence, deck, note ids and screenshots always come from the host.
const Set<String> kGameStreamHostMineFieldKeys = <String>{
  'expression',
  'reading',
  'matched',
  'furiganaPlain',
  'frequenciesHtml',
  'freqHarmonicRank',
  'glossary',
  'glossaryFirst',
  'singleGlossaries',
  'pitchPositions',
  'pitchCategories',
  'phoneticTranscriptions',
  'popupSelectionText',
  'glossarySelectionHighlighted',
  'selectedDictionary',
  'dictionaryMedia',
  'audio',
  // Legacy receiver names.
  'term',
  'meaning',
  'definitions',
  'pitch',
  'frequency',
};

Map<String, String> gameStreamHostMineFields(Map<String, String> remote) {
  final Map<String, String> fields = <String, String>{
    for (final MapEntry<String, String> entry in remote.entries)
      if (kGameStreamHostMineFieldKeys.contains(entry.key))
        entry.key: entry.value,
  };
  final String? audio = fields['audio'];
  if (audio != null &&
      !audio.startsWith('https://') &&
      !audio.startsWith('http://') &&
      !audio.startsWith('data:audio/')) {
    fields.remove('audio');
  }
  // Early receivers sent `term`; the Anki field mapping reads `expression`.
  if ((fields['expression'] ?? '').isEmpty &&
      (fields['term'] ?? '').isNotEmpty) {
    fields['expression'] = fields['term']!;
  }
  return fields;
}

class _LineCaptureRequest {
  const _LineCaptureRequest(this.line, this.hwnd);

  final GameStreamTextEvent line;
  final int hwnd;
}

class _LineCaptureJob {
  _LineCaptureJob(this.lineId, this.generation, this.pending);

  final String lineId;
  final int generation;
  _LineCaptureRequest? pending;
  late final Future<void> done;
}
