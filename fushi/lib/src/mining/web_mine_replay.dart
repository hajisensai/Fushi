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

  /// 动图 / 片段用的一帧（JPEG：比 PNG 编码快、体积小，逐帧采样扛得住）。失败回 null。
  Future<Uint8List?> frame();
}

/// 重放期间采到的一帧：[atMs] = 距观测到开播（t0）的墙钟毫秒，与音频回取窗同一时基。
class WebMineReplayFrame {
  const WebMineReplayFrame({required this.bytes, required this.atMs});

  final Uint8List bytes;
  final int atMs;
}

/// 一句重放抓到的媒体。[audio] 是已编码容器字节（引擎逐字节写盘，绝不能是裸 PCM），
/// [cover] 是 PNG 截图；缺哪个哪个为 null，[warnings] 说明原因（进队列行的 error 列）。
///
/// [frames] 是开了 [WebMineReplayRunner.captureFrames] 时的帧序列（动图 / 音画片段的
/// 画面来源）。[audioLeadMs] = 音频比 t0 早开始多少毫秒（回取窗起点 = t0 - lead），
/// [clipDurationMs] = 片段总长（有音频时 = 回取窗长度）：合片段时帧时间轴整体后移
/// lead 才与音频对齐。
class WebMineReplayCapture {
  const WebMineReplayCapture({
    required this.audio,
    required this.cover,
    required this.warnings,
    this.frames = const <WebMineReplayFrame>[],
    this.audioLeadMs = 0,
    this.clipDurationMs = 0,
  });

  final Uint8List? audio;
  final Uint8List? cover;
  final List<String> warnings;
  final List<WebMineReplayFrame> frames;
  final int audioLeadMs;
  final int clipDurationMs;
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
    this.captureFrames = false,
    this.frameIntervalMs = 125,
    this.maxFrames = 240,
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

  /// 播放期间连续采帧（制卡图片模式是动图 / 音画片段时开）。关着只截中点一张封面。
  final bool captureFrames;

  /// 采帧间隔（≈ 8 fps；截帧本身的耗时计入间隔，帧率尽力而为）。
  final int frameIntervalMs;

  /// 单句帧数上限（30 s × 8 fps），防长句把内存吃光。
  final int maxFrames;

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
    final List<WebMineReplayFrame> frames = <WebMineReplayFrame>[];
    int nextFrameAtMs = 0;
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
      int waitMs = pollMs;
      if (captureFrames && frames.length < maxFrames) {
        final int at = _now().difference(t0).inMilliseconds;
        if (at >= nextFrameAtMs) {
          final Uint8List? shot = await host.frame();
          if (shot != null && shot.isNotEmpty) {
            frames.add(WebMineReplayFrame(bytes: shot, atMs: at));
          }
          nextFrameAtMs = at + frameIntervalMs;
        }
        // 轮询节拍贴着下一帧走（固定 100 ms 一拍会把 125 ms 间隔拖成 200 ms）。
        final int untilNext =
            nextFrameAtMs - _now().difference(t0).inMilliseconds;
        waitMs = untilNext.clamp(1, pollMs);
      }
      await _sleep(Duration(milliseconds: waitMs));
    }
    if (captureFrames && frames.length < 2) warnings.add('frames_insufficient');
    await host.pause();
    if (!reachedEnd) warnings.add('cue_end_timeout');
    // 中点没轮到（cue 极短 / 位置轮询跳过）就在暂停处补一张。
    cover ??= await host.screenshot();

    Uint8List? audio;
    int audioLeadMs = 0;
    int clipDurationMs = _now().difference(t0).inMilliseconds;
    final GalAudioSource? src = audioSource;
    if (src == null) {
      warnings.add('loopback_unavailable');
    } else {
      final int elapsed = _now().difference(t0).inMilliseconds;
      final int backMs = (elapsed + 150).clamp(500, kMaxBackMs);
      audioLeadMs = backMs - elapsed;
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
        } else {
          clipDurationMs = backMs;
        }
      }
    }
    return WebMineReplayCapture(
      audio: audio,
      cover: cover,
      warnings: warnings,
      frames: frames,
      audioLeadMs: audio == null ? 0 : audioLeadMs,
      clipDurationMs: clipDurationMs,
    );
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
