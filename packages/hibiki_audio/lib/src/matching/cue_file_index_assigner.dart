import '../audiobook/audiobook_model.dart';

/// TODO-811: 为「单时间轴字幕（SRT/LRC/VTT/ASS）+ 多个音频文件」的有声书推断每条
/// cue 的 [AudioCue.audioFileIndex] 并把时间码改写成相对该文件的局部时间。
///
/// 这些文本字幕格式只有一条连续时间轴（从 0 到全书结尾），解析器无法知道文件边界，
/// 默认把所有 cue 的 [AudioCue.audioFileIndex] 都设成 0。当一本书有多个音频文件
/// （文件夹模式、或用户手选多文件）时，这会让句子音频裁剪永远从第一个文件裁——落到
/// 第二个文件时间段的句子裁出错误音频（或越界）。SMIL/JSON 自带 fragment/文件映射
/// 不受影响（[JsonAlignmentParser]/[SmilParser] 已正确写 index）。
///
/// 给定按播放顺序的每个文件时长 [fileDurationsMs]（下标 = audioFileIndex），用累积
/// 边界把每条 cue（按其全局 [AudioCue.startMs]）归到所属文件，并把 start/end 减去该
/// 文件的起始累积偏移。落在最后一个文件末尾之后的 cue 归到最后一个文件（夹紧，不丢）。
///
/// 纯函数：原地修改传入的 cue 列表并返回它（与解析器返回同一引用，调用方零拷贝）。
/// 当只有 0 或 1 个文件（无歧义）或没有时长信息时原样返回，不动任何 cue。
List<AudioCue> reindexCuesByFileBoundaries({
  required List<AudioCue> cues,
  required List<int> fileDurationsMs,
}) {
  if (fileDurationsMs.length <= 1 || cues.isEmpty) {
    return cues;
  }

  // 累积起始边界：cumulativeStart[i] = 文件 0..i-1 的时长之和。
  final List<int> cumulativeStart = List<int>.filled(fileDurationsMs.length, 0);
  for (int i = 1; i < fileDurationsMs.length; i++) {
    cumulativeStart[i] = cumulativeStart[i - 1] + fileDurationsMs[i - 1];
  }

  for (final AudioCue cue in cues) {
    final int fileIndex = _fileIndexForGlobalMs(
      globalStartMs: cue.startMs,
      cumulativeStart: cumulativeStart,
      fileDurationsMs: fileDurationsMs,
    );
    final int base = cumulativeStart[fileIndex];
    cue.audioFileIndex = fileIndex;
    final int localStart = cue.startMs - base;
    final int localEnd = cue.endMs - base;
    // 夹紧到非负：边界毫秒抖动不应产生负的局部时间。
    cue.startMs = localStart < 0 ? 0 : localStart;
    cue.endMs = localEnd < cue.startMs ? cue.startMs : localEnd;
  }

  return cues;
}

/// 用累积边界把一个全局毫秒位置归到所属文件下标。落在最后一个文件之后归最后一个。
int _fileIndexForGlobalMs({
  required int globalStartMs,
  required List<int> cumulativeStart,
  required List<int> fileDurationsMs,
}) {
  for (int i = 0; i < fileDurationsMs.length; i++) {
    final int start = cumulativeStart[i];
    final int end = start + fileDurationsMs[i];
    if (globalStartMs < end) {
      return i < 0 ? 0 : i;
    }
  }
  return fileDurationsMs.length - 1;
}
