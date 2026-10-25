/// 歌词学习闭环的纯函数（设计 §12）：一行歌词 → 曲目时间窗（制卡出处 / 音频片段 / AB
/// 循环）。三套时间坐标别混：
/// - **歌词时间**：时间轴里写的毫秒，显示时间 = 播放位置 + 整首偏移；
/// - **曲目时间**：`MusicPlayerEngine.position` 的坐标（CUE 虚拟曲目从段首 0 起），出处
///   链接、制卡历史的 `position_ms`、AB 循环都用它；
/// - **文件时间**：音频文件里的毫秒（= 曲目时间 + CUE 段首），截音频片段用它。
library;

import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_progress.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';

/// 制卡音频片段前后各扩这么多（设计 §12「可前后扩 0.5 s」）。
const int kMusicLyricClipPaddingMs = 500;

/// 一行歌词在曲目时间轴上的窗口。
class MusicLyricLineWindow {
  const MusicLyricLineWindow({
    required this.lineIndex,
    required this.text,
    required this.startMs,
    required this.endMs,
    this.translation,
  });

  /// [LyricTimeline.lines] 下标。
  final int lineIndex;
  final String text;

  /// 曲目时间（毫秒，≥ 0，`endMs >= startMs`）。
  final int startMs;
  final int endMs;

  /// 第一条翻译（释义备选）。
  final String? translation;

  int get durationMs => endMs - startMs;

  /// 截音频片段的文件时间区间（前后各扩 [paddingMs]，起点夹 0、终点夹曲长）。
  ({int startMs, int endMs}) clipInFile({
    int fileOffsetMs = 0,
    int? trackDurationMs,
    int paddingMs = kMusicLyricClipPaddingMs,
  }) {
    final int s = (startMs - paddingMs).clamp(0, startMs);
    int e = endMs + paddingMs;
    if (trackDurationMs != null && trackDurationMs > 0 && e > trackDurationMs) {
      e = trackDurationMs < endMs ? endMs : trackDurationMs;
    }
    return (startMs: s + fileOffsetMs, endMs: e + fileOffsetMs);
  }
}

/// 歌词时间 → 曲目时间（减回整首偏移，夹 0）。
int musicLyricToTrackMs(int lyricMs, {required int offsetMs}) {
  final int t = lyricMs - offsetMs;
  return t < 0 ? 0 : t;
}

/// 第 [lineIndex] 行的曲目时间窗。行没有可用终点（LRC 最后一行 / 无结束时刻）时用下一
/// 主行起点，再不行用 [trackDurationMs]，都没有就零长。无时间歌词或下标越界返回 null。
MusicLyricLineWindow? musicLyricLineWindow(
  LyricTimeline t,
  int lineIndex, {
  int? trackDurationMs,
}) {
  if (!t.isSynced || lineIndex < 0 || lineIndex >= t.lines.length) {
    return null;
  }
  final LyricLine l = t.lines[lineIndex];
  int endLyric = l.endMs;
  if (endLyric <= l.startMs) {
    for (int i = lineIndex + 1; i < t.lines.length; i++) {
      if (!t.lines[i].isBackground && t.lines[i].startMs > l.startMs) {
        endLyric = t.lines[i].startMs;
        break;
      }
    }
  }
  final int start = musicLyricToTrackMs(l.startMs, offsetMs: t.offsetMs);
  int end = endLyric > l.startMs
      ? musicLyricToTrackMs(endLyric, offsetMs: t.offsetMs)
      : (trackDurationMs ?? start);
  if (end < start) end = start;
  return MusicLyricLineWindow(
    lineIndex: lineIndex,
    text: l.text.trim(),
    startMs: start,
    endMs: end,
    translation: l.primaryTranslation,
  );
}

/// 当前（播放位置下）主行下标；没有当前行（还没开始 / 无时间）为 -1。
int musicLyricCurrentLine(LyricTimeline t, int positionMs) {
  final List<KaraokeRowSpan> rows = karaokeRows(t);
  final int row = karaokeCurrentRow(
    timeline: t,
    rows: rows,
    positionMs: positionMs,
    offsetMs: t.offsetMs,
  );
  return row < 0 ? -1 : rows[row].main;
}

/// AB 循环覆盖 [firstLine]..[lastLine]（含）这几行。行号顺序无所谓；拿不到窗口或区间
/// 为空返回 null。
MusicAbLoop? musicAbLoopForLines(
  LyricTimeline t,
  int firstLine,
  int lastLine, {
  int? trackDurationMs,
}) {
  final int lo = firstLine < lastLine ? firstLine : lastLine;
  final int hi = firstLine < lastLine ? lastLine : firstLine;
  final MusicLyricLineWindow? a = musicLyricLineWindow(
    t,
    lo,
    trackDurationMs: trackDurationMs,
  );
  final MusicLyricLineWindow? b = musicLyricLineWindow(
    t,
    hi,
    trackDurationMs: trackDurationMs,
  );
  if (a == null || b == null || b.endMs <= a.startMs) return null;
  return MusicAbLoop(
    Duration(milliseconds: a.startMs),
    Duration(milliseconds: b.endMs),
  );
}

/// 下一主行（AB 循环「再加一行」）；没有返回 -1。
int musicLyricNextMainLine(LyricTimeline t, int lineIndex) {
  for (int i = lineIndex + 1; i < t.lines.length; i++) {
    if (!t.lines[i].isBackground && t.lines[i].text.trim().isNotEmpty) {
      return i;
    }
  }
  return -1;
}
