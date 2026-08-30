import 'dart:async';
import 'dart:typed_data';

import 'package:fushi/src/mining/galgame_audio_source.dart';

/// 网页播放器逐句重放的宿主能力（[WebMineReplayRunner] 只认这个接口，页面实现它、
/// 测试用假宿主）。位置 / 播放态来自页面 250 ms 一拍的状态轮询，不是即时值。
abstract interface class WebMineReplayHost {
  int? get positionMs;
  bool get isPlaying;
  Future<void> seek(int ms);
  Future<void> play();
  Future<void> pause();

  /// 当前画面（PNG）。可捕获环境下含视频区；失败回 null。
  Future<Uint8List?> screenshot();
}

/// 一句重放抓到的媒体。[audio] 是已编码容器字节（引擎逐字节写盘，绝不能是裸 PCM），
/// [cover] 是 PNG 截图；缺哪个哪个为 null，[warnings] 说明原因（进队列行的 error 列）。
class WebMineReplayCapture {
  const WebMineReplayCapture({
    required this.audio,
    required this.cover,
    required this.warnings,
  });

  final Uint8List? audio;
  final Uint8List? cover;
  final List<String> warnings;
}

/// 网页播放器自动制卡的逐句重放：seek 到 cue 前 [preRollMs] → 播 → cue 中点截帧 →
/// 播过 cue 末尾 [tailMs] → 暂停 → 从 WASAPI loopback 环形缓冲回取这段时间的音频。
///
/// 时间窗按**墙钟**取：loopback 只有「当前时刻往前 backMs」一种语义（契约见
/// [GalAudioSource.grabRecent]），所以记下观测到开播的时刻 t0，暂停后取 `now - t0`。
/// 站点解码延迟 / 状态轮询相位都落在这一窗之内，不用猜播放器内部时钟。
///
/// 纯编排、无 UI：[sleep] / [now] 可注入，测试里用假时钟推进。
class WebMineReplayRunner {
  WebMineReplayRunner({
    required this.host,
    required this.audioSource,
    required this.encodeAudio,
    Future<void> Function(Duration d)? sleep,
    DateTime Function()? now,
    this.preRollMs = 300,
    this.tailMs = 250,
    this.pollMs = 100,
    this.seekTimeoutMs = 8000,
    this.playTimeoutMs = 5000,
  }) : _sleep = sleep ?? ((Duration d) => Future<void>.delayed(d)),
       _now = now ?? DateTime.now;

  final WebMineReplayHost host;

  /// 已 `start()` 的 loopback 源；null = 本机无 loopback（非 Windows / 插件缺失），
  /// 只截帧不录音。
  final GalAudioSource? audioSource;

  /// PCM 切片 → 容器字节（`pcmSliceToAacBytes`）。失败回 null。
  final Future<Uint8List?> Function(GalAudioSlice slice) encodeAudio;

  final int preRollMs;
  final int tailMs;
  final int pollMs;
  final int seekTimeoutMs;
  final int playTimeoutMs;

  final Future<void> Function(Duration d) _sleep;
  final DateTime Function() _now;

  /// loopback 环形缓冲 60 s；回取窗封顶留 1 s 余量。
  static const int kMaxBackMs = 59000;

  /// 单句最长等待：cue 长度 + 8 s（站点缓冲/广告）。
  int _playDeadlineMs(int cueStartMs, int cueEndMs) =>
      (cueEndMs - cueStartMs).clamp(0, kMaxBackMs) + 8000;

  Future<WebMineReplayCapture> capture({
    required int cueStartMs,
    required int cueEndMs,
  }) async {
    final List<String> warnings = <String>[];
    final int endMs = cueEndMs > cueStartMs ? cueEndMs : cueStartMs + 1000;
    final int target = (cueStartMs - preRollMs).clamp(0, 1 << 31);

    await host.pause();
    await host.seek(target);
    final bool seeked = await _waitUntil(() {
      final int? pos = host.positionMs;
      return pos != null && (pos - target).abs() <= 1000;
    }, seekTimeoutMs);
    if (!seeked) warnings.add('seek_timeout');

    await host.play();
    final bool started = await _waitUntil(() => host.isPlaying, playTimeoutMs);
    if (!started) {
      await host.pause();
      return WebMineReplayCapture(
        audio: null,
        cover: null,
        warnings: <String>[...warnings, 'play_timeout'],
      );
    }
    final DateTime t0 = _now();

    Uint8List? cover;
    final int midMs = cueStartMs + (endMs - cueStartMs) ~/ 2;
    final int deadline = _playDeadlineMs(cueStartMs, endMs);
    final DateTime hardStop = t0.add(Duration(milliseconds: deadline));
    bool reachedEnd = false;
    while (_now().isBefore(hardStop)) {
      final int pos = host.positionMs ?? -1;
      if (cover == null && pos >= midMs) {
        cover = await host.screenshot();
        if (cover == null) warnings.add('screenshot_null');
      }
      if (pos >= endMs + tailMs) {
        reachedEnd = true;
        break;
      }
      await _sleep(Duration(milliseconds: pollMs));
    }
    await host.pause();
    if (!reachedEnd) warnings.add('cue_end_timeout');
    // 中点没轮到（cue 极短 / 位置轮询跳过）就在暂停处补一张。
    cover ??= await host.screenshot();

    Uint8List? audio;
    final GalAudioSource? src = audioSource;
    if (src == null) {
      warnings.add('loopback_unavailable');
    } else {
      final int elapsed = _now().difference(t0).inMilliseconds;
      final int backMs = (elapsed + 150).clamp(500, kMaxBackMs);
      GalAudioSlice? slice;
      try {
        slice = await src.grabRecent(backMs);
      } catch (e) {
        warnings.add('loopback_grab_failed: $e');
      }
      if (slice == null || slice.isEmpty) {
        if (!warnings.any((String w) => w.startsWith('loopback_grab'))) {
          warnings.add('loopback_empty');
        }
      } else {
        audio = await encodeAudio(slice);
        if (audio == null || audio.isEmpty) {
          audio = null;
          warnings.add('audio_encode_failed');
        }
      }
    }
    return WebMineReplayCapture(audio: audio, cover: cover, warnings: warnings);
  }

  Future<bool> _waitUntil(bool Function() done, int timeoutMs) async {
    final DateTime until = _now().add(Duration(milliseconds: timeoutMs));
    while (!done()) {
      if (!_now().isBefore(until)) return false;
      await _sleep(Duration(milliseconds: pollMs));
    }
    return true;
  }
}
