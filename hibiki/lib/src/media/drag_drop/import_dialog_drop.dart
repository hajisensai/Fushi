import 'package:hibiki/src/media/drag_drop/drop_classification.dart';

/// 拖入导入对话框时，按对话框类型把 [DroppedFiles] 解成「该写到哪些字段」的纯
/// 数据结果。无 IO / 无 context，是三个导入对话框 `_handleDialogDrop` 的可测核心。
///
/// 各对话框拿到结果后只做 `setState` 写字段——真正的副作用（sidecar 扫描、封面抽取、
/// 播放列表解析）仍由对话框实例方法处理，因为它们涉及 IO / 平台通道，不属纯函数。

/// 书籍导入对话框（[BookImportDialog]）的拖放字段更新意图。
///
/// 与现有字段一一对应：[epubPath]→`_epubPath`、[subtitlePath]→`_subtitlePath`、
/// [audioPaths]→`_audioPaths`。`null` / 空表示这次拖入未提供该类文件，对话框
/// 保留原值（仅覆盖拖入命中的字段，不清空用户已选）。
class BookDialogDropResult {
  const BookDialogDropResult({
    this.epubPath,
    this.subtitlePath,
    this.audioPaths = const <String>[],
  });

  final String? epubPath;
  final String? subtitlePath;
  final List<String> audioPaths;

  bool get isEmpty =>
      epubPath == null && subtitlePath == null && audioPaths.isEmpty;
}

/// 把拖入文件解成 [BookDialogDropResult]：第一个书文件→epub、第一个字幕→subtitle、
/// 全部音频→audios。.mp4 既是视频又是音频；书籍表面不接受视频，故只取它的音频语义。
BookDialogDropResult resolveBookDialogDrop(DroppedFiles files) {
  return BookDialogDropResult(
    epubPath: files.books.isNotEmpty ? files.books.first : null,
    subtitlePath: files.subtitles.isNotEmpty ? files.subtitles.first : null,
    audioPaths: List<String>.of(files.audios),
  );
}

/// 有声书导入对话框（[AudiobookImportDialog]）的拖放字段更新意图。
///
/// [audioPaths]→`_audioPaths`（同时清 `_audioDir`，两者互斥）、[alignmentPath]→
/// `_alignmentPath`。有声书只附加音频 + 对齐字幕到已有书，不接受 epub / 视频。
class AudiobookDialogDropResult {
  const AudiobookDialogDropResult({
    this.audioPaths = const <String>[],
    this.alignmentPath,
  });

  final List<String> audioPaths;
  final String? alignmentPath;

  bool get isEmpty => audioPaths.isEmpty && alignmentPath == null;
}

/// 把拖入文件解成 [AudiobookDialogDropResult]：全部音频→audios、第一个字幕→对齐。
AudiobookDialogDropResult resolveAudiobookDialogDrop(DroppedFiles files) {
  return AudiobookDialogDropResult(
    audioPaths: List<String>.of(files.audios),
    alignmentPath: files.subtitles.isNotEmpty ? files.subtitles.first : null,
  );
}

/// 视频导入对话框（[VideoImportDialog]）的拖放字段更新意图。
///
/// 播放列表（m3u8/m3u）语义独立——非空时走 `_importPlaylistFromPath`（一次性解析
/// 导入并关窗），优先于单视频；故 [playlistPath] 与 [videoPath] 互斥（playlist 命中
/// 时 videoPath 为 null）。[videoPath]→`_videoPath`、[subtitlePath]→`_subtitlePath`。
class VideoDialogDropResult {
  const VideoDialogDropResult({
    this.playlistPath,
    this.videoPath,
    this.subtitlePath,
  });

  final String? playlistPath;
  final String? videoPath;
  final String? subtitlePath;

  bool get isEmpty =>
      playlistPath == null && videoPath == null && subtitlePath == null;
}

/// 把拖入文件解成 [VideoDialogDropResult]：有播放列表→playlist（优先，与 video 互斥）；
/// 否则第一个视频→video；字幕始终取第一个（playlist 自带各集字幕，故 playlist 命中时
/// 不另填 subtitle）。
VideoDialogDropResult resolveVideoDialogDrop(DroppedFiles files) {
  if (files.playlists.isNotEmpty) {
    return VideoDialogDropResult(playlistPath: files.playlists.first);
  }
  return VideoDialogDropResult(
    videoPath: files.videos.isNotEmpty ? files.videos.first : null,
    subtitlePath: files.subtitles.isNotEmpty ? files.subtitles.first : null,
  );
}
