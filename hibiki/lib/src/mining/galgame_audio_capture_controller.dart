import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/mining/process_audio_capture_channel.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/utils/misc/card_screenshot_downsampler.dart';

enum GalgameAudioCaptureState { stopped, starting, running, unavailable }

sealed class GalgameMiningMediaException implements Exception {
  const GalgameMiningMediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class GalgameAudioCaptureException extends GalgameMiningMediaException {
  const GalgameAudioCaptureException(super.message);
}

final class GalgamePictureCaptureException extends GalgameMiningMediaException {
  const GalgamePictureCaptureException(super.message);
}

class GalgameMiningMedia {
  GalgameMiningMedia({required this.audioPath, required this.picturePath});

  final String audioPath;
  final String picturePath;

  Future<void> dispose() async {
    for (final String path in <String>[audioPath, picturePath]) {
      try {
        final File file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // The next app temp cleanup can remove a file still held by antivirus.
      }
    }
  }
}

/// App-level association between Luna clipboard occurrences and native audio
/// markers. A marker ID is minted synchronously; its MethodChannel call is kept
/// as a future so mining cannot export before native has accepted the marker.
class GalgameAudioCaptureController extends ChangeNotifier {
  GalgameAudioCaptureController._();

  static const int _maxPendingMarkers = 2048;
  static const int _maxPendingPictures = 8;

  static final GalgameAudioCaptureController instance =
      GalgameAudioCaptureController._();

  @visibleForTesting
  static bool? debugIsSupportedOverride;

  @visibleForTesting
  static Future<WindowCaptureResult> Function(int hwnd)?
      debugWindowCaptureOverride;

  @visibleForTesting
  static GalgameMiningMedia Function(
    String occurrenceId, {
    required bool compressPicture,
  })? debugExportOccurrenceOverride;

  static bool get isSupported => debugIsSupportedOverride ?? Platform.isWindows;

  GalgameAudioCaptureState _state = GalgameAudioCaptureState.stopped;
  ExternalWindowInfo? _target;
  String? _lastError;
  int _occurrenceSequence = 0;
  final Map<String, Future<ProcessAudioCaptureResult>> _pendingMarkers =
      <String, Future<ProcessAudioCaptureResult>>{};
  final Map<String, Future<WindowCaptureResult>> _pendingPictures =
      <String, Future<WindowCaptureResult>>{};

  GalgameAudioCaptureState get state => _state;
  ExternalWindowInfo? get target => _target;
  String? get lastError => _lastError;
  bool get isRunning => _state == GalgameAudioCaptureState.running;

  Future<bool> start(ExternalWindowInfo window) async {
    if (!isSupported || window.pid <= 0) {
      _setState(
        GalgameAudioCaptureState.unavailable,
        error: 'The selected window has no capturable process.',
      );
      return false;
    }
    _target = window;
    _setState(GalgameAudioCaptureState.starting);
    final ProcessAudioCaptureResult result =
        await ProcessAudioCaptureChannel.start(pid: window.pid);
    if (!result.ok) {
      _setState(
        GalgameAudioCaptureState.unavailable,
        error: result.error ?? 'Unable to start process audio capture.',
      );
      return false;
    }
    _pendingMarkers.clear();
    _pendingPictures.clear();
    _setState(GalgameAudioCaptureState.running);
    return true;
  }

  Future<void> stop() async {
    if (isSupported) await ProcessAudioCaptureChannel.stop();
    _pendingMarkers.clear();
    _pendingPictures.clear();
    _target = null;
    _setState(GalgameAudioCaptureState.stopped);
  }

  /// Attempts to reconnect a persisted executable path after app startup.
  Future<bool> restore({
    required bool enabled,
    required String executablePath,
    required String windowTitle,
  }) async {
    if (!enabled || !isSupported) {
      await stop();
      return false;
    }
    final List<ExternalWindowInfo> windows =
        await WindowCaptureChannel.listWindows();
    final String wantedPath = executablePath.trim().toLowerCase();
    final String wantedTitle = windowTitle.trim();
    ExternalWindowInfo? match;
    if (wantedPath.isNotEmpty) {
      for (final ExternalWindowInfo window in windows) {
        if (window.executablePath.toLowerCase() == wantedPath) {
          match = window;
          break;
        }
      }
    }
    if (match == null && wantedTitle.isNotEmpty) {
      for (final ExternalWindowInfo window in windows) {
        if (window.title == wantedTitle) {
          match = window;
          break;
        }
      }
    }
    if (match == null) {
      _setState(
        GalgameAudioCaptureState.unavailable,
        error: 'The configured game process is not running.',
      );
      return false;
    }
    return start(match);
  }

  /// Returns null when capture is inactive. The returned ID remains distinct
  /// even when adjacent clipboard strings are identical.
  String? markClipboardOccurrence() {
    if (!isRunning) return null;
    final String id =
        '${DateTime.now().microsecondsSinceEpoch}-${_occurrenceSequence++}';
    final Future<ProcessAudioCaptureResult> pending =
        ProcessAudioCaptureChannel.mark(id).then(
      (ProcessAudioCaptureResult result) {
        if (!result.ok) {
          _lastError = result.error ?? 'Unable to mark sentence audio.';
          notifyListeners();
        }
        return result;
      },
      onError: (Object error, StackTrace stackTrace) {
        _lastError = error.toString();
        notifyListeners();
        return ProcessAudioCaptureResult(error: _lastError);
      },
    );
    _pendingMarkers[id] = pending;
    final ExternalWindowInfo? target = _target;
    if (target != null && target.hwnd != 0) {
      _pendingPictures[id] = _captureWindow(target.hwnd);
    }
    while (_pendingMarkers.length > _maxPendingMarkers) {
      final String expired = _pendingMarkers.keys.first;
      _pendingMarkers.remove(expired);
      _pendingPictures.remove(expired);
    }
    while (_pendingPictures.length > _maxPendingPictures) {
      _pendingPictures.remove(_pendingPictures.keys.first);
    }
    return id;
  }

  Future<GalgameMiningMedia> exportOccurrence(
    String occurrenceId, {
    Duration postRoll = const Duration(milliseconds: 650),
    bool compressPicture = true,
  }) async {
    final GalgameMiningMedia Function(
      String occurrenceId, {
      required bool compressPicture,
    })? exportOverride = debugExportOccurrenceOverride;
    if (exportOverride != null) {
      return exportOverride(
        occurrenceId,
        compressPicture: compressPicture,
      );
    }
    final Future<ProcessAudioCaptureResult>? pending =
        _pendingMarkers[occurrenceId];
    final Future<WindowCaptureResult>? pendingPicture =
        _pendingPictures[occurrenceId];
    final ProcessAudioCaptureResult? markerResult =
        pending == null ? null : await pending;
    if (markerResult != null && !markerResult.ok) {
      _discardOccurrence(occurrenceId);
      throw GalgameAudioCaptureException(
        markerResult.error ?? 'The sentence audio marker could not be created.',
      );
    }
    final ExternalWindowInfo? target = _target;
    if (target == null || target.hwnd == 0) {
      _discardOccurrence(occurrenceId);
      throw const GalgamePictureCaptureException(
        'The selected game window is no longer available.',
      );
    }
    final Directory directory = Directory(
      p.join(Directory.systemTemp.path, 'hibiki_galgame_audio'),
    );
    await directory.create(recursive: true);

    String? audioPath;
    String? picturePath;
    final Future<void> pictureFuture = () async {
      picturePath = await _capturePicture(
        target: target,
        occurrenceId: occurrenceId,
        directory: directory,
        compress: compressPicture,
        pendingCapture: pendingPicture,
      );
    }();
    final Future<void> audioFuture = () async {
      await Future<void>.delayed(postRoll);
      final String preferredPath = p.join(
        directory.path,
        '$occurrenceId.mp3',
      );
      final ProcessAudioCaptureResult result =
          await ProcessAudioCaptureChannel.exportAudio(
        occurrenceId: occurrenceId,
        outputPath: preferredPath,
      );
      if (!result.ok || result.path == null) {
        throw GalgameAudioCaptureException(
          result.error ?? 'Unable to export sentence audio.',
        );
      }
      audioPath = result.path;
    }();

    try {
      await Future.wait<void>(<Future<void>>[pictureFuture, audioFuture]);
      return GalgameMiningMedia(
        audioPath: audioPath!,
        picturePath: picturePath!,
      );
    } on GalgameMiningMediaException catch (error) {
      _lastError = error.message;
      notifyListeners();
      await _deleteTemporaryFiles(<String?>[audioPath, picturePath]);
      rethrow;
    } on FileSystemException catch (error) {
      _lastError = 'Unable to save the game screenshot: ${error.message}';
      notifyListeners();
      await _deleteTemporaryFiles(<String?>[audioPath, picturePath]);
      throw GalgamePictureCaptureException(_lastError!);
    } finally {
      _discardOccurrence(occurrenceId);
    }
  }

  Future<String> _capturePicture({
    required ExternalWindowInfo target,
    required String occurrenceId,
    required Directory directory,
    required bool compress,
    required Future<WindowCaptureResult>? pendingCapture,
  }) async {
    final WindowCaptureResult result =
        await (pendingCapture ?? _captureWindow(target.hwnd));
    if (!result.ok) {
      throw GalgamePictureCaptureException(
        result.error ?? 'Unable to capture the game window.',
      );
    }
    final Uint8List pngBytes = result.pngBytes!;
    final Uint8List pictureBytes = downsampleCardScreenshot(
      pngBytes,
      maxLongEdge: compress ? 1000 : 2000,
      quality: compress ? 90 : 95,
    );
    final String extension = identical(pictureBytes, pngBytes) ? 'png' : 'jpg';
    final String picturePath = p.join(
      directory.path,
      '$occurrenceId-picture.$extension',
    );
    await File(picturePath).writeAsBytes(pictureBytes, flush: true);
    return picturePath;
  }

  Future<void> _deleteTemporaryFiles(List<String?> paths) async {
    for (final String? path in paths) {
      if (path == null) continue;
      try {
        final File file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Best effort; app temp cleanup handles antivirus-held files later.
      }
    }
  }

  void _discardOccurrence(String occurrenceId) {
    _pendingMarkers.remove(occurrenceId);
    _pendingPictures.remove(occurrenceId);
  }

  static Future<WindowCaptureResult> _captureWindow(int hwnd) =>
      debugWindowCaptureOverride?.call(hwnd) ??
      WindowCaptureChannel.captureWindow(hwnd);

  void _setState(GalgameAudioCaptureState state, {String? error}) {
    _state = state;
    _lastError = error;
    notifyListeners();
  }

  @visibleForTesting
  Future<WindowCaptureResult>? debugPendingPicture(String occurrenceId) =>
      _pendingPictures[occurrenceId];

  @visibleForTesting
  void debugReset() {
    _state = GalgameAudioCaptureState.stopped;
    _target = null;
    _lastError = null;
    _occurrenceSequence = 0;
    _pendingMarkers.clear();
    _pendingPictures.clear();
    debugWindowCaptureOverride = null;
    debugExportOccurrenceOverride = null;
  }
}
