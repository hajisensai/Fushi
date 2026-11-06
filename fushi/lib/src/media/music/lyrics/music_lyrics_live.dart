/// 歌词页之外的「当前行」（设计 §6.2）：桌面歌词（Android 悬浮窗 / Windows 置顶穿透窗，
/// 复用有声书的 `FloatingLyricChannel`）与锁屏 / 媒体通知副标题。
///
/// - 只在用户开了其中一项时才解析歌词（与歌词页同一个 [MusicLyricsService.resolve]）；
/// - 当前行按引擎位置事件判（约 10 Hz，行切换不需要更细）；
/// - 桌面窗口里的逐字推进按**音节边界**下发一次高亮（定时器排到下一个边界，不逐帧过
///   平台通道）：原生窗口只认「区间高亮」，没有逐帧渐变——这是复用现有原生窗口的取舍；
/// - 有声书持有媒体会话（它在出声）时让出窗口，音乐重新认领时再拿回来。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/lyrics/music_lyrics_clock.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_learning.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';

/// 桌面歌词窗口（真 app = `FloatingLyricChannel`；测试注入替身）。
abstract interface class MusicDesktopLyricsSurface {
  /// 平台有没有原生窗口（macOS / Linux / iOS 没有）。
  bool get isSupported;

  /// 拉起窗口；false = 没权限 / 建不出来。
  Future<bool> show();
  Future<void> hide();

  /// 推一块文本（当前行居中，前后若干行），[currentStart] / [currentLength] 是当前行在块内的
  /// UTF-16 区间（-1 = 没有当前行）。
  Future<void> showBlock(String text, int currentStart, int currentLength);

  /// 高亮块内 [start, start+length)（已唱部分）；length 0 = 清掉。
  Future<void> highlight(int start, int length);
  Future<void> setPlaying(bool playing);
}

/// 桌面窗口里显示的一块：当前行居中，前后各几行（行数跟悬浮字幕「同时显示句数」）。
@immutable
class MusicDesktopLyricsBlock {
  const MusicDesktopLyricsBlock({
    required this.text,
    required this.currentStart,
    required this.currentLength,
  });

  final String text;
  final int currentStart;
  final int currentLength;

  @override
  bool operator ==(Object other) =>
      other is MusicDesktopLyricsBlock &&
      other.text == text &&
      other.currentStart == currentStart &&
      other.currentLength == currentLength;

  @override
  int get hashCode => Object.hash(text, currentStart, currentLength);
}

/// 纯函数：当前主行 [line]（-1 = 前奏）→ 窗口文本块，当前行前取 [before] 个主行、
/// 后取 [after] 个主行（伴唱 / 空行不占名额）。前奏里以第一行为锚、当前行区间 -1
/// （整块按「未唱」显示）；靠近开头 / 结尾时那一侧有多少给多少。
MusicDesktopLyricsBlock musicDesktopLyricsBlock(
  LyricTimeline t,
  int line, {
  int before = 0,
  int after = 1,
}) {
  int anchor = line;
  bool hasCurrent = line >= 0;
  if (anchor < 0) {
    anchor = musicLyricNextMainLine(t, -1);
    hasCurrent = false;
  }
  if (anchor < 0 || anchor >= t.lines.length) {
    return const MusicDesktopLyricsBlock(
      text: '',
      currentStart: -1,
      currentLength: 0,
    );
  }
  final List<int> above = <int>[];
  for (int i = anchor; above.length < before;) {
    i = musicLyricPreviousMainLine(t, i);
    if (i < 0) break;
    above.insert(0, i);
  }
  final List<int> below = <int>[];
  for (int i = anchor; below.length < after;) {
    i = musicLyricNextMainLine(t, i);
    if (i < 0) break;
    below.add(i);
  }
  final StringBuffer buffer = StringBuffer();
  for (final int i in above) {
    buffer
      ..write(t.lines[i].text.trim())
      ..write('\n');
  }
  final int currentStart = buffer.length;
  final String cur = t.lines[anchor].text.trim();
  buffer.write(cur);
  for (final int i in below) {
    buffer
      ..write('\n')
      ..write(t.lines[i].text.trim());
  }
  return MusicDesktopLyricsBlock(
    text: buffer.toString(),
    currentStart: hasCurrent ? currentStart : -1,
    currentLength: hasCurrent ? cur.length : 0,
  );
}

/// 纯函数：第 [line] 行在显示时间 [lyricMs] 已唱完的 UTF-16 字符数（按音节，唱到的
/// 音节整个算唱过——原生窗口只有区间高亮）。行首空白与块内 `trim` 对齐。
int musicDesktopSungLength(LyricLine line, int lyricMs) {
  final String raw = line.text;
  final int lead = raw.length - raw.trimLeft().length;
  int at = 0;
  int sung = 0;
  for (final LyricSyllable s in line.syllables) {
    at += s.text.length;
    if (lyricMs >= s.startMs) sung = at;
  }
  final int trimmed = raw.trim().length;
  return (sung - lead).clamp(0, trimmed);
}

/// 纯函数：第 [line] 行在 [lyricMs] 之后的下一个音节起点（显示时间）；没有为 null。
int? musicNextSyllableBoundary(LyricLine line, int lyricMs) {
  for (final LyricSyllable s in line.syllables) {
    if (s.startMs > lyricMs) return s.startMs;
  }
  return null;
}

class MusicLyricsLive extends ChangeNotifier {
  MusicLyricsLive({
    required MusicPlayerEngine engine,
    required MusicLyricsService service,
    required MusicDesktopLyricsSurface desktop,
    required bool Function() desktopEnabled,
    required ({int before, int after}) Function() desktopSpan,
    required bool Function() mediaSessionEnabled,
    required Listenable sessionOwnerChanged,
    required bool Function() musicOwnsSession,
    VoidCallback? onDesktopReleased,
  }) : _engine = engine,
       _service = service,
       _desktop = desktop,
       _desktopEnabled = desktopEnabled,
       _desktopSpan = desktopSpan,
       _mediaSessionEnabled = mediaSessionEnabled,
       _ownerChanged = sessionOwnerChanged,
       _owns = musicOwnsSession,
       _onDesktopReleased = onDesktopReleased {
    _engine.addListener(_onEngine);
    _ownerChanged.addListener(_onEngine);
    _generatedSub = _service.generatedUpdates.listen((String uid) {
      if (uid == _uid) unawaited(reload());
    });
  }

  /// 生成字幕写进当前曲目时重新解析（[MusicLyricsService.generatedUpdates]）。
  late final StreamSubscription<String> _generatedSub;

  final MusicPlayerEngine _engine;
  final MusicLyricsService _service;
  final MusicDesktopLyricsSurface _desktop;
  final bool Function() _desktopEnabled;

  /// 桌面窗口里当前行前后各显示几个主行（悬浮字幕「同时显示句数」，与有声书同口径）。
  final ({int before, int after}) Function() _desktopSpan;
  final bool Function() _mediaSessionEnabled;
  final Listenable _ownerChanged;
  final bool Function() _owns;
  final VoidCallback? _onDesktopReleased;

  String? _uid;
  int _generation = 0;
  LyricTimeline? _timeline;
  int _line = -1;
  bool _desktopShown = false;
  bool _showing = false;
  MusicDesktopLyricsBlock? _pushedBlock;
  int _pushedSung = -1;
  bool? _pushedPlaying;
  Timer? _syllableTimer;
  MusicLyricsClock? _clock;

  /// 当前曲目的生效歌词（含整首偏移）；没解析 / 没有为 null。
  LyricTimeline? get timeline => _timeline;

  /// 当前主行文本（锁屏副标题用）；前奏 / 无歌词 / 无时间为 null。
  String? get currentLineText {
    final LyricTimeline? t = _timeline;
    if (t == null || !t.isSynced || _line < 0 || _line >= t.lines.length) {
      return null;
    }
    final String s = t.lines[_line].text.trim();
    return s.isEmpty ? null : s;
  }

  /// 下一行歌词（Live Activity / 菜单栏播放条的第二行）；当前是最后一行或没有时间轴为 null。
  String? get nextLineText {
    final LyricTimeline? t = _timeline;
    if (t == null || !t.isSynced) return null;
    for (int i = _line + 1; i < t.lines.length; i++) {
      final String s = t.lines[i].text.trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  /// iOS Live Activity / macOS 菜单栏播放条要当前行：与桌面歌词、媒体会话歌词并列的第三个
  /// 使用方（`HomeWidgetLiveActivities`）。只有用得上时才解析歌词、跟行。
  bool _liveActivityWanted = false;

  void setLiveActivityWanted(bool value) {
    if (_liveActivityWanted == value) return;
    _liveActivityWanted = value;
    _onEngine();
  }

  /// 锁屏 / 媒体通知该显示的当前行（设置关着为 null）。
  String? get mediaSessionLine =>
      _mediaSessionEnabled() ? currentLineText : null;

  bool get desktopShown => _desktopShown;

  bool get _wanted =>
      _desktopEnabled() || _mediaSessionEnabled() || _liveActivityWanted;

  /// 歌词页换了来源 / 调了偏移：重新解析当前曲目。
  Future<void> reload() async {
    _uid = null;
    _onEngine();
  }

  /// 设置开关变了。
  void onSettingsChanged() => _onEngine();

  void _onEngine() {
    final MusicPlayItem? item = _engine.current;
    if (!_wanted || item == null) {
      _clear();
      unawaited(_syncDesktop());
      return;
    }
    if (item.trackUid != _uid) {
      _uid = item.trackUid;
      _timeline = null;
      _line = -1;
      unawaited(_resolve(item, ++_generation));
    }
    _updateLine();
    unawaited(_syncDesktop());
  }

  Future<void> _resolve(MusicPlayItem item, int generation) async {
    LyricTimeline? t;
    try {
      t = (await _service.resolve(
        MusicLyricsTrackRef(
          trackUid: item.trackUid,
          path: item.path,
          title: item.title,
          artist: item.artist,
          album: item.album,
          durationMs: item.durationMs,
          cueStartMs: item.startMs,
        ),
      ))?.timeline;
    } on Object catch (e) {
      // 在线查询失败：歌词页会显示原因；这里只是没有当前行可显示。
      debugPrint('[music] live lyrics resolve failed: $e');
    }
    if (generation != _generation) return;
    _timeline = t;
    _line = -1;
    _updateLine(force: true);
    unawaited(_syncDesktop());
  }

  void _updateLine({bool force = false}) {
    final LyricTimeline? t = _timeline;
    final int line = t == null || !t.isSynced
        ? -1
        : musicLyricCurrentLine(t, _engine.position.inMilliseconds);
    if (line == _line && !force) return;
    _line = line;
    notifyListeners();
  }

  void _clear() {
    _generation++;
    _uid = null;
    final bool had = _timeline != null || _line != -1;
    _timeline = null;
    _line = -1;
    if (had) notifyListeners();
  }

  Future<void> _syncDesktop() async {
    final bool want =
        _desktopEnabled() &&
        _desktop.isSupported &&
        _engine.isActive &&
        _owns() &&
        _timeline != null;
    if (want && !_desktopShown && !_showing) {
      _showing = true;
      final bool ok = await _desktop.show();
      _showing = false;
      _desktopShown = ok;
      _pushedBlock = null;
      _pushedSung = -1;
      _pushedPlaying = null;
      if (ok) notifyListeners();
    } else if (!want && _desktopShown) {
      _desktopShown = false;
      _stopSyllableTimer();
      await _desktop.hide();
      notifyListeners();
      _onDesktopReleased?.call();
      return;
    }
    if (!_desktopShown) return;
    await _pushDesktop();
  }

  Future<void> _pushDesktop() async {
    final LyricTimeline? t = _timeline;
    if (t == null) return;
    final ({int before, int after}) span = _desktopSpan();
    final MusicDesktopLyricsBlock block = musicDesktopLyricsBlock(
      t,
      _line,
      before: span.before,
      after: span.after,
    );
    if (block != _pushedBlock) {
      _pushedBlock = block;
      _pushedSung = -1;
      await _desktop.showBlock(
        block.text,
        block.currentStart,
        block.currentLength,
      );
    }
    final bool playing = _engine.isPlaying;
    if (playing != _pushedPlaying) {
      _pushedPlaying = playing;
      await _desktop.setPlaying(playing);
    }
    await _pushSung();
  }

  Future<void> _pushSung() async {
    _stopSyllableTimer();
    final LyricTimeline? t = _timeline;
    if (t == null || _line < 0 || !t.timingQuality.isPerSyllable) return;
    final LyricLine line = t.lines[_line];
    final MusicLyricsClock clock = _clock ??= MusicLyricsClock(_engine);
    final int lyricMs = clock.position.inMilliseconds + t.offsetMs;
    final int sung = musicDesktopSungLength(line, lyricMs);
    if (sung != _pushedSung) {
      _pushedSung = sung;
      // 区间是块内偏移：当前行前面可能还有上文行。
      final int start = _pushedBlock?.currentStart ?? 0;
      await _desktop.highlight(start < 0 ? 0 : start, sung);
    }
    if (!_engine.isPlaying) return;
    final int? next = musicNextSyllableBoundary(line, lyricMs);
    if (next == null) return;
    final double speed = _engine.currentSettings.speed <= 0
        ? 1
        : _engine.currentSettings.speed;
    _syllableTimer = Timer(
      Duration(milliseconds: ((next - lyricMs) / speed).ceil().clamp(1, 60000)),
      () => unawaited(_pushSung()),
    );
  }

  void _stopSyllableTimer() {
    _syllableTimer?.cancel();
    _syllableTimer = null;
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngine);
    _ownerChanged.removeListener(_onEngine);
    unawaited(_generatedSub.cancel());
    _stopSyllableTimer();
    _clock?.dispose();
    if (_desktopShown) unawaited(_desktop.hide());
    super.dispose();
  }
}
