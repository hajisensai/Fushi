import 'audiobook_model.dart';

/// 有声书播放进度的「全书毫秒」编码与 cue 的耦合（BUG-3197）。
///
/// `audiobook_pos_<key>` 存的是**全书毫秒**：多文件有声书 = 前面各文件时长之和 +
/// 当前文件内偏移（`AudiobookPlayerController.globalPosition`）。但这里的「文件时长」
/// 不是音频的真实时长，而是**从 cue 推出来的**（该文件内 cue 的最大 `endMs`，见
/// [audiobookFileDurationsFromCues]）——`preload: false` 下开书时拿不到真实时长，
/// 历史上就一直用 cue 推。
///
/// 于是同一个毫秒数的含义随 cue 变：换一份字幕，各文件「时长」跟着变，存着的
/// 全书毫秒按新 cue 一拆就落到别的文件 / 别的偏移，用户看到的是重新导入字幕后
/// 「听书进度被重置」。真实的时间位置（第几个文件、文件内第几毫秒）与字幕无关，
/// 所以 cue 整组替换时必须按**旧 cue**把全书毫秒拆回（文件下标, 文件内偏移），
/// 再按**新 cue**重新编码——这就是 [rebaseAudiobookGlobalPositionMs]。

/// 从全书 cue 推算每个音频文件的「时长」= 该文件内 cue 的最大 `endMs`。
///
/// 播放控制器拆分 / 合成全书毫秒用的就是这一份（唯一真相源），[cues] 不必有序。
/// 没有任何 cue 时返回空列表（全书毫秒退化为文件 0 的文件内毫秒）。
List<int> audiobookFileDurationsFromCues(Iterable<AudioCue> cues) {
  int maxIdx = -1;
  for (final AudioCue cue in cues) {
    if (cue.audioFileIndex > maxIdx) maxIdx = cue.audioFileIndex;
  }
  if (maxIdx < 0) return const <int>[];
  final List<int> durations = List<int>.filled(maxIdx + 1, 0);
  for (final AudioCue cue in cues) {
    final int idx = cue.audioFileIndex;
    if (idx < 0) continue;
    if (cue.endMs > durations[idx]) durations[idx] = cue.endMs;
  }
  return durations;
}

/// 把按 [oldDurationsMs] 编码的全书毫秒 [globalMs] 换算成按 [newDurationsMs]
/// 编码的全书毫秒，保持（文件下标, 文件内偏移）这一**真实时间位置**不变。
///
/// 拆分口径与 `AudiobookPlayerController.splitGlobalMs` 相同（逐文件减，最后一个
/// 文件吃掉余数），但**不钳制**最后一个文件内的偏移：cue 推出的时长通常短于真实
/// 音频（片尾没有 cue），钳了就会把片尾的位置拽回最后一句。合成口径与
/// `globalPosition` 相同（下标越过新时长表时，基数取到表尾为止）。
int rebaseAudiobookGlobalPositionMs(
  int globalMs,
  List<int> oldDurationsMs,
  List<int> newDurationsMs,
) {
  if (globalMs <= 0) return globalMs;
  int remaining = globalMs;
  int fileIndex = 0;
  for (; fileIndex < oldDurationsMs.length - 1; fileIndex++) {
    final int d = oldDurationsMs[fileIndex];
    if (remaining < d) break;
    remaining -= d;
  }
  int base = 0;
  for (int i = 0; i < fileIndex && i < newDurationsMs.length; i++) {
    base += newDurationsMs[i];
  }
  return base + remaining;
}
