import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// Desktop (Windows/macOS/Linux) preview playback via just_audio (the media_kit
/// backend, initialised in main.dart). Mirrors the Android native MediaPlayer
/// used for the dictionary popup "play pronunciation" button — both local files
/// and remote URLs (Forvo / JapanesePod, etc.).
class DesktopAudioPlayback {
  const DesktopAudioPlayback._();

  static final AudioPlayer _player = AudioPlayer();

  static Future<bool> playUrl(String url) =>
      _play(() => _player.setUrl(url), 'playUrl');

  static Future<bool> playFile(String path) =>
      _play(() => _player.setFilePath(path), 'playFile');

  static Future<bool> _play(
    Future<Duration?> Function() load,
    String tag,
  ) async {
    try {
      await _player.stop();
      await load();
      // play() completes only when playback finishes; fire-and-forget so the
      // caller (the popup audio button) is not blocked for the clip duration.
      unawaited(_player.play());
      return true;
    } catch (e, stack) {
      ErrorLogService.instance.log('DesktopAudioPlayback.$tag', e, stack);
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // Stopping an idle player is harmless.
    }
  }
}
