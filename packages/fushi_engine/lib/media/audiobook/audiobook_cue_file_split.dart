/// 「一份单时间轴字幕 + 多个音频文件」的 cue 归文件：所有导入 / 重新导入路径共用
/// 的唯一入口（BUG-4248）。
///
/// SRT / VTT / ASS / SSA / LRC 只有一条从全书开头算起的时间轴，解析器把每条 cue 都
/// 放在第 0 个文件上；播放器按 `audioFileIndex` + 文件内时间找句子，于是第 2 个文件
/// 起的句子全部对不上。按实测的每个文件时长把 cue 切回各自文件
/// （[reindexCuesByFileBoundaries]）。以前只有 app 的「给已有书导入有声书」对话框做
/// 这一步，服务端库根、发现页下载、转录入库、书 + 字幕 + 音频一起导入、独立字幕书
/// 都没做。
library;

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';

/// [subtitlePath] 的格式是不是单时间轴字幕（需要按文件时长切 cue 的那一类）。
/// SMIL / JSON 对齐自带文件映射，不算。
bool isSingleTimelineSubtitle(String subtitlePath) {
  final String ext = p.extension(subtitlePath);
  return ext.isNotEmpty && isAudiobookSubtitleExtension(ext);
}

/// 把刚从 [subtitlePath] 解析出来的全书时间轴 [cues] 按 [audioPaths]（播放顺序）
/// 的实测时长分到各文件，并把时间改成文件内时间。原地改、返回同一个列表。
///
/// 以下情况原样返回：不到 2 个音频文件、没有 cue、不是单时间轴字幕、cue 已经
/// 分过文件（有 `audioFileIndex != 0` 的）、或者有任何一个文件探不出时长（探测走
/// [AudiobookStorage.probeAudioDurationsMs]：app 装 just_audio，服务端装 ffprobe；
/// 没装配时全 0）。探不出时长时不猜，记一条诊断日志。
Future<List<AudioCue>> splitSingleTimelineCuesAcrossAudioFiles({
  required List<AudioCue> cues,
  required String subtitlePath,
  required List<String> audioPaths,
}) async {
  if (audioPaths.length <= 1 || cues.isEmpty) return cues;
  if (!isSingleTimelineSubtitle(subtitlePath)) return cues;
  if (cues.any((AudioCue c) => c.audioFileIndex != 0)) return cues;
  final List<int> durationsMs = await AudiobookStorage.probeAudioDurationsMs(
    audioPaths,
  );
  if (durationsMs.length != audioPaths.length ||
      durationsMs.any((int d) => d <= 0)) {
    engineLog.logDiagnostic(
      'AudiobookCueFileSplit',
      'cues left on file 0: duration probe incomplete for '
          '${audioPaths.length} files ($durationsMs)',
    );
    return cues;
  }
  return reindexCuesByFileBoundaries(cues: cues, fileDurationsMs: durationsMs);
}
