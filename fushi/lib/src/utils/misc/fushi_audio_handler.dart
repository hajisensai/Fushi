import 'package:audio_service/audio_service.dart' as ag;
import 'package:flutter/foundation.dart' show mapEquals;

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
  /// [playbackState] 分派 play / pause，而 [playbackState] 只是会话推过来的镜像，
  /// 可能落后于播放器（或在会话起来前恒为初始的「未播放」），单击会被判反。
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

  /// 推播放态给 audio_service（Android 媒体会话 + 前台服务 / iOS Now Playing）。
  ///
  /// [minimal] = 「显示媒体通知」关着时的最简形态（BUG-3777 A）：播放态照推，
  /// 让 Android 照常进前台服务 + PARTIAL_WAKE_LOCK（无通知的媒体前台服务不被允许，
  /// 不推播放态则后台必被冻结），但通知只剩一个播放 / 暂停键——不给上下句、悬浮
  /// 字幕键，也不声明 seek（Android 13+ 没有 seek 动作就不画进度条，iOS 控制中心
  /// 的进度条不可拖）。
  ///
  /// [floatingLyricControl] = false 时完整形态也不放「悬浮字幕」键（后台视频没有
  /// 悬浮字幕可开）。
  void updatePlaybackState({
    required bool playing,
    required Duration position,
    required double speed,
    required Duration duration,
    bool minimal = false,
    bool floatingLyricControl = true,
  }) {
    if (minimal) {
      playbackState.add(
        ag.PlaybackState(
          controls: [
            if (playing) ag.MediaControl.pause else ag.MediaControl.play,
          ],
          androidCompactActionIndices: const [0],
          processingState: ag.AudioProcessingState.ready,
          playing: playing,
          updatePosition: position,
          speed: speed,
        ),
      );
      return;
    }
    final bool withFloatingLyric =
        floatingLyricControl && onToggleFloatingLyric != null;
    playbackState.add(
      ag.PlaybackState(
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
      ),
    );
  }

  /// 推一张完整媒体卡片。[subtitle] 非空（清洗后）时与 [updateNotificationSubtitle]
  /// 同样把当前句放进 `artist` / `displaySubtitle` / `displayDescription`，否则用
  /// [artist]。每次刷新既要基础信息又要当前句的调用方（音乐会话）必须一次传齐、
  /// 只推一张最终卡片：分两次调用会让「无副标题卡」与「有副标题卡」交替推送，
  /// [_pushMediaItem] 的去重永远命中不了（BUG-4507）。
  void setMediaItemInfo({
    required String title,
    String? artist,
    Duration? duration,
    Uri? artUri,
    String? subtitle,
  }) {
    final String? cleanedSubtitle = _cleanNotificationSubtitle(subtitle);
    _pushMediaItem(
      ag.MediaItem(
        id: 'fushi_audiobook',
        title: title,
        artist: cleanedSubtitle ?? artist,
        duration: duration,
        artUri: artUri,
        displaySubtitle: cleanedSubtitle,
        displayDescription: cleanedSubtitle,
      ),
    );
  }

  /// 最简媒体卡片：只有标题，没有作者 / 封面 / 时长（缺时长 + 无 seek 动作 =
  /// 不画进度条），配合 [updatePlaybackState] 的 `minimal` 形态使用。
  void setMinimalMediaItem({required String title}) {
    _pushMediaItem(ag.MediaItem(id: 'fushi_audiobook', title: title));
  }

  void updateNotificationSubtitle({
    required String title,
    required String? subtitle,
    String? fallbackArtist,
  }) {
    final ag.MediaItem? current = mediaItem.value;
    if (current == null) return;
    final String? cleanedSubtitle = _cleanNotificationSubtitle(subtitle);
    _pushMediaItem(
      current.copyWith(
        title: title,
        artist: cleanedSubtitle ?? fallbackArtist,
        displaySubtitle: cleanedSubtitle,
        displayDescription: cleanedSubtitle,
      ),
    );
  }

  /// 媒体卡片内容真变了才推给 audio_service（BUG-4507）。
  ///
  /// 会话在控制器每次 notify（播放进度 tick、cue 推进、播放态翻转）时都会重推
  /// 副标题，绝大多数时候内容一字未变。audio_service 0.18 的 Android 端每收到一次
  /// `setMediaItem` 就 `Executors.newSingleThreadExecutor()` 新开一条线程去跑
  /// `synchronized AudioService.setMetadata`，从不关闭；几千次重复推送 = 几千条线程
  /// 抢同一把锁，主线程 `buildNotification` 拿不到锁就 ANR。[ag.MediaItem] 的 `==`
  /// 只比 `id`，所以这里按卡片上真正显示的字段逐一比较。
  void _pushMediaItem(ag.MediaItem next) {
    final ag.MediaItem? current = mediaItem.value;
    if (current != null && mediaItemContentEquals(current, next)) return;
    mediaItem.add(next);
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

/// 两张媒体卡片推给平台的内容是否相同（[ag.MediaItem] 自带的 `==` 只比 `id`）。
bool mediaItemContentEquals(ag.MediaItem a, ag.MediaItem b) =>
    a.id == b.id &&
    a.title == b.title &&
    a.album == b.album &&
    a.artist == b.artist &&
    a.genre == b.genre &&
    a.duration == b.duration &&
    a.artUri == b.artUri &&
    mapEquals(a.artHeaders, b.artHeaders) &&
    a.playable == b.playable &&
    a.displayTitle == b.displayTitle &&
    a.displaySubtitle == b.displaySubtitle &&
    a.displayDescription == b.displayDescription &&
    a.rating == b.rating &&
    a.isLive == b.isLive &&
    mapEquals(a.extras, b.extras);
