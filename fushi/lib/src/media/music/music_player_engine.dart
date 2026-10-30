/// 音乐播放编排（设计 §7.2）：队列在 Dart，向输出后端只维持「当前 + 下一首」两项；
/// 后端无缝切到下一首时，引擎推进队列并把新的「下一首」补给后端。ReplayGain 按播放
/// 语境选：整张专辑顺序播 = album，随机 / 混排 = track。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 队列从哪来：决定 ReplayGain 模式（专辑语境用 album gain 保留曲间响度差）。
/// 循环模式：关（队尾停）/ 列表循环（队尾接回队首）/ 单曲循环（当前曲反复）。
enum MusicRepeatMode { off, all, one }

enum MusicQueueContext {
  /// 一张专辑按碟号 / 轨号顺序播。
  album,

  /// 跨专辑的曲目列表（歌曲分区、艺人、歌单）。
  mixed,
}

/// 播放来源的种类（落进播放流 `music_play_events.source_kind`，wire 值冻结）。
enum MusicPlaySourceKind {
  /// 本地曲库专辑（id = `albumUid`）。
  album('album'),

  /// 本地歌单（id = `playlistUid`）。
  playlist('playlist'),

  /// 在线插件专辑（id 见 [MusicPlaySource.pluginAlbum]）。
  pluginAlbum('plugin_album'),

  /// 在线插件歌单（id 见 [MusicPlaySource.pluginPlaylist]）。
  pluginPlaylist('plugin_playlist'),

  /// 媒体服务器专辑（id 见 [MusicPlaySource.serverAlbum]）。
  serverAlbum('server_album'),

  /// 媒体服务器歌单（id 见 [MusicPlaySource.serverPlaylist]）。
  serverPlaylist('server_playlist'),

  /// 艺人页（id = `artistUid`）。
  artist('artist'),

  /// 其它（歌曲分区、搜索结果、推荐 …；id 由调用方自定）。
  other('other');

  const MusicPlaySourceKind(this.wire);

  final String wire;

  /// wire 值 → 种类；不认识的（将来版本写的）归 [other]。
  static MusicPlaySourceKind fromWire(String wire) {
    for (final MusicPlaySourceKind k in values) {
      if (k.wire == wire) return k;
    }
    return other;
  }
}

/// 一个播放队列是从哪儿点开的（专辑 / 歌单 …）：随播放事件落库，驱动「最近播放的
/// 歌单 / 专辑」。[id] 是该种类下的不透明身份；插件 / 服务器来源用 `<宿主 id>/<条目 id>`
/// 编码（宿主 id 不含 `/`，条目 id 可以含），用 [hostRef] 拆回。字段全 final（插件 /
/// 服务器的命名构造要拼 id，做不成 const，所以不挂 `@immutable`）。
class MusicPlaySource {
  const MusicPlaySource({
    required this.kind,
    required this.id,
    this.title,
    this.cover,
  });

  const MusicPlaySource.album(String albumUid, {String? title, String? cover})
    : this(
        kind: MusicPlaySourceKind.album,
        id: albumUid,
        title: title,
        cover: cover,
      );

  const MusicPlaySource.playlist(
    String playlistUid, {
    String? title,
    String? cover,
  }) : this(
         kind: MusicPlaySourceKind.playlist,
         id: playlistUid,
         title: title,
         cover: cover,
       );

  MusicPlaySource.pluginAlbum(
    String pluginId,
    String albumId, {
    String? title,
    String? cover,
  }) : this(
         kind: MusicPlaySourceKind.pluginAlbum,
         id: '$pluginId/$albumId',
         title: title,
         cover: cover,
       );

  MusicPlaySource.pluginPlaylist(
    String pluginId,
    String playlistId, {
    String? title,
    String? cover,
  }) : this(
         kind: MusicPlaySourceKind.pluginPlaylist,
         id: '$pluginId/$playlistId',
         title: title,
         cover: cover,
       );

  MusicPlaySource.serverAlbum(
    String serverId,
    String albumId, {
    String? title,
    String? cover,
  }) : this(
         kind: MusicPlaySourceKind.serverAlbum,
         id: '$serverId/$albumId',
         title: title,
         cover: cover,
       );

  MusicPlaySource.serverPlaylist(
    String serverId,
    String playlistId, {
    String? title,
    String? cover,
  }) : this(
         kind: MusicPlaySourceKind.serverPlaylist,
         id: '$serverId/$playlistId',
         title: title,
         cover: cover,
       );

  final MusicPlaySourceKind kind;
  final String id;

  /// 显示名（专辑名 / 歌单名）。
  final String? title;

  /// 封面（http(s) 地址或本地文件路径）。
  final String? cover;

  /// 插件 / 服务器来源的 (宿主 id, 条目 id)；其它种类或编码不对返回 null。
  ({String hostId, String itemId})? get hostRef {
    switch (kind) {
      case MusicPlaySourceKind.pluginAlbum:
      case MusicPlaySourceKind.pluginPlaylist:
      case MusicPlaySourceKind.serverAlbum:
      case MusicPlaySourceKind.serverPlaylist:
        final int slash = id.indexOf('/');
        if (slash <= 0 || slash == id.length - 1) return null;
        return (
          hostId: id.substring(0, slash),
          itemId: id.substring(slash + 1),
        );
      case MusicPlaySourceKind.album:
      case MusicPlaySourceKind.playlist:
      case MusicPlaySourceKind.artist:
      case MusicPlaySourceKind.other:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MusicPlaySource && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// 纯函数：语境 + 是否随机 → ReplayGain 模式（设计 §7.2）。[enabled] 为 false = 关。
MusicReplayGainMode musicReplayGainModeFor({
  required bool enabled,
  required MusicQueueContext context,
  required bool shuffled,
}) {
  if (!enabled) return MusicReplayGainMode.off;
  if (context == MusicQueueContext.album && !shuffled) {
    return MusicReplayGainMode.album;
  }
  return MusicReplayGainMode.track;
}

/// 「上一首」的判据：当前曲目已播超过 [threshold] 时回到本曲开头，否则退到上一首
/// （与主流播放器一致）。返回 true = 退到上一首。
bool musicPreviousGoesBack(
  Duration position, {
  Duration threshold = const Duration(seconds: 3),
}) => position <= threshold;

/// AB 循环区间（相对当前曲目起点，`b > a`）。
@immutable
class MusicAbLoop {
  const MusicAbLoop(this.a, this.b);

  final Duration a;
  final Duration b;

  @override
  bool operator ==(Object other) =>
      other is MusicAbLoop && other.a == a && other.b == b;

  @override
  int get hashCode => Object.hash(a, b);
}

/// 连续多少首拿不到流（[MusicPlaybackFailure.trackUnavailable]）才停下并提示；不到这个数时
/// 自动跳到下一首。
const int kMusicMaxConsecutiveUnavailable = 3;

/// 构造输出后端的工厂（真 app 给 libmpv，测试给替身）。
typedef MusicOutputBackendFactory = MusicOutputBackend Function();

class MusicPlayerEngine extends ChangeNotifier {
  MusicPlayerEngine({
    required MusicOutputBackendFactory backendFactory,
    bool Function()? gaplessEnabled,
    bool Function()? replayGainEnabled,
    MusicOutputSettings Function()? baseSettings,
    Random? random,
  }) : _backendFactory = backendFactory,
       _gaplessEnabled = gaplessEnabled ?? (() => true),
       _replayGainEnabled = replayGainEnabled ?? (() => true),
       _baseSettings = baseSettings ?? (() => _kDefaultBaseSettings),
       _random = random ?? Random();

  static const MusicOutputSettings _kDefaultBaseSettings = MusicOutputSettings(
    gapless: true,
    replayGain: MusicReplayGainMode.off,
  );

  final MusicOutputBackendFactory _backendFactory;
  final bool Function() _gaplessEnabled;
  final bool Function() _replayGainEnabled;

  /// 其余输出偏好（独占 / 设备 / 音量 / 变速 / 预放大 / DSD / 交叉淡入），来自设置。
  final MusicOutputSettings Function() _baseSettings;
  final Random _random;

  MusicOutputBackend? _backend;
  StreamSubscription<MusicBackendEvent>? _eventSub;

  /// 播放顺序（随机时是打乱后的顺序）。
  List<MusicPlayItem> _queue = const <MusicPlayItem>[];

  /// 原始顺序（关随机时还原）。
  List<MusicPlayItem> _original = const <MusicPlayItem>[];
  int _index = -1;
  MusicQueueContext _context = MusicQueueContext.mixed;
  MusicPlaySource? _source;
  bool _shuffled = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  String? _lastError;
  bool _stopAfterCurrent = false;

  /// 队列（或睡眠定时）播完、后端已卸载文件。
  bool _ended = false;

  /// 打开代次：每次 [_openCurrent] / [stop] 加一。连切时晚回来的那次打开（后端在取流）
  /// 发现代次变了就丢弃结果，不改播放状态、不记播放事件。
  int _openGen = 0;

  /// 正在打开当前曲目（在线曲目取流中）。
  bool _resolving = false;

  /// 当前曲目打开失败：后端里没有它（或停在失败处），[play] / [seek] 必须重开而不是续播。
  bool _needsReopen = false;

  /// 打开期间用户按了暂停：打开完成后停在暂停（不按打开时的「播放」自动开播）。
  bool _pauseAfterOpen = false;

  /// 连续拿不到流而自动跳过的曲目数（成功出声即清零）。
  int _consecutiveUnavailable = 0;
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  MusicBackendOutputFallback? _lastOutputFallback;
  MusicAbLoop? _abLoop;

  /// 输出自动退回（独占 → 共享 / 指定设备 → 默认）时调用：界面弹明确提示。
  void Function(MusicBackendOutputFallback fallback)? onOutputFallback;

  /// 播放失败（打不开 / 音频 CD 没盘或换了盘）时调用：界面弹明确提示。拿不到流的在线曲目
  /// 先自动跳过（[onTrackSkipped]），连续 [kMusicMaxConsecutiveUnavailable] 首都这样（或
  /// 队列到底）才停下并调这里。
  void Function(MusicBackendFailed failure)? onPlaybackFailed;

  /// 一首拿不到流、已自动跳到下一首时调用（[skipped] 是被跳过的那首）：界面可轻提示。
  void Function(MusicPlayItem skipped, MusicBackendFailed failure)?
  onTrackSkipped;

  /// 每次真正开始播一首新曲（含无缝推进）时调用：播放流落库、媒体会话刷新。
  void Function(MusicPlayItem item)? onTrackStarted;

  /// 播放状态变成「在播」时调用：媒体会话仲裁（暂停有声书、认领通知）。
  VoidCallback? onWillPlay;

  List<MusicPlayItem> get queue => List<MusicPlayItem>.unmodifiable(_queue);
  int get index => _index;
  MusicPlayItem? get current =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  /// 预排给后端的下一首：单曲循环是当前曲；列表循环到队尾时接回队首。
  MusicPlayItem? get next {
    if (_index < 0 || _index >= _queue.length) return null;
    if (_repeat == MusicRepeatMode.one) return _queue[_index];
    if (_index + 1 < _queue.length) return _queue[_index + 1];
    return _repeat == MusicRepeatMode.all ? _queue.first : null;
  }

  MusicRepeatMode _repeat = MusicRepeatMode.off;
  MusicRepeatMode get repeatMode => _repeat;

  /// 切循环模式：不打断当前曲，只更新预排给后端的下一首。
  Future<void> setRepeatMode(MusicRepeatMode mode) async {
    if (mode == _repeat) return;
    _repeat = mode;
    notifyListeners();
    final MusicOutputBackend? backend = _backend;
    if (backend != null && !_ended && current != null) {
      await _sendNext(backend);
    }
  }

  bool get isPlaying => _playing;

  /// 正在打开当前曲目（在线曲目向插件取流中）：界面显示加载中。取流期间旧曲已停，
  /// [position] 停在 0。
  bool get resolving => _resolving;
  bool get isActive => current != null;
  bool get shuffled => _shuffled;

  /// 当前队列的来源（[playQueue] 传入；没传 = 不知道）。播放流按它记「最近播放的来源」。
  MusicPlaySource? get source => _source;
  Duration get position => _position;
  Duration? get duration => _duration;
  String? get lastError => _lastError;

  /// 睡眠定时：播完本曲停。
  bool get stopAfterCurrent => _stopAfterCurrent;

  /// 睡眠定时器的到点时刻（到点后播完正在放的那首停）；null = 没开。
  DateTime? get sleepDeadline => _sleepDeadline;

  /// 最近一次输出退回（面板显示原因）；用户改输出设置后清掉。
  MusicBackendOutputFallback? get lastOutputFallback => _lastOutputFallback;

  /// 当前 AB 循环（相对当前曲目起点）；null = 没开。换曲目自动关。
  MusicAbLoop? get abLoop => _abLoop;

  /// 开 / 改 AB 循环；[loop] 为 null（或区间为空）= 关。没在播时只记状态不下发。
  Future<void> setAbLoop(MusicAbLoop? loop) async {
    final MusicAbLoop? next = loop == null || loop.b <= loop.a ? null : loop;
    if (next == _abLoop) return;
    _abLoop = next;
    notifyListeners();
    await _backend?.setAbLoop(next?.a, next?.b);
  }

  /// 换曲目时关掉循环（后端的循环点跨文件保留，必须显式清）。
  void _dropAbLoopForTrackChange() {
    if (_abLoop == null) return;
    _abLoop = null;
    unawaited(_backend?.setAbLoop(null, null));
  }

  MusicOutputSettings get currentSettings => _baseSettings().copyWith(
    gapless: _gaplessEnabled(),
    replayGain: musicReplayGainModeFor(
      enabled: _replayGainEnabled(),
      context: _context,
      shuffled: _shuffled,
    ),
  );

  /// 当前 → 下一首这一处衔接是否交叉淡入（设计 §7.2）：设置开了、没有「播完本曲停」、
  /// 而且是真边界（专辑连续 / CUE 拆轨默认不淡入，见 [musicTransitionCrossfades]）。
  /// 独占等输出侧的停用由后端判（[musicCrossfadeAvailability]）。
  bool get crossfadeToNext {
    final MusicPlayItem? from = current;
    final MusicPlayItem? to = next;
    if (from == null || to == null || _stopAfterCurrent) return false;
    final MusicOutputSettings s = _baseSettings();
    if (s.crossfade <= Duration.zero) return false;
    return musicTransitionCrossfades(
      from,
      to,
      albumOrder: _context == MusicQueueContext.album && !_shuffled,
      includeContinuous: s.crossfadeContinuous,
    );
  }

  /// 最近一次发给后端的 [crossfadeToNext]（设置变了才重发「下一首」）。
  bool _sentCrossfadeNext = false;

  Future<void> _sendNext(MusicOutputBackend backend) {
    final bool crossfade = crossfadeToNext;
    _sentCrossfadeNext = crossfade;
    return backend.replaceNext(
      _stopAfterCurrent ? null : next,
      crossfadeNext: crossfade,
    );
  }

  /// 正在播放时读信号路径（面板）；没在播为 null。
  Future<MusicSignalPathSnapshot?> readSignalPath() async =>
      _backend?.readSignalPath();

  /// 可选输出设备。没在播时临时建一个后端读完即释放。
  Future<List<MusicAudioDevice>> listAudioDevices() async {
    final MusicOutputBackend? existing = _backend;
    if (existing != null) return existing.listAudioDevices();
    final MusicOutputBackend temp = _backendFactory();
    try {
      return await temp.listAudioDevices();
    } finally {
      await temp.dispose();
    }
  }

  MusicOutputBackend _ensureBackend() {
    final MusicOutputBackend? existing = _backend;
    if (existing != null) return existing;
    final MusicOutputBackend created = _backendFactory();
    _backend = created;
    _eventSub = created.events.listen(_onBackendEvent);
    return created;
  }

  /// 换一个队列，从 [startIndex] 开始播。[source] 是这个队列从哪张专辑 / 哪个歌单点开
  /// 的（最近播放用；不传 = 来源未知）。
  Future<void> playQueue(
    List<MusicPlayItem> items, {
    int startIndex = 0,
    MusicQueueContext context = MusicQueueContext.mixed,
    bool shuffle = false,
    MusicPlaySource? source,
  }) async {
    if (items.isEmpty) return;
    final int start = startIndex.clamp(0, items.length - 1);
    _original = List<MusicPlayItem>.of(items);
    _context = context;
    _source = source;
    _shuffled = shuffle;
    if (shuffle) {
      // 选中的那首排第一，其余打乱。
      final MusicPlayItem first = items[start];
      final List<MusicPlayItem> rest = List<MusicPlayItem>.of(items)
        ..removeAt(start)
        ..shuffle(_random);
      _queue = <MusicPlayItem>[first, ...rest];
      _index = 0;
    } else {
      _queue = List<MusicPlayItem>.of(items);
      _index = start;
    }
    await _openCurrent(play: true);
  }

  /// 打开 [current]。[userInitiated] = 用户点的（换队列 / 切歌 / 跳转）：连续失败计数清零；
  /// false = 拿不到流后的自动跳过。
  Future<void> _openCurrent({
    required bool play,
    bool userInitiated = true,
  }) async {
    final MusicPlayItem? item = current;
    if (item == null) return;
    final int gen = ++_openGen;
    if (userInitiated) _consecutiveUnavailable = 0;
    final MusicOutputBackend backend = _ensureBackend();
    _dropAbLoopForTrackChange();
    _position = Duration.zero;
    _duration = item.durationMs == null
        ? null
        : Duration(milliseconds: item.durationMs!);
    _lastError = null;
    _ended = false;
    _needsReopen = false;
    _pauseAfterOpen = false;
    _resolving = true;
    notifyListeners();
    if (play) onWillPlay?.call();
    try {
      await backend.applySettings(currentSettings);
      if (gen != _openGen) return;
      final bool crossfade = crossfadeToNext;
      _sentCrossfadeNext = crossfade;
      await backend.openPair(
        item,
        _stopAfterCurrent ? null : next,
        play: play,
        crossfadeNext: crossfade,
      );
    } on MusicTrackOpenException catch (e) {
      if (gen != _openGen) return;
      _resolving = false;
      _onTrackFailed(e.failure, autoSkip: play);
      return;
    } finally {
      if (gen == _openGen) _resolving = false;
    }
    // 打开期间用户又切了别的：那一次说了算，这次的结果作废（不记播放事件）。
    if (gen != _openGen) return;
    if (_needsReopen) {
      // 打开期间后端已经报了这一首失败（[_onBackendEvent] 处理过）。
      notifyListeners();
      return;
    }
    if (play) {
      onTrackStarted?.call(item);
      if (_pauseAfterOpen) {
        await backend.pause();
        if (gen != _openGen) return;
      } else {
        _playing = true;
      }
    }
    notifyListeners();
  }

  /// 当前曲目打开 / 播放失败。拿不到流（[MusicPlaybackFailure.trackUnavailable]）且是要播的：
  /// 自动跳下一首，连续 [kMusicMaxConsecutiveUnavailable] 首（或已到队尾）才停并提示。
  /// 停下后当前曲目标记为需重开，再按播放从头打开它。
  void _onTrackFailed(MusicBackendFailed failure, {required bool autoSkip}) {
    final MusicPlayItem? failed = current;
    _lastError = failure.message;
    _playing = false;
    _needsReopen = true;
    final bool skippable =
        autoSkip &&
        failed != null &&
        failure.reason == MusicPlaybackFailure.trackUnavailable &&
        !_stopAfterCurrent;
    if (skippable) {
      _consecutiveUnavailable++;
      if (_consecutiveUnavailable < kMusicMaxConsecutiveUnavailable &&
          _index + 1 < _queue.length) {
        onTrackSkipped?.call(failed, failure);
        _index++;
        unawaited(_openCurrent(play: true, userInitiated: false));
        return;
      }
    }
    _consecutiveUnavailable = 0;
    onPlaybackFailed?.call(failure);
    notifyListeners();
  }

  Future<void> togglePlayPause() => _playing ? pause() : play();

  Future<void> play() async {
    final MusicOutputBackend? backend = _backend;
    if (backend == null || current == null) return;
    // 正在打开：打开完成后本来就会播（或按失败处理），只撤销打开期间按的暂停。
    if (_resolving) {
      _pauseAfterOpen = false;
      return;
    }
    if (_ended || _needsReopen) {
      // 队列播完后后端已卸载文件、交还设备；或这一首打开 / 播放失败、后端里没有它：
      // 从当前曲目开头重开（在线曲目随之重新取流）。
      await _openCurrent(play: true);
      return;
    }
    onWillPlay?.call();
    await backend.play();
    _playing = true;
    notifyListeners();
  }

  Future<void> pause() async {
    final MusicOutputBackend? backend = _backend;
    if (backend == null) return;
    if (_resolving) {
      // 取流还没回来、后端里没有可暂停的：记下，打开完成后停在暂停。
      _pauseAfterOpen = true;
      _playing = false;
      notifyListeners();
      return;
    }
    await backend.pause();
    _playing = false;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    final MusicOutputBackend? backend = _backend;
    if (backend == null || current == null) return;
    final Duration clamped = position < Duration.zero
        ? Duration.zero
        : (_duration != null && position > _duration! ? _duration! : position);
    if (_resolving) return;
    if (_ended || _needsReopen) {
      await _openCurrent(play: false);
      // 重开又失败了（或被别的打开顶掉）：没有可跳的文件。
      if (_needsReopen || _resolving) return;
    }
    await backend.seek(clamped);
    _position = clamped;
    notifyListeners();
  }

  Future<void> seekRelative(Duration delta) => seek(_position + delta);

  /// 播完本曲停（再调一次取消）。
  Future<void> setStopAfterCurrent(bool value) async {
    if (_stopAfterCurrent == value) return;
    _stopAfterCurrent = value;
    if (!value) {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      _sleepDeadline = null;
    }
    notifyListeners();
    // 后端不再预排下一首，当前曲目播完即 Completed；取消时把下一首补回去。
    final MusicOutputBackend? backend = _backend;
    if (backend != null) await _sendNext(backend);
  }

  /// 睡眠定时：[after] 之后播完当时正在放的那首停；null 取消。
  void setSleepTimer(Duration? after) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    if (after == null) {
      unawaited(setStopAfterCurrent(false));
      return;
    }
    _sleepDeadline = DateTime.now().add(after);
    _sleepTimer = Timer(after, () {
      _sleepTimer = null;
      unawaited(setStopAfterCurrent(true));
    });
    notifyListeners();
  }

  Future<void> skipNext() async {
    if (_index + 1 >= _queue.length) {
      // 列表 / 单曲循环下，队尾「下一首」接回队首（单曲循环只管自然播完）。
      if (_repeat == MusicRepeatMode.off || _queue.isEmpty) return;
      _index = 0;
      await _openCurrent(play: true);
      return;
    }
    _index++;
    await _openCurrent(play: true);
  }

  Future<void> skipPrevious() async {
    if (current == null) return;
    if (!musicPreviousGoesBack(_position) || _index == 0) {
      await seek(Duration.zero);
      return;
    }
    _index--;
    await _openCurrent(play: true);
  }

  /// 跳到队列第 [i] 首。
  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    await _openCurrent(play: true);
  }

  /// 开 / 关随机：保持当前曲目不变、不中断，只重排它之后的队列并更新预排的下一首。
  Future<void> setShuffle(bool shuffle) async {
    if (shuffle == _shuffled) return;
    final MusicPlayItem? playing = current;
    _shuffled = shuffle;
    if (playing == null) {
      notifyListeners();
      return;
    }
    if (shuffle) {
      final List<MusicPlayItem> rest = List<MusicPlayItem>.of(_original)
        ..remove(playing)
        ..shuffle(_random);
      _queue = <MusicPlayItem>[playing, ...rest];
      _index = 0;
    } else {
      _queue = List<MusicPlayItem>.of(_original);
      _index = _queue.indexOf(playing);
    }
    final MusicOutputBackend? backend = _backend;
    if (backend != null) {
      await backend.applySettings(currentSettings);
      await _sendNext(backend);
    }
    notifyListeners();
  }

  /// 停止并清空队列（释放后端：音乐不在播时不占一个 mpv 实例）。
  Future<void> stop() async {
    final MusicOutputBackend? backend = _backend;
    _backend = null;
    _openGen++;
    _resolving = false;
    _needsReopen = false;
    _consecutiveUnavailable = 0;
    await _eventSub?.cancel();
    _eventSub = null;
    _queue = const <MusicPlayItem>[];
    _original = const <MusicPlayItem>[];
    _index = -1;
    _source = null;
    _playing = false;
    _position = Duration.zero;
    _duration = null;
    _stopAfterCurrent = false;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    _abLoop = null;
    notifyListeners();
    if (backend != null) {
      await backend.stop();
      await backend.dispose();
    }
  }

  /// 输出设置变了（设置页切无缝 / ReplayGain）：立刻下发给在用的后端。
  Future<void> reapplySettings() async {
    _lastOutputFallback = null;
    final MusicOutputBackend? backend = _backend;
    if (backend != null) {
      await backend.applySettings(currentSettings);
      // 交叉淡入开关 / 「连续曲目也淡入」变了：这一处衔接的方式跟着变（还来得及的话）。
      if (!_ended && current != null && crossfadeToNext != _sentCrossfadeNext) {
        await _sendNext(backend);
      }
    }
    notifyListeners();
  }

  void _onBackendEvent(MusicBackendEvent event) {
    // 打开期间（取流中）后端报的位置 / 播放态 / 推进 / 播完都属于被换掉的旧曲。
    if (_resolving && event is! MusicBackendOutputFallback) {
      if (event is MusicBackendFailed) _onFailedEvent(event);
      return;
    }
    switch (event) {
      case MusicBackendPosition(
        :final Duration position,
        :final Duration? duration,
      ):
        // 真出声了：这一首拿到了流。
        if (position > Duration.zero) _consecutiveUnavailable = 0;
        _position = position;
        if (duration != null && duration > Duration.zero) _duration = duration;
        notifyListeners();
      case MusicBackendPlaying(:final bool playing):
        if (_playing == playing) return;
        _playing = playing;
        notifyListeners();
      case MusicBackendAdvanced(:final String? trackUid):
        // 后端已经无缝切到我们预排的下一首（以实际出声为准）：推进队列、补新的下一首。
        // 后端报了曲目就按曲目对位（切换期内队列可能被重排过）。
        final int found = trackUid == null
            ? -1
            : _queue.indexWhere((MusicPlayItem i) => i.trackUid == trackUid);
        if (found >= 0) {
          _index = found;
        } else if (_index + 1 < _queue.length) {
          _index++;
        } else if (_repeat == MusicRepeatMode.all && _queue.isNotEmpty) {
          _index = 0;
        }
        final MusicPlayItem? item = current;
        _dropAbLoopForTrackChange();
        _needsReopen = false;
        _lastError = null;
        _position = Duration.zero;
        _duration = item?.durationMs == null
            ? null
            : Duration(milliseconds: item!.durationMs!);
        if (item != null) onTrackStarted?.call(item);
        notifyListeners();
        final MusicOutputBackend? backend = _backend;
        if (backend != null) unawaited(_sendNext(backend));
      case MusicBackendCompleted():
        // 后端播完即卸载文件、交还设备（独占不再占着）；再按播放由 [play] 重开。
        _playing = false;
        _ended = true;
        if (_stopAfterCurrent) {
          // 睡眠定时到点：指到下一首开头，用户再按播放从下一首接着听。
          _stopAfterCurrent = false;
          _sleepDeadline = null;
          if (_index + 1 < _queue.length) {
            _index++;
            final MusicPlayItem? item = current;
            _position = Duration.zero;
            _duration = item?.durationMs == null
                ? null
                : Duration(milliseconds: item!.durationMs!);
          }
        }
        notifyListeners();
      case MusicBackendOutputFallback():
        _lastOutputFallback = event;
        onOutputFallback?.call(event);
        notifyListeners();
      case MusicBackendFailed():
        _onFailedEvent(event);
    }
  }

  /// 后端异步报的失败（打开之后才发现：流地址打不开、预排的下一首取不到流 …），按曲目对位：
  /// * 是当前曲目（或后端没说是哪首）：当前曲目失败；
  /// * 是预排的下一首（当前曲放完时后端才去取它的流）：推进到它（不算开始播放，不记播放
  ///   事件），再按它失败处理；
  /// * 都不是：用户已经切走了，过期事件，丢弃。
  /// 打开期间（[_resolving]）只认后端明说是当前曲目的失败。
  void _onFailedEvent(MusicBackendFailed event) {
    final String? uid = event.trackUid;
    final MusicPlayItem? cur = current;
    // 只在本来要出声时自动跳过：暂停着的曲目失败了就停在那里。
    final bool wanted = _playing || _resolving;
    if (uid == null || uid == cur?.trackUid) {
      if (_resolving && uid == null) return;
      _resolving = false;
      _onTrackFailed(event, autoSkip: wanted);
      return;
    }
    if (!_resolving && uid == next?.trackUid) {
      _index++;
      _dropAbLoopForTrackChange();
      _position = Duration.zero;
      final MusicPlayItem? item = current;
      _duration = item?.durationMs == null
          ? null
          : Duration(milliseconds: item!.durationMs!);
      _onTrackFailed(event, autoSkip: wanted);
    }
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    final MusicOutputBackend? backend = _backend;
    _backend = null;
    unawaited(_eventSub?.cancel());
    if (backend != null) unawaited(backend.dispose());
    super.dispose();
  }
}
