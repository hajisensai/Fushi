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

  /// 推一块文本（当前行 + 下一行），[currentStart] / [currentLength] 是当前行在块内的
  /// UTF-16 区间（-1 = 没有当前行）。
  Future<void> showBlock(String text, int currentStart, int currentLength);

  /// 高亮块内 [start, start+length)（已唱部分）；length 0 = 清掉。
  Future<void> highlight(int start, int length);
  Future<void> setPlaying(bool playing);
}

/// 桌面窗口里显示的一块：当前行 + 下一行（双行模式）。
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

/// 纯函数：当前主行 [line]（-1 = 前奏）→ 窗口文本块。前奏里显示第一行（当前行区间
/// -1，整块按「未唱」显示）；最后一行之后只剩它自己。
MusicDesktopLyricsBlock musicDesktopLyricsBlock(LyricTimeline t, int line) {
  int first = line;
  bool hasCurrent = line >= 0;
  if (first < 0) {
    first = musicLyricNextMainLine(t, -1);
    hasCurrent = false;
  }
  if (first < 0 || first >= t.lines.length) {
    return const MusicDesktopLyricsBlock(
      text: '',
      currentStart: -1,
      currentLength: 0,
    );
  }
  final String cur = t.lines[first].text.trim();
  final int next = musicLyricNextMainLine(t, first);
  final String text = next < 0 ? cur : '$cur\n${t.lines[next].text.trim()}';
  return MusicDesktopLyricsBlock(
    text: text,
    currentStart: hasCurrent ? 0 : -1,
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
    required bool Function() mediaSessionEnabled,
    required Listenable sessionOwnerChanged,
    required bool Function() musicOwnsSession,
    VoidCallback? onDesktopReleased,
  }) : _engine = engine,
       _service = service,
       _desktop = desktop,
       _desktopEnabled = desktopEnabled,
       _mediaSessionEnabled = mediaSessionEnabled,
       _ownerChanged = sessionOwnerChanged,
       _owns = musicOwnsSession,
       _onDesktopReleased = onDesktopReleased {
    _engine.addListener(_onEngine);
    _ownerChanged.addListener(_onEngine);
  }

  final MusicPlayerEngine _engine;
  final MusicLyricsService _service;
  final MusicDesktopLyricsSurface _desktop;
  final bool Function() _desktopEnabled;
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

  /// 锁屏 / 媒体通知该显示的当前行（设置关着为 null）。
  String? get mediaSessionLine =>
      _mediaSessionEnabled() ? currentLineText : null;

  bool get desktopShown => _desktopShown;

  bool get _wanted => _desktopEnabled() || _mediaSessionEnabled();

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
    final MusicDesktopLyricsBlock block = musicDesktopLyricsBlock(t, _line);
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
      await _desktop.highlight(0, sung);
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
    _stopSyllableTimer();
    _clock?.dispose();
    if (_desktopShown) unawaited(_desktop.hide());
    super.dispose();
  }
}
