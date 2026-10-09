import 'package:audio_service/audio_service.dart' as ag;

/// 系统媒体控制（通知栏 / 锁屏 / 蓝牙 AVRCP / 车机 / 耳机线控）发来的播放意图。
///
/// PLAY 与 PAUSE 是两种**有方向**的命令：蓝牙耳机 / 车机重连时常自动补发 PLAY，
/// 播放中收到它必须保持播放。只有耳机单击（[ag.MediaButton.media]）本身是「切换」
/// 语义。三者不能压成同一个无方向事件，否则播放中补发的 PLAY 会把声音暂停。
enum MediaPlayIntent { play, pause, toggle }

class FushiAudioHandler extends ag.BaseAudioHandler {
  FushiAudioHandler({
    required this.onPlayIntent,
    required this.onSeek,
    required this.onRewind,
    required this.onFastForward,
    this.onSkipToNext,
    this.onSkipToPrevious,
    this.onToggleFloatingLyric,
  });

  final void Function(MediaPlayIntent intent) onPlayIntent;
  final Function(Duration) onSeek;
  final Function() onRewind;
  final Function() onFastForward;
  final Function()? onSkipToNext;
  final Function()? onSkipToPrevious;

  /// 通知栏「悬浮字幕」custom action 回调（仅 Android 媒体通知）。null 时不在
  /// 通知 controls 里加该按钮。
  final Function()? onToggleFloatingLyric;

  @override
  Future<void> play() async {
    onPlayIntent(MediaPlayIntent.play);
  }

  @override
  Future<void> pause() async {
    onPlayIntent(MediaPlayIntent.pause);
  }

  /// 耳机单击是切换语义，交给会话按播放器真实状态切换。不走基类实现：基类按
  /// [playbackState] 分派 play / pause，而关掉媒体通知时 [playbackState] 从不更新、
  /// 恒为初始的「未播放」，单击会被恒判成 PLAY，播放中按耳机再也停不下来。
  @override
  Future<void> click([ag.MediaButton button = ag.MediaButton.media]) async {
    if (button == ag.MediaButton.media) {
      onPlayIntent(MediaPlayIntent.toggle);
      return;
    }
    await super.click(button);
  }

  @override
  Future<void> seek(Duration position) async {
    onSeek(position);
  }

  @override
  Future<void> fastForward() async {
    onFastForward();
  }

  @override
  Future<void> rewind() async {
    onRewind();
  }

  @override
  Future<void> skipToNext() async {
    onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    onSkipToPrevious?.call();
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == _toggleFloatingLyricAction) {
      onToggleFloatingLyric?.call();
      return null;
    }
    return super.customAction(name, extras);
  }

  static const String _toggleFloatingLyricAction = 'toggleFloatingLyric';

  /// 「悬浮字幕」通知 custom action。仅当 [onToggleFloatingLyric] 非 null 时加入
  /// controls，触发回 [customAction] 路由 `toggleFloatingLyric`。
  ag.MediaControl get _floatingLyricControl => ag.MediaControl.custom(
        androidIcon: 'drawable/ic_notif_floating_lyric',
        label: 'Floating subtitle',
        name: _toggleFloatingLyricAction,
      );

  void updatePlaybackState({
    required bool playing,
    required Duration position,
    required double speed,
    required Duration duration,
  }) {
    final bool withFloatingLyric = onToggleFloatingLyric != null;
    playbackState.add(ag.PlaybackState(
      controls: [
        ag.MediaControl.skipToPrevious,
        if (playing) ag.MediaControl.pause else ag.MediaControl.play,
        ag.MediaControl.skipToNext,
        if (withFloatingLyric) _floatingLyricControl,
      ],
      systemActions: const {
        ag.MediaAction.seek,
        ag.MediaAction.seekForward,
        ag.MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: ag.AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
      speed: speed,
    ));
  }

  void setMediaItemInfo({
    required String title,
    String? artist,
    Duration? duration,
    Uri? artUri,
  }) {
    mediaItem.add(ag.MediaItem(
      id: 'hibiki_audiobook',
      title: title,
      artist: artist,
      duration: duration,
      artUri: artUri,
    ));
  }

  void updateNotificationSubtitle({
    required String title,
    required String? subtitle,
    String? fallbackArtist,
  }) {
    final ag.MediaItem? current = mediaItem.value;
    if (current == null) return;
    final String? cleanedSubtitle = _cleanNotificationSubtitle(subtitle);
    mediaItem.add(current.copyWith(
      title: title,
      artist: cleanedSubtitle ?? fallbackArtist,
      displaySubtitle: cleanedSubtitle,
      displayDescription: cleanedSubtitle,
    ));
  }

  String? _cleanNotificationSubtitle(String? subtitle) {
    final String? cleaned = subtitle?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    return cleaned;
  }

  void clearNotification() {
    playbackState.add(ag.PlaybackState());
    mediaItem.add(null);
  }
}
