import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// 音频输出丢失后的自动恢复（BUG-3767）。
///
/// **现场**：播放中 Windows 音频设备失效（`AUDCLNT_E_DEVICE_INVALIDATED`：默认输出
/// 设备切换、蓝牙 / HDMI / USB 声卡掉线、被别的程序独占），mpv 的 wasapi 只重试一次，
/// 再失败就打 `[cplayer] Could not open/initialize audio device -> no sound.`，随后
/// `error_on_track` **把音轨取消选中**（`aid` 变 `no`）——视频照放，声音永久消失，只能
/// 重启 app。
///
/// 真 libmpv 实测（`test/media/video/video_audio_output_recovery_test.dart`）：
/// - 设备恢复后 mpv **不会**自己把音轨选回来；
/// - `ao-reload` 也无效（mpv 在没有 ao 时直接 return）；
/// - **重新选中原音轨**（写回具体轨号的 `aid`）会重建音频链与 ao，声音恢复；写
///   `aid=auto` 是 no-op（见 [videoAudioRecoveryTargetAid]）；
/// - 换下一集不沿用 `aid=no`，所以恢复状态按 load 重置。
///
/// 于是本类在「音频输出丢失」后按退避节奏反复重选音轨，直到 ao 真建起来；系统音频
/// 设备列表变化（插拔 / 切换，mpv wasapi 的热插拔通知经 `audio-device-list` 上来）时
/// 立即重试一次。重试次数不设上限：设备可能几分钟后才回来，每次失败的代价只是 mpv
/// 再打一行错误，间隔封顶 [kVideoAudioOutputRecoveryBackoff] 的最后一档。
class VideoAudioOutputRecovery {
  VideoAudioOutputRecovery({
    required Future<VideoAudioRecoveryAttempt> Function() reselectAudio,
    List<Duration> backoff = kVideoAudioOutputRecoveryBackoff,
    void Function(String message)? log,
  }) : assert(backoff.isNotEmpty),
       _reselectAudio = reselectAudio,
       _backoff = backoff,
       _log = log;

  final Future<VideoAudioRecoveryAttempt> Function() _reselectAudio;
  final List<Duration> _backoff;
  final void Function(String message)? _log;

  bool _lost = false;
  bool _inFlight = false;
  int _attempts = 0;
  Timer? _timer;

  /// 每次 [reset] 递增；在途尝试回来时代次变了就丢弃结果（换集 / 销毁）。
  int _generation = 0;

  /// 当前是否处于「音频输出丢失、正在恢复」状态。
  bool get lost => _lost;

  /// 已经发起过的恢复尝试次数（本轮丢失以来）。
  int get attempts => _attempts;

  /// mpv 错误流的一行。只认「音频设备打不开」这一种，其余错误不归本类管。
  void onPlayerError(String message) {
    if (!isVideoAudioOutputLostMessage(message)) return;
    if (_lost) {
      // 在途尝试自己失败时 mpv 会再报一次，结果由那次尝试的返回值处理，不重复排期。
      if (!_inFlight && _timer == null) _schedule();
      return;
    }
    _lost = true;
    _attempts = 0;
    _log?.call('audio output lost; scheduling audio track reselect');
    _schedule();
  }

  /// 系统音频设备列表变化：设备回来了的最强信号，丢失状态下立即重试并重置退避。
  void onAudioDevicesChanged() {
    if (!_lost || _inFlight) return;
    _timer?.cancel();
    _timer = null;
    _attempts = 0;
    unawaited(_attempt());
  }

  /// 新 load / Player 销毁：上一片的恢复状态作废。
  void reset() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _lost = false;
    _inFlight = false;
    _attempts = 0;
  }

  void dispose() => reset();

  void _schedule() {
    final int index = _attempts < _backoff.length
        ? _attempts
        : _backoff.length - 1;
    _timer?.cancel();
    _timer = Timer(_backoff[index], () {
      _timer = null;
      unawaited(_attempt());
    });
  }

  Future<void> _attempt() async {
    if (!_lost || _inFlight) return;
    final int generation = _generation;
    _inFlight = true;
    _attempts++;
    VideoAudioRecoveryAttempt result;
    try {
      result = await _reselectAudio();
    } catch (error) {
      _log?.call('audio track reselect threw: $error');
      result = VideoAudioRecoveryAttempt.stillLost;
    }
    if (generation != _generation) return; // 换集 / 销毁：结果作废。
    _inFlight = false;
    switch (result) {
      case VideoAudioRecoveryAttempt.recovered:
        _log?.call('audio output recovered after $_attempts attempt(s)');
        _lost = false;
        _attempts = 0;
      case VideoAudioRecoveryAttempt.abandoned:
        _log?.call('audio output recovery abandoned');
        _lost = false;
        _attempts = 0;
      case VideoAudioRecoveryAttempt.stillLost:
        _schedule();
    }
  }
}

/// 一次恢复尝试的结果。
enum VideoAudioRecoveryAttempt {
  /// ao 已建起来（`current-ao` 非空）。
  recovered,

  /// 还是没有 ao，按退避继续。
  stillLost,

  /// 没有可恢复的目标（Player 已换 / 已销毁、用户本来就选了无音轨），停止。
  abandoned,
}

/// 重试间隔：前几次快（设备切换通常一两秒内就绪），之后封顶 30 秒。
const List<Duration> kVideoAudioOutputRecoveryBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// mpv `[cplayer]` 在 ao 初始化失败、随后取消选中音轨时打的那一行。
bool isVideoAudioOutputLostMessage(String message) =>
    message.contains('Could not open/initialize audio device');

/// 恢复时要写回的 `aid`，**必须是具体轨号**。
///
/// media_kit 记的选轨（`state.track.audio.id`）不跟随 mpv 的取消选中，是具体轨号时
/// 正是丢失前在放的那条（load 后 `adoptNativeAudioSelection` 会把 `auto` 对齐成具体
/// 轨）。仍是 `auto` 时不能原样写回：真 libmpv 实测播放中写 `aid=auto` 是 no-op，
/// 音轨永远选不回来——按 mpv 默认选轨的同一口径挑容器默认轨，没有就挑第一条真实轨。
/// 用户本来就选了无音轨（`no`）或没有可选的轨时返回 null（不恢复）。
String? videoAudioRecoveryTargetAid(
  String? selectedId,
  List<AudioTrack> tracks,
) {
  final String? id = selectedId?.trim();
  if (id == null || id.isEmpty || id == 'no') return null;
  final List<AudioTrack> real = tracks
      .where((AudioTrack t) => t.id != 'auto' && t.id != 'no')
      .toList();
  if (id != 'auto') return id;
  for (final AudioTrack track in real) {
    if (track.isDefault ?? false) return track.id;
  }
  return real.isEmpty ? null : real.first.id;
}
