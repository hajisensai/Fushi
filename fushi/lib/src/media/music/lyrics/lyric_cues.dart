/// `LyricTimeline → List<AudioCue>` 适配（设计 §5.2）：让以 cue 为输入的既有链路（制卡音频
/// 片段、句子上下文、AB 循环）直接吃音乐歌词。音乐歌词本身不落有声书的 cue 表。
library;

import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_music/fushi_music.dart';

/// 歌词显示时间（含偏移）→ 音频文件时间：显示时间 = 音频时间 + offset，所以减回去；
/// CUE 虚拟曲目再加上它在整轨文件里的起点。
int lyricToAudioMs(
  int lyricMs, {
  required int offsetMs,
  int fileOffsetMs = 0,
  int lineOffsetMs = 0,
}) => lyricMs - offsetMs - lineOffsetMs + fileOffsetMs;

/// 主唱行一行一条 cue（和声行并入不单列）。[trackUid] 当 `bookKey`，`sentenceIndex` 是
/// 时间轴里的行下标（与 `KaraokeLyricsView` 的行号一致）。无时间的歌词返回空表。
List<AudioCue> lyricTimelineToAudioCues(
  LyricTimeline timeline, {
  required String trackUid,
  int fileOffsetMs = 0,
  Map<int, int> lineOffsetsMs = const <int, int>{},
}) {
  if (!timeline.isSynced) return <AudioCue>[];
  final List<AudioCue> out = <AudioCue>[];
  for (int i = 0; i < timeline.lines.length; i++) {
    final LyricLine l = timeline.lines[i];
    if (l.isBackground) continue;
    final String text = l.text.trim();
    if (text.isEmpty) continue;
    final int lineOffset = lineOffsetsMs[i] ?? 0;
    out.add(
      AudioCue()
        ..bookKey = trackUid
        ..chapterHref = ''
        ..sentenceIndex = i
        ..textFragmentId = ''
        ..text = text
        ..startMs = lyricToAudioMs(
          l.startMs,
          offsetMs: timeline.offsetMs,
          fileOffsetMs: fileOffsetMs,
          lineOffsetMs: lineOffset,
        )
        ..endMs = lyricToAudioMs(
          l.endMs,
          offsetMs: timeline.offsetMs,
          fileOffsetMs: fileOffsetMs,
          lineOffsetMs: lineOffset,
        )
        ..audioFileIndex = 0,
    );
  }
  return out;
}
