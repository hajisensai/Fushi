/// 视频字幕文本覆盖层（`video_subtitle_text_overrides`，反馈 gleDreKAvo /
/// dpAsMkUjKT）的两条键编码，只在这里写一次。
///
/// 播放器读写覆盖层（`fushi` app）与库里改名 / 移动文件后迁移覆盖层键
/// （[VideoBookRepository.applyMediaFileMoves]）必须用同一套编码，否则迁过去的
/// 键与播放时算出的键对不上，手改的字幕静默失效。
library;

import 'package:path/path.dart' as p;

/// 覆盖层的视频键：`bookUid`，播放列表第 2 集起 `bookUid#<集下标>`（与远端字幕偏好
/// 键 `(uid, episodeIndex)` 同口径）。
String subtitleTextOverrideVideoKey(String uid, int episodeIndex) =>
    episodeIndex <= 0 ? uid : '$uid#$episodeIndex';

/// 覆盖层的字幕源键：字幕源指针（`subtitleSource` 四态编码 / YouTube 轨键 / 在线轨键）
/// 的归一化。
///
/// - 外挂字幕文件（绝对路径）→ `file:<文件名>`：不存绝对路径，换数据根 / 迁移设备不
///   影响命中；ASR 每次产物文件名带时间戳，重新识别得到的是另一个源，旧改动不会误套
///   到新识别结果上。文件**改名**（整理文件名 / 下载改名）会改变这个键，所以改名方
///   必须同步迁移覆盖层行（[VideoBookRepository.applyMediaFileMoves]）。
/// - 其余（`embedded:<n>`、在线 / YouTube 轨键等）原样。
/// - null / 空（没有显式选择的默认字幕）→ 空串。
String subtitleTextOverrideSourceKey(String? source) {
  if (source == null) return '';
  final String trimmed = source.trim();
  if (trimmed.isEmpty) return '';
  if (p.windows.isAbsolute(trimmed) || p.posix.isAbsolute(trimmed)) {
    return 'file:${p.windows.basename(p.posix.basename(trimmed))}';
  }
  return trimmed;
}
