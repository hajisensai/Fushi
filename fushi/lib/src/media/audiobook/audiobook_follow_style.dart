import 'dart:math' as math;

import 'package:fushi_audio/fushi_audio.dart';

/// 有声书「跟随音频」在分页 / 连续两种正文模式下的跟读方式（反馈 tUJsiLpL9d，
/// GitHub #3300，所有者 2026-11-23 拍板「按 A+B 实现」，两项默认都用新行为）。
///
/// 分页模式「跨页句子」（偏好 `audiobook_page_split_follow`）：
/// * [kAudiobookPageSplitPageEdge]（方案 A，默认）：一句话被分到两页时，声音读到本页
///   最后一个字就翻到下一页——仍是整页，页码 / 恢复位置 / 翻页动效不受影响。
/// * [kAudiobookPageSplitNextSentence]：旧行为，翻页只看句首在哪一页，跨页句的后半截
///   要等下一句开始才看得见。
const String kAudiobookPageSplitPageEdge = 'page_edge';
const String kAudiobookPageSplitNextSentence = 'next_sentence';

/// 连续模式「跟随滚动」（偏好 `audiobook_scroll_follow`）：
/// * [kAudiobookScrollFollowLineAlign]（方案 B，默认，kadoki 的做法）：整句在屏内就不动；
///   否则把句首所在行（竖排 = 列）的行框起始边滚到正文起始边，屏幕起始侧不露半行。
/// * [kAudiobookScrollFollowMargin]：旧行为，句首离屏边 15% 就滚，落点是任意像素。
const String kAudiobookScrollFollowLineAlign = 'line_align';
const String kAudiobookScrollFollowMargin = 'margin';

/// 跨页句在音频时间轴上的「翻页时刻」（cue 时间域：相对音频文件、已扣音画延迟的毫秒）。
///
/// [charsBefore] = 句中排在当前页（含之前各页）的可数字符数，[totalChars] = 整句可数
/// 字符数，两者由分页 shell 的 `audioCuePageSplit` 按正文 DOM 量出（跳过注音与标点）。
/// 返回的是下一页第一个字开始发声的时刻：
/// * cue 带逐 token 发射时间（设备端转录产物，[AudioCue.tokenTiming]）时按字数比例落到
///   对应 token 的发射时刻——token 文本与正文的字形不一定逐字相同，所以只用比例对齐；
/// * 否则在 `[startMs, endMs]` 上按字数比例线性估时（误差在几百毫秒内，设计图已说明）。
///
/// 结果夹在 `[startMs, endMs]` 内；[totalChars] 非正（量不到字）时返回 `endMs`
/// ——等于不提前翻，退回下一句再翻的旧行为。
int audiobookCueSplitMs({
  required AudioCue cue,
  required int charsBefore,
  required int totalChars,
}) {
  final int start = cue.startMs;
  final int end = math.max(cue.endMs, start);
  if (totalChars <= 0) return end;
  final double fraction = (charsBefore / totalChars).clamp(0.0, 1.0);
  final CueTokenTiming? timing = cue.tokenTiming;
  if (timing != null && !timing.isEmpty) {
    int tokenChars = 0;
    for (final String token in timing.tokens) {
      tokenChars += _countedRunes(token);
    }
    if (tokenChars > 0) {
      final double target = fraction * tokenChars;
      int seen = 0;
      for (int i = 0; i < timing.length; i++) {
        if (seen >= target) {
          return (start + timing.offsetsMs[i]).clamp(start, end);
        }
        seen += _countedRunes(timing.tokens[i]);
      }
      return end;
    }
  }
  return (start + ((end - start) * fraction).round()).clamp(start, end);
}

int _countedRunes(String token) {
  int n = 0;
  for (final int rune in token.runes) {
    if (rune == 0x20 || rune == 0x3000 || rune == 0x09 || rune == 0x0A) {
      continue;
    }
    n++;
  }
  return n;
}

/// 播放器 tick 上挂的一枚一次性「句内时刻」观察：[cue] 正在播、且 cue 时钟走到 [atMs]
/// 时调一次 [onReached]。分页「读到页边就翻」用它在声音越过页边的那一刻翻页。
class CueEdgeWatch {
  const CueEdgeWatch({
    required this.cue,
    required this.atMs,
    required this.onReached,
  });

  final AudioCue cue;
  final int atMs;
  final void Function() onReached;
}

/// [watch] 这一 tick 是否到点。只在「正在播、文件对得上、当前句仍是被观察的那句、
/// 且这一 tick 的命中句不是别的句子」时成立——换句了由新句的 reveal 负责翻页，
/// 旧观察作废（不先翻一次再翻回）。句间静音里（[hitCue] 为 null）当前句仍是被观察的
/// 那句，到点照样触发：这句已读完，后半截正该露出来。
bool cueEdgeWatchDue({
  required CueEdgeWatch watch,
  required AudioCue? currentCue,
  required AudioCue? hitCue,
  required int audioFileIndex,
  required int effectiveMs,
  required bool playing,
  required bool Function(AudioCue a, AudioCue b) isSameCue,
}) {
  if (!playing) return false;
  if (watch.cue.audioFileIndex != audioFileIndex) return false;
  if (currentCue == null || !isSameCue(currentCue, watch.cue)) return false;
  if (hitCue != null && !isSameCue(hitCue, watch.cue)) return false;
  return effectiveMs >= watch.atMs;
}
