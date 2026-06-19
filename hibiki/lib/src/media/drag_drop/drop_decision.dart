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
/// - books 表面：有书文件→新建书；否则命中书卡且有字幕/音频→附加到该卡；否则有 m3u8 播放
///   列表/视频文件→**自动切到视频导入**（带上拖入文件，不再只提示让用户手动切，TODO-558）；
///   否则有字幕/音频（必非命中卡）→提示需要目标卡；其余忽略。
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
      // 拖字幕/音频到具体书卡 → 附加到那本书（含拖 .mp4 给书加音频）。视频判定放在
      // 其后，避免把「拖 mp4 到书卡挂音频」误判成新建视频。
      if (cardHit && (files.subtitles.isNotEmpty || files.audios.isNotEmpty)) {
        return DropIntent.attachToBookCard;
      }
      // 拖视频/播放列表到书架空白处 → 自动切到视频导入流程（带上文件），消除「视频在
      // books 表面 unsupportedSurface 只提示」的特例（TODO-558 / BUG-326）。
      if (files.playlists.isNotEmpty) return DropIntent.importNewPlaylist;
      if (files.videos.isNotEmpty) return DropIntent.importNewVideo;
      // 到此：非命中卡的纯字幕/音频 → 音频/字幕必须挂到某本书，提示需要目标卡。
      if (files.subtitles.isNotEmpty || files.audios.isNotEmpty) {
        return DropIntent.needCardTarget;
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
