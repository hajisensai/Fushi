import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/mining/process_audio_capture_channel.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';

enum GalgameAudioCaptureState { stopped, starting, running, unavailable }

class GalgameAudioCaptureException implements Exception {
  const GalgameAudioCaptureException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GalgameAudioClip {
  GalgameAudioClip(this.path);

  final String path;

  Future<void> dispose() async {
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The next app temp cleanup can remove a file still held by antivirus.
    }
  }
}

/// App-level association between Luna clipboard occurrences and native audio
/// markers. A marker ID is minted synchronously; its MethodChannel call is kept
/// as a future so mining cannot export before native has accepted the marker.
class GalgameAudioCaptureController extends ChangeNotifier {
  GalgameAudioCaptureController._();

  static const int _maxPendingMarkers = 2048;

  static final GalgameAudioCaptureController instance =
      GalgameAudioCaptureController._();

  @visibleForTesting
  static bool? debugIsSupportedOverride;

  static bool get isSupported => debugIsSupportedOverride ?? Platform.isWindows;

  GalgameAudioCaptureState _state = GalgameAudioCaptureState.stopped;
  ExternalWindowInfo? _target;
  String? _lastError;
  int _occurrenceSequence = 0;
  final Map<String, Future<ProcessAudioCaptureResult>> _pendingMarkers =
      <String, Future<ProcessAudioCaptureResult>>{};

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
    _setState(GalgameAudioCaptureState.running);
    return true;
  }

  Future<void> stop() async {
    if (isSupported) await ProcessAudioCaptureChannel.stop();
    _pendingMarkers.clear();
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
    while (_pendingMarkers.length > _maxPendingMarkers) {
      _pendingMarkers.remove(_pendingMarkers.keys.first);
    }
    return id;
  }

  Future<GalgameAudioClip> exportOccurrence(
    String occurrenceId, {
    Duration postRoll = const Duration(milliseconds: 650),
  }) async {
    final Future<ProcessAudioCaptureResult>? pending =
        _pendingMarkers[occurrenceId];
    final ProcessAudioCaptureResult? markerResult =
        pending == null ? null : await pending;
    if (markerResult != null && !markerResult.ok) {
      throw GalgameAudioCaptureException(
        markerResult.error ?? 'The sentence audio marker could not be created.',
      );
    }
    await Future<void>.delayed(postRoll);
    final Directory directory = Directory(
      p.join(Directory.systemTemp.path, 'hibiki_galgame_audio'),
    );
    await directory.create(recursive: true);
    final String outputPath = p.join(directory.path, '$occurrenceId.wav');
    final ProcessAudioCaptureResult result =
        await ProcessAudioCaptureChannel.exportWav(
      occurrenceId: occurrenceId,
      outputPath: outputPath,
    );
    _pendingMarkers.remove(occurrenceId);
    if (!result.ok || result.path == null) {
      _lastError = result.error ?? 'Unable to export sentence audio.';
      notifyListeners();
      throw GalgameAudioCaptureException(_lastError!);
    }
    return GalgameAudioClip(result.path!);
  }

  void _setState(GalgameAudioCaptureState state, {String? error}) {
    _state = state;
    _lastError = error;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _state = GalgameAudioCaptureState.stopped;
    _target = null;
    _lastError = null;
    _occurrenceSequence = 0;
    _pendingMarkers.clear();
  }
}
