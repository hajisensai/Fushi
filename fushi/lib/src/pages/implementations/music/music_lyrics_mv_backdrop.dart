/// 歌词页的 MV 背景：当前曲目绑了本机 MV（或曲目本身就是 MV 视频）时，歌词页与全屏歌词
/// 动画的背景默认放 MV 画面（设置 › 音乐 › 歌词页背景「有 MV 时背景放 MV」可关）。
///
/// 声音仍是音乐引擎放的曲库音轨；MV 用一个**静音、不解音轨**的 mpv 实例只出画面，跟着
/// 引擎时钟走：MV 时刻 = 曲目时刻 + 绑定偏移（`music_videos.offset_ms`，声纹对齐求得）。
/// 偏差超过 [kMusicMvBackdropSeekTolerance] 才 seek，引擎暂停 / 拖动 / 换歌画面跟着停 /
/// 跳 / 换；MV 时间轴之外（前奏比 MV 早、MV 比歌短）画面淡出，露出下面的流体背景。
///
/// 这里只读绑定、不做任何解码：找 MV 是音乐来源扫完后的后台匹配
/// （`music_video_auto_match.dart`，每个视频只解码一次、每对只对一次）或曲目详情里的
/// 「找本地 MV」。网络 MV（YouTube）不当背景串流，仍从曲目详情进 MV 页看。
library;

import 'dart:async';

import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/media/music/music_local_video.dart'
    show isMusicLocalFilePath;
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart'
    show resolvePlatformHwdec, setMpvPropertiesInOrder;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart' show isVideoMediaPath;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 画面与音频偏差超过这么多才 seek（小偏差 seek 反而卡顿，背景画面看不出 0.3 秒）。
const Duration kMusicMvBackdropSeekTolerance = Duration(milliseconds: 300);

/// 同步检查间隔。
const Duration kMusicMvBackdropSyncInterval = Duration(milliseconds: 250);

/// 背景要放的 MV：本机视频文件 + 偏移（MV 时刻 = 曲目时刻 + [offsetMs]）。
@immutable
class MusicMvBackdropSource {
  const MusicMvBackdropSource({required this.path, required this.offsetMs});

  final String path;
  final int offsetMs;

  @override
  bool operator ==(Object other) =>
      other is MusicMvBackdropSource &&
      other.path == path &&
      other.offsetMs == offsetMs;

  @override
  int get hashCode => Object.hash(path, offsetMs);
}

/// 一次同步检查的结论（纯函数 [planMusicMvBackdropSync] 的产物）。
@immutable
class MusicMvBackdropSyncPlan {
  const MusicMvBackdropSyncPlan({
    required this.visible,
    required this.play,
    this.seekTo,
  });

  /// MV 画面该不该显示（目标时刻落在 MV 时间轴内）。
  final bool visible;

  /// 画面该不该走（音频在放且画面可见）。
  final bool play;

  /// 要 seek 到的 MV 时刻；null = 不用 seek。
  final Duration? seekTo;
}

/// 纯函数：按音频位置算 MV 画面这一刻该怎样。[videoDuration] 为 null / 0 = 还不知道
/// 时长（不判尾部越界）。目标时刻在 MV 之前时把画面停在开头备好，不显示。
MusicMvBackdropSyncPlan planMusicMvBackdropSync({
  required Duration audioPosition,
  required bool audioPlaying,
  required int offsetMs,
  required Duration videoPosition,
  Duration? videoDuration,
  Duration tolerance = kMusicMvBackdropSeekTolerance,
}) {
  final Duration target = audioPosition + Duration(milliseconds: offsetMs);
  final bool knownLength =
      videoDuration != null && videoDuration > Duration.zero;
  if (target < Duration.zero) {
    return MusicMvBackdropSyncPlan(
      visible: false,
      play: false,
      seekTo: videoPosition == Duration.zero ? null : Duration.zero,
    );
  }
  if (knownLength && target >= videoDuration) {
    return const MusicMvBackdropSyncPlan(visible: false, play: false);
  }
  final Duration drift = videoPosition - target;
  final bool off = drift.abs() > tolerance;
  return MusicMvBackdropSyncPlan(
    visible: true,
    play: audioPlaying,
    seekTo: off ? target : null,
  );
}

/// 曲目本身就是本机 MV 视频时直接拿它当背景（偏移 = CUE 起点，普通文件 0）；否则 null。
MusicMvBackdropSource? musicMvBackdropSelfSource(MusicPlayItem item) =>
    isVideoMediaPath(item.path) && isMusicLocalFilePath(item.path)
    ? MusicMvBackdropSource(path: item.path, offsetMs: item.startMs ?? 0)
    : null;

/// 从曲目的 MV 绑定里挑第一个能当背景放的（绑定已按「用户确认优先、置信度降序」排好），
/// 解析成本机文件；都放不了返回 null。
Future<MusicMvBackdropSource?> resolveMusicMvBackdropSource(
  FushiDatabase db,
  List<MusicVideoRow> bindings,
) async {
  for (final MusicVideoRow row in bindings) {
    final String? file = await resolveMusicVideoLocalFile(db, row);
    if (file != null) {
      return MusicMvBackdropSource(path: file, offsetMs: row.offsetMs);
    }
  }
  return null;
}

/// 曲目 [trackUid] 当前能当背景放的 MV（[resolveMusicMvBackdropSource]），绑定一变就
/// 重发：后台匹配绑上、曲目详情里手动找到 / 解绑、MV 页改了偏移，正开着的歌词页都跟着换。
Stream<MusicMvBackdropSource?> watchMusicMvBackdropSource(
  FushiDatabase db,
  String trackUid,
) => db
    .watchMusicVideos(trackUid)
    .asyncMap(
      (List<MusicVideoRow> rows) => resolveMusicMvBackdropSource(db, rows),
    )
    .distinct();

/// 歌词页持有的 MV 背景控制器：盯引擎换歌、订阅当前曲目的 MV 绑定、管一个只出画面的
/// mpv 实例并让它跟音频对齐。用完调 [dispose]。
class MusicMvBackdropController extends ChangeNotifier
    with WidgetsBindingObserver {
  MusicMvBackdropController({
    required MusicPlayerEngine engine,
    required FushiPlaybackClock clock,
    required FushiDatabase database,
    required bool enabled,
  }) : _engine = engine,
       _clock = clock,
       _database = database,
       _enabled = enabled {
    _engine.addListener(_onEngine);
    WidgetsBinding.instance.addObserver(this);
    _onEngine();
  }

  final MusicPlayerEngine _engine;
  final FushiPlaybackClock _clock;
  final FushiDatabase _database;

  bool _enabled;
  bool _disposed = false;
  bool _foreground = true;
  String? _trackUid;
  int _loadToken = 0;
  StreamSubscription<MusicMvBackdropSource?>? _bindingSub;
  MusicMvBackdropSource? _source;
  Player? _player;
  VideoController? _video;
  Timer? _timer;
  bool _visible = false;
  bool _seeking = false;
  bool _opened = false;

  /// 现在有没有 MV 画面盖在背景上（全屏歌词动画据此不画共享背景）。
  bool get showing => _visible && _video != null;

  /// 画面（还没建播放器时为 null）。
  VideoController? get video => _video;

  /// 当前背景用的 MV（测试 / 调试用）。
  MusicMvBackdropSource? get source => _source;

  /// 设置开关。在 build 里赋值也安全：真正的切换推迟到微任务。
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    scheduleMicrotask(() {
      if (_disposed) return;
      _trackUid = null;
      _onEngine();
    });
  }

  void _onEngine() {
    if (_disposed) return;
    final MusicPlayItem? item = _enabled ? _engine.current : null;
    final String? uid = item?.trackUid;
    if (uid == _trackUid) return;
    _trackUid = uid;
    final int token = ++_loadToken;
    unawaited(_bindingSub?.cancel());
    _bindingSub = null;
    final MusicMvBackdropSource? self = item == null
        ? null
        : musicMvBackdropSelfSource(item);
    if (item == null || self != null) {
      unawaited(_apply(self));
      return;
    }
    _bindingSub = watchMusicMvBackdropSource(_database, item.trackUid).listen(
      (MusicMvBackdropSource? src) {
        if (_disposed || token != _loadToken) return;
        unawaited(_apply(src));
      },
      onError: (Object e, StackTrace st) =>
          ErrorLogService.instance.log('MusicMvBackdrop.load', e, st),
    );
  }

  Future<void> _apply(MusicMvBackdropSource? src) async {
    if (src == _source) return;
    final MusicMvBackdropSource? prev = _source;
    if (src != null && prev != null && src.path == prev.path && _opened) {
      // 只改了偏移（MV 页里调过）：同一个文件不重开，下一次同步按新偏移对齐。
      _source = src;
      _sync();
      return;
    }
    _source = src;
    _setVisible(false);
    if (src == null) {
      _timer?.cancel();
      _timer = null;
      _opened = false;
      await _player?.stop();
      return;
    }
    final Player player = _ensurePlayer();
    _opened = false;
    try {
      await player.open(Media(src.path), play: false);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('MusicMvBackdrop.open', e, st);
      return;
    }
    if (_disposed || !identical(src, _source)) return;
    _opened = true;
    _timer ??= Timer.periodic(kMusicMvBackdropSyncInterval, (_) => _sync());
    _sync();
  }

  Player _ensurePlayer() {
    final Player? existing = _player;
    if (existing != null) return existing;
    final Player player = Player();
    _player = player;
    _video = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: resolvePlatformHwdec('auto-safe'),
      ),
    );
    // 只出画面：不选音轨（不解码音频，也绝不和引擎两路出声）、不循环、精确 seek。
    unawaited(
      setMpvPropertiesInOrder(player, <String, String>{
        'aid': 'no',
        'mute': 'yes',
        'loop-file': 'no',
        'hr-seek': 'yes',
      }),
    );
    unawaited(player.setVolume(0));
    return player;
  }

  void _sync() {
    final Player? player = _player;
    final MusicMvBackdropSource? src = _source;
    if (_disposed || player == null || src == null || !_opened) return;
    if (!_foreground) {
      _setVisible(false);
      if (player.state.playing) unawaited(player.pause());
      return;
    }
    final MusicMvBackdropSyncPlan plan = planMusicMvBackdropSync(
      audioPosition: _clock.position,
      audioPlaying: _engine.isPlaying,
      offsetMs: src.offsetMs,
      videoPosition: player.state.position,
      videoDuration: player.state.duration,
    );
    _setVisible(plan.visible);
    final Duration? seekTo = plan.seekTo;
    if (seekTo != null && !_seeking) {
      _seeking = true;
      unawaited(
        player.seek(seekTo).whenComplete(() {
          _seeking = false;
        }),
      );
    }
    if (plan.play != player.state.playing) {
      unawaited(plan.play ? player.play() : player.pause());
    }
  }

  void _setVisible(bool value) {
    if (value == _visible) return;
    _visible = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadToken++;
    _engine.removeListener(_onEngine);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_bindingSub?.cancel());
    _bindingSub = null;
    _timer?.cancel();
    unawaited(_player?.dispose());
    super.dispose();
  }
}

/// MV 背景层：盖在流体背景上，MV 可见时淡入、不可见时淡出；上面压一层上浅下深的黑色
/// 渐变保证歌词可读。不吃点击。
class MusicLyricsMvBackdrop extends StatelessWidget {
  const MusicLyricsMvBackdrop({super.key, required this.controller});

  final MusicMvBackdropController controller;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final VideoController? video = controller.video;
        return AnimatedOpacity(
          key: const ValueKey<String>('music_lyrics_mv_backdrop'),
          opacity: controller.showing ? 1 : 0,
          duration: fushiMotionDuration(context, FushiMotion.medium),
          child: video == null
              ? const SizedBox.expand()
              : Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Video(
                      controller: video,
                      controls: NoVideoControls,
                      fit: BoxFit.cover,
                      fill: Colors.transparent,
                      wakelock: false,
                      subtitleViewConfiguration:
                          const SubtitleViewConfiguration(visible: false),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: <Color>[
                            Color.fromRGBO(0, 0, 0, 0.25),
                            Color.fromRGBO(0, 0, 0, 0.5),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    ),
  );
}
