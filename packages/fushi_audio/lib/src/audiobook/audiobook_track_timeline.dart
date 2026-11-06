import 'audiobook_model.dart';

/// 一条音轨在整本书时间轴上的位置（毫秒）。
typedef AudioTrackSpan = ({int startOffsetMs, int durationMs});

/// 把**整本书时间轴**上的字幕 cue 切回各音轨内的本地时间。
///
/// 一份覆盖全书的字幕（一个 SRT）里，时间是从第一条音轨开头算起的累计值；而播放
/// 器认的 cue 是「第 [AudioCue.audioFileIndex] 个文件内的 [AudioCue.startMs]」。多音轨
/// 的有声书（Audiobookshelf 上几乎都是）如果不切，所有 cue 都落在第 0 个文件里，
/// 偏移远超第 0 个文件的长度，第二个文件以后的句子永远对不上。
///
/// - cue 归属起点所在的音轨（`startOffsetMs <= startMs`，取最后一条满足的；多条轨起点
///   相同——前面的是零长度轨——就取后面真有内容的那条）。
/// - 横跨音轨边界的 cue 归起点那条轨，终点钳到该轨末尾：一句话不可能在两个文件里播。
/// - 起点落在最后一条轨末尾之后（字幕比音频长）的 cue 仍保留，钳在最后一条轨的末尾，
///   不丢句子（正文按 cue 生成，丢了会让文本和字幕对不上）。
/// - 只有一条轨（或 [tracks] 为空）时原样返回，不复制。
///
/// 返回的是**新对象**，不改动 [globalCues]。顺序与输入一致。
List<AudioCue> splitCuesAcrossTracks(
  List<AudioCue> globalCues,
  List<AudioTrackSpan> tracks,
) {
  if (tracks.length <= 1) return globalCues;
  return <AudioCue>[
    for (final AudioCue cue in globalCues) _placeCue(cue, tracks),
  ];
}

AudioCue _placeCue(AudioCue cue, List<AudioTrackSpan> tracks) {
  final int index = _trackIndexFor(cue.startMs, tracks);
  final AudioTrackSpan track = tracks[index];
  final int start = (cue.startMs - track.startOffsetMs).clamp(
    0,
    track.durationMs,
  );
  final int end = (cue.endMs - track.startOffsetMs).clamp(
    start,
    track.durationMs,
  );
  return AudioCue()
    ..id = cue.id
    ..bookKey = cue.bookKey
    ..chapterHref = cue.chapterHref
    ..sentenceIndex = cue.sentenceIndex
    ..textFragmentId = cue.textFragmentId
    ..text = cue.text
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = index
    ..markup = cue.markup
    ..tokenTiming = cue.tokenTiming;
}

/// 最后一条 `startOffsetMs <= timeMs` 的轨下标（二分）；比第一条轨还早则取 0。
int _trackIndexFor(int timeMs, List<AudioTrackSpan> tracks) {
  int low = 0;
  int high = tracks.length - 1;
  int found = 0;
  while (low <= high) {
    final int mid = (low + high) >> 1;
    if (tracks[mid].startOffsetMs <= timeMs) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return found;
}
