import 'package:flutter/services.dart';

abstract final class ProcessAudioCaptureChannel {
  static const MethodChannel _channel =
      MethodChannel('app.hibiki.reader/process_audio_capture');

  static Future<ProcessAudioCaptureResult> start({
    required int pid,
    int bufferSeconds = 120,
  }) =>
      _invokeResult('start', <String, Object?>{
        'pid': pid,
        'bufferSeconds': bufferSeconds,
      });

  static Future<ProcessAudioCaptureResult> stop() =>
      _invokeResult('stop', const <String, Object?>{});

  static Future<ProcessAudioCaptureResult> mark(String occurrenceId) =>
      _invokeResult('mark', <String, Object?>{
        'occurrenceId': occurrenceId,
      });

  static Future<ProcessAudioCaptureResult> exportWav({
    required String occurrenceId,
    required String outputPath,
    int preRollMs = 450,
    int maxClipMs = 30000,
  }) =>
      _invokeResult('exportWav', <String, Object?>{
        'occurrenceId': occurrenceId,
        'outputPath': outputPath,
        'preRollMs': preRollMs,
        'maxClipMs': maxClipMs,
      });

  static Future<ProcessAudioCaptureStatus> status() async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('status');
      return ProcessAudioCaptureStatus.fromMap(
        raw ?? const <Object?, Object?>{},
      );
    } on PlatformException catch (e) {
      return ProcessAudioCaptureStatus(error: e.message ?? 'status failed');
    } on MissingPluginException {
      return const ProcessAudioCaptureStatus(
        error: 'process audio capture unavailable',
      );
    }
  }

  static Future<ProcessAudioCaptureResult> _invokeResult(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        method,
        arguments,
      );
      return ProcessAudioCaptureResult.fromMap(
        raw ?? const <Object?, Object?>{},
      );
    } on PlatformException catch (e) {
      return ProcessAudioCaptureResult(error: e.message ?? '$method failed');
    } on MissingPluginException {
      return const ProcessAudioCaptureResult(
        error: 'process audio capture unavailable',
      );
    }
  }
}

class ProcessAudioCaptureResult {
  const ProcessAudioCaptureResult({
    this.ok = false,
    this.error,
    this.path,
    this.sampleRate = 0,
    this.channels = 0,
    this.startFrame = 0,
    this.endFrame = 0,
  });

  final bool ok;
  final String? error;
  final String? path;
  final int sampleRate;
  final int channels;
  final int startFrame;
  final int endFrame;

  static ProcessAudioCaptureResult fromMap(Map<Object?, Object?> map) {
    final String error = (map['error'] as String?) ?? '';
    final String path = (map['path'] as String?) ?? '';
    return ProcessAudioCaptureResult(
      ok: map['ok'] == true,
      error: error.isEmpty ? null : error,
      path: path.isEmpty ? null : path,
      sampleRate: (map['sampleRate'] as int?) ?? 0,
      channels: (map['channels'] as int?) ?? 0,
      startFrame: (map['startFrame'] as int?) ?? 0,
      endFrame: (map['endFrame'] as int?) ?? 0,
    );
  }
}

class ProcessAudioCaptureStatus {
  const ProcessAudioCaptureStatus({
    this.running = false,
    this.pid = 0,
    this.sampleRate = 0,
    this.channels = 0,
    this.bufferedSeconds = 0,
    this.error,
  });

  final bool running;
  final int pid;
  final int sampleRate;
  final int channels;
  final int bufferedSeconds;
  final String? error;

  static ProcessAudioCaptureStatus fromMap(Map<Object?, Object?> map) {
    final String error = (map['error'] as String?) ?? '';
    return ProcessAudioCaptureStatus(
      running: map['running'] == true,
      pid: (map['pid'] as int?) ?? 0,
      sampleRate: (map['sampleRate'] as int?) ?? 0,
      channels: (map['channels'] as int?) ?? 0,
      bufferedSeconds: (map['bufferedSeconds'] as int?) ?? 0,
      error: error.isEmpty ? null : error,
    );
  }
}
