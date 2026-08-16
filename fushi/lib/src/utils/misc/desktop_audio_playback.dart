import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

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

  /// 是否已把冷启动预热排进 [_activation] 队列，避免重复入队（幂等）。
  static bool _warmUpQueued = false;

  /// 冷启动惰性预热（BUG-1015 / BUG-1690）。
  ///
  /// just_audio_media_kit 在**进程内第一次**把播放平台激活（`_setPlatformActive(true)`
  /// → media_kit `Player.init`）时，第一段真实播放的音频输出会被这次冷激活吞掉：表现
  /// 为「本次 app 启动后第一次查词自动发音没声音、点第二次才响」（BUG-1015）。修法是
  /// 用一段极短的**全零 PCM 静音**（[_silentWavBytes]）先走一遍 `stop→load→play`，把
  /// 冷激活的首帧空窗在无声中消耗掉。
  ///
  /// 但预热**不能放在 app 启动时**（BUG-1690）：预热本质是在真实音频输出设备上开一条
  /// 渲染流——iOS 上这会激活音频会话、直接暂停其他 app 正在播的音乐；蓝牙多点/独占
  /// 设备上会把输出抢过来。「启动 app 打断音乐」的根因就是这条启动期音频流。
  ///
  /// 根因修法：预热改为**惰性**——首次真实播放（[playUrl]/[playFile] → [_play]）在
  /// 入队自己的播放周期**之前**，同步把预热周期排进同一条 [_activation] FIFO 串行队列。
  /// 队列保证预热完整跑完（含等静音片播放完成，见 body 内注释）后真实播放才开始，
  /// BUG-1015 的保护不变；而启动路径从此不碰音频设备，天然不可能打断任何音乐。
  ///
  /// 必须是**同步方法、内部无 await 先于入队**：否则触发它的那次真实播放可能先入队，
  /// FIFO 顺序被破坏，首个真实播放又撞上冷激活。临时文件的异步创建挪进队列 body 内。
  /// volume 0 + 全零采样双重保证无任何可听声响；任何失败都吞掉并记日志，绝不影响
  /// 触发它的真实播放。Android 不经本类（原生 MediaPlayer 无此冷启动），无需门控。
  static void _ensureWarmUpQueued() {
    if (_warmUpQueued) return;
    _warmUpQueued = true;
    _activation.run<void>(() async {
      try {
        final Directory dir = await getTemporaryDirectory();
        final File silent = File('${dir.path}/fushi_audio_warmup.wav');
        if (!silent.existsSync()) {
          silent.parent.createSync(recursive: true);
          silent.writeAsBytesSync(_silentWavBytes());
        }
        await _player.stop();
        await _player.setVolume(0.0);
        await _player.setFilePath(silent.path);
        await _player.play();
        // 等静音片真正播放完成（0.1s，兜底超时）再放行队列里的下一个（真实）播放
        // 周期：真实周期开头就是 `stop()`，若此刻设备还没完成冷启动就把预热掐掉，
        // 冷激活空窗会漏给用户听得见的那次播放，BUG-1015 复发。
        await _player.processingStateStream
            .firstWhere((ProcessingState s) => s == ProcessingState.completed)
            .timeout(const Duration(seconds: 2));
      } catch (e, stack) {
        ErrorLogService.instance.log('DesktopAudioPlayback.warmUp', e, stack);
      }
    });
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
    // Lazy cold-start warm-up (BUG-1015/BUG-1690): queue the silent warm-up
    // cycle BEFORE this real cycle. Must stay synchronous up to this point so
    // FIFO order on _activation is guaranteed.
    _ensureWarmUpQueued();
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
          // BUG-1127 — log the bail: this used to be a fully silent swallow
          // (return false, zero traces), the same observability blind spot that
          // mis-rooted BUG-1015.
          ErrorLogService.instance.logDiagnostic(
            'DesktopAudioPlayback.$tag',
            'preempted by stop() before load — playback dropped',
          );
          return false;
        }
        await _player.setVolume(volume.clamp(0.0, 1.0));
        await load();
        if (_activation.generation != submittedGeneration) {
          // BUG-1127 — same as above, after load: observable, never silent.
          ErrorLogService.instance.logDiagnostic(
            'DesktopAudioPlayback.$tag',
            'preempted by stop() after load — playback dropped',
          );
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
