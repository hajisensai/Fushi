import 'package:fushi_audio/fushi_audio.dart';

/// 远端直出容器里服务器抽不出的内嵌**文本**字幕轨（BUG-2590 的兼容层场景）：
/// libmpv 正在 demux 这条流，本就会把这条轨解码成文本。与其让它把字画进画面
/// （不可点、无列表），不如只借它的解码结果——`sub-text` + `sub-start` /
/// `sub-end`——拼成 cue 喂回可点 overlay。零额外流量；代价是 cue 只能边播边
/// 累积（没播到的句子服务器不给、我们也不再读一遍流）。
///
/// 这里是把 mpv 每次上报的一句合进累积列表的纯函数，控制器只负责喂数据。

/// mpv 秒值属性（`sub-start` / `sub-end` 形如 `"12.345000"`）→ 毫秒；
/// 无当前字幕时 mpv 报错或空串 → null。
int? parseMpvSecondsToMs(String raw) {
  final double? seconds = double.tryParse(raw.trim());
  if (seconds == null || seconds.isNaN || seconds.isInfinite) return null;
  if (seconds < 0) return null;
  return (seconds * 1000).round();
}

/// mpv 拿不到 `sub-end` 时（个别 demuxer 报的包没有时长）给的暂定时长；下一次
/// 字幕变化会按真实位置收尾（[closePlayerDecodedCue]）。
const int kPlayerDecodedCueProvisionalMs = 5000;

/// 用 mpv 上报的一句构造 cue。[text] 为空（句间空档）返回 null。
/// [startMs] 缺失时退回 [positionMs]（事件到达时的播放位置）。
AudioCue? buildPlayerDecodedCue({
  required String text,
  required int? startMs,
  required int? endMs,
  required int positionMs,
}) {
  final String normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return null;
  final int start = startMs ?? positionMs;
  final int end = (endMs != null && endMs > start)
      ? endMs
      : start + kPlayerDecodedCueProvisionalMs;
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = normalized
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = 0;
}

/// 把 [cue] 合进按 startMs 升序的 [cues]，返回新列表（不改入参）、这句落在第几位
/// [index]，以及是不是插入 [inserted]（false = 原地替换）。
///
/// - 同一起点的已有句（seek 回看重放 / mpv 对同一句重复上报）→ 替换，不重复；
/// - 否则按起点插入；
/// - 结果的 [AudioCue.sentenceIndex] 按列表位置重排（字幕列表 / 跳句按它编号）。
///
/// 调用方据此维护下标类播放态：替换不动任何下标，插入只把 ≥ [index] 的下标
/// 后移一位（[shiftCueIndexForInsert]）。整体作废会让「重播本句」的单句停与
/// 「字幕结束暂停」失效——播到目标句时 mpv 必然重新上报这一句。
({List<AudioCue> cues, int index, bool inserted}) mergePlayerDecodedCue(
  List<AudioCue> cues,
  AudioCue cue,
) {
  final List<AudioCue> next = List<AudioCue>.of(cues);
  final int same = next.indexWhere((AudioCue c) => c.startMs == cue.startMs);
  final int index;
  final bool inserted;
  if (same >= 0) {
    next[same] = cue;
    index = same;
    inserted = false;
  } else {
    int insertAt = next.length;
    for (int i = 0; i < next.length; i++) {
      if (next[i].startMs > cue.startMs) {
        insertAt = i;
        break;
      }
    }
    next.insert(insertAt, cue);
    index = insertAt;
    inserted = true;
  }
  for (int i = 0; i < next.length; i++) {
    next[i].sentenceIndex = i;
  }
  return (cues: next, index: index, inserted: inserted);
}

/// 在第 [insertedAt] 位插入一句后，原下标 [index] 的新位置（null 保持 null）。
int? shiftCueIndexForInsert(int? index, int insertedAt) {
  if (index == null || index < 0) return index;
  return index >= insertedAt ? index + 1 : index;
}

/// mpv 没给 `sub-end` 的那句（暂定时长）在字幕下一次变化时按真实位置 [atMs]
/// 收尾；[atMs] 不在该句区间内（seek 走了）则保持暂定值。返回是否改动。
bool closePlayerDecodedCue(AudioCue cue, int atMs) {
  if (atMs <= cue.startMs || atMs >= cue.endMs) return false;
  cue.endMs = atMs;
  return true;
}
