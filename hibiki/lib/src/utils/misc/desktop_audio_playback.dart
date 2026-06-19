import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// Serializes the asynchronous operations that toggle a shared just_audio
/// player's platform activation, so two playback cycles can never interleave on
/// the single, never-disposed player id (BUG-342).
///
/// Every [run] body executes strictly one-at-a-time on a single future chain:
/// a queued body only starts after the previously queued body has fully settled
/// (returned or thrown). The chain itself always advances on a resolved future
/// so one failing body never stalls later callers, while each caller still
/// observes its own body's result or error.
///
/// `run` bodies must `await` *every* asynchronous operation that changes
/// activation — including `player.play()`, which in just_audio toggles
/// `_setPlatformActive(true)` when the native platform was not already active
/// (just_audio.dart play(): the `else` branch at L960-965). Leaving any such
/// operation un-awaited (fire-and-forget) lets the next body start while the
/// previous activation is still in flight, re-opening the exact interleaving
/// this queue exists to prevent.
///
/// [preempt] gives `stop` priority semantics: it bumps a generation counter so
/// a queued playback body that has not yet reached its `play()` step can detect
/// it has been superseded ([generation]) and bail out before starting a new
/// activation, instead of fighting an incoming dismiss-stop.
@visibleForTesting
class AudioActivationQueue {
  AudioActivationQueue();

  Future<void> _tail = Future<void>.value();
  int _generation = 0;

  /// Monotonically increasing token bumped by [preempt]. A playback body
  /// captures this before yielding and re-checks it before activating; a change
  /// means a newer stop superseded it.
  int get generation => _generation;

  /// Signals that any in-flight or queued playback should consider itself
  /// superseded (e.g. a dismiss-stop arrived). Returns the new generation.
  int preempt() => ++_generation;

  Future<T> run<T>(Future<T> Function() action) {
    final Completer<T> result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (e, stack) {
        result.completeError(e, stack);
      }
    });
    return result.future;
  }
}

/// Desktop (Windows/macOS/Linux) preview playback via just_audio (the media_kit
/// backend, initialised in main.dart). Mirrors the Android native MediaPlayer
/// used for the dictionary popup "play pronunciation" button — both local files
/// and remote URLs (Forvo / JapanesePod, etc.).
class DesktopAudioPlayback {
  const DesktopAudioPlayback._();

  static final AudioPlayer _player = AudioPlayer();

  /// Serializes every operation that changes the shared [_player]'s platform
  /// activation (`stop` ↔ `load` ↔ `play`). The single shared player keeps one
  /// fixed just_audio player id for the whole process; just_audio's
  /// `_setPlatformActive` toggles the native (media_kit) platform on/off under
  /// that id, and the activating call registers the id with media_kit via
  /// `init(id)` (just_audio.dart `_setPlatformActive` → `setPlatform` →
  /// `_pluginPlatform.init`, L1411) *before* it checks whether a newer
  /// activation interrupted it (`checkInterruption` after init, L1428).
  ///
  /// If two playback cycles overlap (e.g. rapid auto-read / manual re-taps of
  /// successive lookups), cycle A's `play()` can register the id during its
  /// activation while cycle B supersedes it; A then throws the `abort`
  /// exception (L1314-1317) *after* it already registered the id, leaking a
  /// native player whose id is never disposed. Every later activation calls
  /// `init` with the same id and just_audio_media_kit throws
  /// `Player <id> already exists!`, so all preview/auto-read audio goes silent
  /// until the app restarts (BUG-342).
  ///
  /// Chaining the activation-changing work on one queue guarantees the
  /// `stop`→`load`→`play` cycles never interleave on the shared id. Crucially
  /// `play()` is **awaited inside the run body** because it is the second
  /// activation trigger: just_audio's play() calls `_setPlatformActive(true)`
  /// in its `else` branch (L960-965) when the platform was not already active.
  /// Awaiting it keeps that activation inside the serial boundary. It does
  /// **not** block for the clip's full duration: just_audio's play() returns as
  /// soon as `playCompleter` resolves (L971), and that completer fires the
  /// moment the native play request is accepted (`_sendPlayRequest` →
  /// `await platform.play()`, L997), not when playback ends. So the body
  /// settles once activation is stable, while the clip keeps playing.
  static final AudioActivationQueue _activation = AudioActivationQueue();

  static Future<bool> playUrl(String url, {double volume = 1.0}) =>
      _play(() => _player.setUrl(url), 'playUrl', volume);

  static Future<bool> playFile(String path, {double volume = 1.0}) =>
      _play(() => _player.setFilePath(path), 'playFile', volume);

  static Future<bool> _play(
    Future<Duration?> Function() load,
    String tag,
    double volume,
  ) {
    // Capture the activation generation at submission time. If a dismiss-stop
    // (which calls _activation.preempt()) supersedes this cycle before its body
    // reaches play(), the body bails out before starting a new activation
    // rather than racing the incoming stop.
    final int submittedGeneration = _activation.generation;
    return _activation.run<bool>(() async {
      try {
        await _player.stop();
        if (_activation.generation != submittedGeneration) {
          // A stop superseded this playback while it was queued/loading; do not
          // start a fresh activation only to be torn down immediately.
          return false;
        }
        await _player.setVolume(volume.clamp(0.0, 1.0));
        await load();
        if (_activation.generation != submittedGeneration) {
          return false;
        }
        // play() also toggles platform activation (_setPlatformActive(true) in
        // just_audio's play() else-branch), so it MUST be awaited inside this
        // serial body — not fire-and-forget — to keep that activation from
        // interleaving with the next cycle. It returns once the native play
        // request is accepted (playCompleter), not when the clip ends, so the
        // caller is not blocked for the clip duration.
        await _player.play();
        return true;
      } catch (e, stack) {
        ErrorLogService.instance.log('DesktopAudioPlayback.$tag', e, stack);
        return false;
      }
    });
  }

  static Future<void> stop() {
    // Preempt first (synchronously) so any playback cycle still queued/loading
    // sees a newer generation and bails before activating; then enqueue the
    // real stop so it runs serially on the same chain (no interleaving with a
    // load/play already past its check).
    _activation.preempt();
    return _activation.run<void>(() async {
      try {
        await _player.stop();
      } catch (_) {
        // Stopping an idle player is harmless.
      }
    });
  }
}
