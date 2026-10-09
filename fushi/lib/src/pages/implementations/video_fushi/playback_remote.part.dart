part of '../video_fushi_page.dart';

/// 本页对桌面控制通道（`fushi_cli play ...`）的遥控实现，登记进
/// [videoPlaybackRemotes]（initState 登记、dispose 注销，见 [_VideoFushiPageState]）。
///
/// 每个动作只转调页内已有执行体，与悬浮球 / 底栏同名按钮同一条路径
/// （[_buildVideoFloatingBallScene]：播放暂停、上 / 下一句；细进度条的
/// `controller.seekMs`；倍速菜单的 [_VideoFushiPageState._setSpeed]），且同样不唤起
/// 控制条——遥控时用户的手不在控制条上。控制器尚未就绪时 [snapshot] 为 null、
/// 动作为 no-op（路由层先看快照再下发）。
class _VideoPagePlaybackRemote implements VideoPlaybackRemote {
  _VideoPagePlaybackRemote(this._state);

  final _VideoFushiPageState _state;

  VideoPlayerController? get _controller =>
      _state.mounted ? _state._controller : null;

  @override
  VideoPlaybackSnapshot? snapshot() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return null;
    return VideoPlaybackSnapshot(
      title: _state._title,
      bookUid: _state.widget.bookUid,
      positionMs: controller.positionMs,
      durationMs: controller.durationMs,
      playing: controller.isPlaying,
      speed: controller.speed,
      cue: controller.currentCue?.text,
    );
  }

  // play() 的 Future 可能挂到下一次暂停才 settle（与有声书 BUG-1736 同理），页内
  // 所有入口都 unawaited，这里同样不等，免得遥控请求被挂住。
  @override
  Future<void> play() async {
    final VideoPlayerController? controller = _controller;
    if (controller != null) unawaited(controller.play());
  }

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> toggle() async {
    final VideoPlayerController? controller = _controller;
    if (controller != null) unawaited(controller.playOrPause());
  }

  @override
  Future<void> seekToMs(int positionMs) async =>
      _controller?.seekMs(positionMs);

  @override
  Future<void> seekByMs(int deltaMs) async =>
      _controller?.seekRelative(deltaMs);

  @override
  Future<void> setRate(double rate) async {
    if (_controller == null) return;
    await _state._setSpeed(rate);
  }

  @override
  Future<void> previousCue() async => _controller?.skipToPrevCueOrSeekBack(
    seekSeconds: _state._asbConfig.seekSeconds,
  );

  @override
  Future<void> nextCue() async => _controller?.skipToNextCueOrSeekForward(
    seekSeconds: _state._asbConfig.seekSeconds,
  );
}
