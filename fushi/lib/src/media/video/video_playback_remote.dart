import 'package:flutter/foundation.dart';

/// 视频播放页对外暴露的最小遥控面（桌面控制通道 `fushi_cli play ...` 用）。
///
/// 播放控制器是 `_VideoFushiPageState` 的私有字段，页面在 initState 把自己的实现
/// 登记进 [videoPlaybackRemotes]、dispose 时注销。实现只转调页内已有的执行体
/// （底栏 / 悬浮球 / 快捷键背后的同一批方法），不另写播放逻辑。
abstract interface class VideoPlaybackRemote {
  /// 当前播放状态；控制器尚未就绪（首开加载中 / 加载失败）时为 null。
  VideoPlaybackSnapshot? snapshot();

  Future<void> play();

  Future<void> pause();

  Future<void> toggle();

  /// 绝对跳转到 [positionMs]（毫秒）。
  Future<void> seekToMs(int positionMs);

  /// 相对当前位置前后跳 [deltaMs]（毫秒，负数后退）。
  Future<void> seekByMs(int deltaMs);

  /// 设置倍速（与页内倍速菜单同一入口，含持久化与夹取）。
  Future<void> setRate(double rate);

  /// 上一句字幕（无字幕时回退若干秒，与底栏「上一句」按钮同语义）。
  Future<void> previousCue();

  /// 下一句字幕（无字幕时前进若干秒，与底栏「下一句」按钮同语义）。
  Future<void> nextCue();
}

/// [VideoPlaybackRemote.snapshot] 的只读快照。
@immutable
class VideoPlaybackSnapshot {
  const VideoPlaybackSnapshot({
    required this.title,
    required this.bookUid,
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.speed,
    required this.cue,
  });

  final String? title;
  final String bookUid;
  final int? positionMs;
  final int? durationMs;
  final bool playing;
  final double speed;

  /// 当前字幕句文本（无字幕 / 句间空隙为 null）。
  final String? cue;
}

/// 视频播放页遥控登记表：按登记顺序成栈，[current] 恒为最后登记、仍存活的那页
/// （叠加打开多个视频页时以最上层为准）；[unregister] 只移除传入的那一个。
class VideoPlaybackRemoteRegistry {
  final List<VideoPlaybackRemote> _stack = <VideoPlaybackRemote>[];

  /// 当前可遥控的视频页；没有视频页时为 null。
  final ValueNotifier<VideoPlaybackRemote?> current =
      ValueNotifier<VideoPlaybackRemote?>(null);

  /// 登记 [remote] 到栈顶；已登记过的重复调用是 no-op（不改变栈序）。
  void register(VideoPlaybackRemote remote) {
    if (_stack.contains(remote)) return;
    _stack.add(remote);
    current.value = remote;
  }

  /// 注销 [remote]（未登记时 no-op）；栈顶随之回落到下一个仍登记的页面。
  void unregister(VideoPlaybackRemote remote) {
    if (!_stack.remove(remote)) return;
    current.value = _stack.isEmpty ? null : _stack.last;
  }

  @visibleForTesting
  int get debugLength => _stack.length;
}

/// 进程级唯一登记点。
final VideoPlaybackRemoteRegistry videoPlaybackRemotes =
    VideoPlaybackRemoteRegistry();
