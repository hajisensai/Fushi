import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

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

  /// 是否已完成一次冷启动预热，避免重复预热（[warmUp] 幂等）。
  static bool _warmed = false;

  /// 桌面首帧冷启动预热（BUG-1015）。
  ///
  /// just_audio_media_kit 在**进程内第一次**把播放平台激活（`_setPlatformActive(true)`
  /// → media_kit `Player.init`）时，第一段真实播放的音频输出会被这次冷激活吞掉：表现
  /// 为「本次 app 启动后第一次查词自动发音没声音、点第二次才响」。这**不是**解析或触发
  /// 问题（url 已解析成功、`_play` 也没被抢占），而是播放管线首次激活的固有空窗。
  ///
  /// 根因修法：启动时用一段极短的**全零 PCM 静音**（[_silentWavBytes]）走一遍完整的
  /// `stop→load→play` 周期（复用同一 [_player] 与 [_activation] 串行队列，绝不与后续真实
  /// 播放交错），把这次冷激活的首帧空窗在无声中消耗掉。等用户第一次真正查词时平台已激活，
  /// 首个自动发音即出声。volume 0 + 全零采样双重保证无任何可听声响；任何失败都被
  /// [_play] 内部吞掉并记日志，绝不影响启动。仅桌面（just_audio_media_kit）需要，Android
  /// 走原生 MediaPlayer 无此冷启动（由 [TtsChannel.warmUpLookupAudioPlayer] 平台门控）。
  static Future<void> warmUp() async {
    if (_warmed) return;
    _warmed = true;
    try {
      final Directory dir = await getTemporaryDirectory();
      final File silent = File('${dir.path}/hibiki_audio_warmup.wav');
      if (!silent.existsSync()) {
        silent.parent.createSync(recursive: true);
        silent.writeAsBytesSync(_silentWavBytes());
      }
      // volume 0：即便静音样本外仍有任何底噪也听不见；走 _play 复用激活串行队列。
      await _play(() => _player.setFilePath(silent.path), 'warmUp', 0.0);
    } catch (e, stack) {
      ErrorLogService.instance.log('DesktopAudioPlayback.warmUp', e, stack);
    }
  }

  /// 构造一段 ~0.1s、8kHz、单声道、16-bit 的**全零（静音）** PCM WAV 字节。
  /// 只为触发 media_kit 首次平台激活，内容全零故绝对无声。
  static Uint8List _silentWavBytes() {
    const int sampleRate = 8000;
    const int channels = 1;
    const int bitsPerSample = 16;
    const int sampleCount = 800; // 0.1s
    const int dataSize = sampleCount * channels * (bitsPerSample ~/ 8);
    const int byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    const int blockAlign = channels * (bitsPerSample ~/ 8);
    final ByteData bd = ByteData(44 + dataSize);
    void writeAscii(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        bd.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    bd.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // subchunk1 size (PCM)
    bd.setUint16(20, 1, Endian.little); // audioFormat = PCM
    bd.setUint16(22, channels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    bd.setUint32(40, dataSize, Endian.little);
    // data 区保持 ByteData 默认全零 = 静音。
    return bd.buffer.asUint8List();
  }

  /// 测试钩子：暴露静音预热 WAV 字节，供守卫断言其为合法全零 PCM WAV。
  @visibleForTesting
  static Uint8List debugSilentWavBytes() => _silentWavBytes();

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
