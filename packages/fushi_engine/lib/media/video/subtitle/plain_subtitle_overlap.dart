/// 纯文本字幕（SRT / WebVTT）的重叠时间收口（拍板台 0jnNr_P5Rd）。
///
/// 现象：Windows 端开双字幕放某份 srt，主字幕每换一句就在贴底格和上一格之间来回跳。
/// 根因是这份 srt 的前一句 end 晚于下一句 start（yt-dlp 导出的 YouTube 自动字幕、
/// 随手打的轴都常见），换句瞬间两句同时在屏。overlay 按 libass「Collisions: Normal」
/// 做槽位（`video_subtitle_overlay.dart` `_groupSlots`）：在屏的句子可见期内槽位不变，
/// 新句补空槽——重叠的句子于是一句贴底、一句在上，下一次重叠再反过来。
///
/// ASS 的重叠是作者用样式 / 定位精心排的，原样保留；纯文本字幕没有任何排版信息，
/// 同时在屏几乎总是打轴误差，所以在解析时把**部分重叠**的前一句收到下一句开始
/// （与 mpv `sub-fix-timing` 同一方向，只是不限 210ms 阈值：滚动式自动字幕每句都盖到
/// 下下句，重叠远超阈值）。刻意保留同屏的两种写法不动：
/// - 同一起点的多条 cue（多人同时开口的并列写法）；
/// - 被前一句**完整包住**的 cue（长时间挂着的注释 / 招牌 + 中间的对白）。
library;

import 'package:fushi_audio/fushi_audio_core.dart';

/// 就地把 [cues] 里「前一句尾巴盖住下一句开头」的前一句 `endMs` 收到下一句的
/// `startMs`，返回同一个列表（顺序不变）。
///
/// 「下一句」= 起点严格晚于本句起点的最早一组 cue；只有这组里有 cue 的终点晚于本句
/// 终点（部分重叠）才收口。本句完整包住下一句、或下一句与本句同起点时不动。
List<AudioCue> clampPlainTextCueOverlaps(List<AudioCue> cues) {
  if (cues.length < 2) return cues;
  final List<AudioCue> sorted = List<AudioCue>.of(cues)
    ..sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  // 每个下标所在「同起点组」之后那一组的起点与组内最大终点（从尾往前一趟算出）。
  final int n = sorted.length;
  final List<int> nextGroupStart = List<int>.filled(n, -1);
  final List<int> nextGroupMaxEnd = List<int>.filled(n, -1);
  int followingStart = -1;
  int followingMaxEnd = -1;
  int i = n - 1;
  while (i >= 0) {
    final int start = sorted[i].startMs;
    int groupMaxEnd = sorted[i].endMs;
    int j = i;
    while (j - 1 >= 0 && sorted[j - 1].startMs == start) {
      j--;
      if (sorted[j].endMs > groupMaxEnd) groupMaxEnd = sorted[j].endMs;
    }
    for (int k = j; k <= i; k++) {
      nextGroupStart[k] = followingStart;
      nextGroupMaxEnd[k] = followingMaxEnd;
    }
    followingStart = start;
    followingMaxEnd = groupMaxEnd;
    i = j - 1;
  }
  for (int k = 0; k < n; k++) {
    final AudioCue cue = sorted[k];
    final int nextStart = nextGroupStart[k];
    if (nextStart < 0) continue;
    if (nextStart < cue.endMs && nextGroupMaxEnd[k] > cue.endMs) {
      cue.endMs = nextStart;
    }
  }
  return cues;
}
