import 'package:hibiki/src/media/drag_drop/drop_classification.dart';

/// 拖拽落点所在的 tab 表面。
enum DropSurface { books, video }

/// 决策结果意图。widget 层据此打开对话框 / 提示 / 忽略。
enum DropIntent {
  importNewBook,
  importNewVideo,
  importNewPlaylist,
  attachToBookCard,
  attachToVideoCard,
  needCardTarget,
  unsupportedSurface,
  ignore,
}

/// 根据落点表面、文件分类、是否命中卡片，决定要做什么。纯函数。
///
/// 规则：
/// - books 表面：有书文件→新建书；否则有字幕/音频→命中卡则附加、否则提示需要目标卡；其余忽略
///   （m3u8 播放列表是视频专属，books 表面忽略）。
/// - video 表面：有 m3u8 播放列表→新建播放列表（比单视频更具体，优先）；否则有视频文件→
///   新建视频；否则有字幕→命中卡则附加、否则提示；其余忽略（视频卡不接受音频，故 video
///   表面下只看 subtitles）。
DropIntent decideDropIntent({
  required DropSurface surface,
  required DroppedFiles files,
  required bool cardHit,
}) {
  switch (surface) {
    case DropSurface.books:
      if (files.books.isNotEmpty) return DropIntent.importNewBook;
      if (files.subtitles.isNotEmpty || files.audios.isNotEmpty) {
        return cardHit
            ? DropIntent.attachToBookCard
            : DropIntent.needCardTarget;
      }
      if (files.hasAny) return DropIntent.unsupportedSurface;
      return DropIntent.ignore;
    case DropSurface.video:
      if (files.playlists.isNotEmpty) return DropIntent.importNewPlaylist;
      if (files.videos.isNotEmpty) return DropIntent.importNewVideo;
      if (files.subtitles.isNotEmpty) {
        return cardHit
            ? DropIntent.attachToVideoCard
            : DropIntent.needCardTarget;
      }
      if (files.hasAny) return DropIntent.unsupportedSurface;
      return DropIntent.ignore;
  }
}
