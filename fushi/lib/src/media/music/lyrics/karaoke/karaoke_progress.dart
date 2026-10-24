/// 逐字歌词的时间换算（纯函数，可单测）：生效时间、音节擦色进度、当前行判定。
///
/// 时间语义：显示时间 = 播放位置 + 整首偏移（正 = 歌词提前，与 LRC `[offset:]`
/// 与 `music_lyrics.offset_ms` 同号）。
library;

import 'dart:math' as math;

import 'package:fushi_music/fushi_music.dart';

/// 播放位置 [positionMs] 下的歌词显示时间。
int karaokeLineTimeMs({required int positionMs, required int offsetMs}) =>
    positionMs + offsetMs;

/// 点 [line] 要跳到的播放位置：让该行起点恰好落在显示时间上。
int karaokeSeekPositionForLine({
  required LyricLine line,
  required int offsetMs,
}) {
  final int p = line.startMs - offsetMs;
  return p < 0 ? 0 : p;
}

/// 音节擦色进度（0–1），语义对齐 libass（`ass_render.c` 的 `process_karaoke_effects`，
/// 真 libmpv 截帧验证见 `music_karaoke_stage_real_test.dart`）：
/// - [LyricFill.instant]（`\k`）：音节**起点**整字变色，0 或 1；
/// - [LyricFill.outline]（`\ko`）：同样在起点瞬间切换（不是擦色），且描边起点之前不画、
///   起点之后出现（描边由画家处理）；
/// - [LyricFill.sweep]（`\kf` / `\K`）：起止之间线性擦色。
double karaokeSyllableProgress(LyricSyllable s, int timeMs) {
  if (timeMs < s.startMs) return 0;
  if (timeMs >= s.endMs) return 1;
  if (s.fill != LyricFill.sweep) return 1;
  final int d = s.endMs - s.startMs;
  if (d <= 0) return 1;
  return (timeMs - s.startMs) / d;
}

/// 行级歌词（只有行时间）的整行线性擦色估计；[sweep] = false 时到点整行高亮。
double karaokeLineLevelProgress(
  LyricLine line,
  int timeMs, {
  bool sweep = true,
}) {
  if (timeMs < line.startMs) return 0;
  if (timeMs >= line.endMs) return 1;
  if (!sweep) return 1;
  final int d = line.endMs - line.startMs;
  return d <= 0 ? 1 : (timeMs - line.startMs) / d;
}

/// 「长音呼吸」：时长超过 [kKaraokeLongSyllableMs] 的音节在唱的过程中轻微放大再回落。
/// 返回放大倍数（1 = 不放大）。
const int kKaraokeLongSyllableMs = 1000;
const double kKaraokeBreathScale = 0.06;

double karaokeBreathScale(LyricSyllable s, double progress) {
  if (s.durationMs <= kKaraokeLongSyllableMs ||
      progress <= 0 ||
      progress >= 1) {
    return 1;
  }
  // 0 → 峰值 → 0 的半正弦，峰值在中段。
  return 1 + kKaraokeBreathScale * math.sin(progress * math.pi);
}

/// 当前音节的上浮量（0–1，乘以外观里的上浮像素）：起唱快速升起、唱完回落。
double karaokeLift(double progress) {
  if (progress <= 0 || progress >= 1) return 0;
  const double rise = 0.15;
  if (progress < rise) return progress / rise;
  return 1;
}

/// 一组行（主行 + 紧跟的和声行）。
class KaraokeRowSpan {
  const KaraokeRowSpan({required this.main, required this.backgrounds});

  /// 主行下标（时间轴里第一条就是和声行时，它自成一组、当主行用）。
  final int main;
  final List<int> backgrounds;

  Iterable<int> get all sync* {
    yield main;
    yield* backgrounds;
  }
}

/// 把时间轴切成显示行组：和声行挂到前一主行下。
List<KaraokeRowSpan> karaokeRows(LyricTimeline t) {
  final List<KaraokeRowSpan> out = <KaraokeRowSpan>[];
  for (int i = 0; i < t.lines.length; i++) {
    if (t.lines[i].isBackground && out.isNotEmpty) {
      final KaraokeRowSpan prev = out.removeLast();
      out.add(
        KaraokeRowSpan(
          main: prev.main,
          backgrounds: <int>[...prev.backgrounds, i],
        ),
      );
    } else {
      out.add(KaraokeRowSpan(main: i, backgrounds: const <int>[]));
    }
  }
  return out;
}

/// 当前行组：起点已到（按各自显示时间）的最后一组；全都没到为 -1。
/// 间奏里保持上一组（居中不乱跳），是否「正在唱」另由 [karaokeRowIsSinging] 判。
int karaokeCurrentRow({
  required LyricTimeline timeline,
  required List<KaraokeRowSpan> rows,
  required int positionMs,
  required int offsetMs,
}) {
  if (!timeline.isSynced) return -1;
  int current = -1;
  // 行按起点有序：二分找最后一个起点 <= 显示时间的组。
  int lo = 0;
  int hi = rows.length - 1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    final int li = rows[mid].main;
    final int t = karaokeLineTimeMs(positionMs: positionMs, offsetMs: offsetMs);
    if (timeline.lines[li].startMs <= t) {
      current = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return current;
}

/// 组里是否有一行正处于起止之间。
bool karaokeRowIsSinging({
  required LyricTimeline timeline,
  required KaraokeRowSpan row,
  required int positionMs,
  required int offsetMs,
}) {
  for (final int li in row.all) {
    final LyricLine l = timeline.lines[li];
    final int t = karaokeLineTimeMs(positionMs: positionMs, offsetMs: offsetMs);
    if (t >= l.startMs && t < l.endMs) return true;
  }
  return false;
}
