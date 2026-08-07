import 'package:fushi/src/media/drag_drop/drop_classification.dart';

/// 拖拽落点所在的 tab 表面。
///
/// [manga] = 漫画库（`ReaderHibikiHistoryPage(mangaOnly: true)` 的壳）。它与
/// [books] 共用同一个页面和同一份 drop target；差别**只在漫画载体优先**，其余
/// 一切（epub / 视频 / 字幕 / URL）行为与 [books] 完全一致（见 decideDropIntent
/// 里的委托）——那是改动前就有的行为，不在此处收窄。
enum DropSurface { books, video, manga }

/// 决策结果意图。widget 层据此打开对话框 / 提示 / 忽略。
enum DropIntent {
  importNewBook,

  /// 拖入 `.mokuro` / `.cbz` / 页图目录 → 导入一本漫画（`EpubBooks` 里
  /// `format='manga'` 的行，第三种「书」）。books 与 manga 两个表面都产出它：
  /// 漫画是书的一种，普通书架拖漫画包也该能导，不该静默。
  importNewManga,

  /// 拖入 cbr/cb7/rar → 认得出是漫画包，但 `archive` 包不解 RAR，导不了。
  /// 单列一个意图只为给明确提示，不再静默无反应。
  unsupportedMangaArchive,

  importNewVideo,
  importNewPlaylist,

  /// 拖入的可导入网络流 URL → 走视频「流媒体导入」（[_importStreamUrl]，入库进视频
  /// 书架）。books/video 两表面都自动切到视频导入，与拖视频文件的自动切换一致（TODO-1306）。
  importVideoUrl,
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
      // 漫画载体优先于普通书文件：`.mokuro` 是 JSON、若先被 books 分支吃掉会被
      // 当纯文本转成 EPUB（导入对话框内部也是漫画分支早退于 TextToEpub，同一道
      // 理）。漫画是书的一种，普通书架拖漫画包照样导，不静默。
      if (files.mangas.isNotEmpty) return DropIntent.importNewManga;
      if (files.unsupportedMangas.isNotEmpty) {
        return DropIntent.unsupportedMangaArchive;
      }
      if (files.books.isNotEmpty) return DropIntent.importNewBook;
      // 拖字幕/音频到具体书卡 → 附加到那本书（含拖 .mp4 给书加音频）。视频判定放在
      // 其后，避免把「拖 mp4 到书卡挂音频」误判成新建视频。
      if (cardHit && (files.subtitles.isNotEmpty || files.audios.isNotEmpty)) {
        return DropIntent.attachToBookCard;
      }
      // 拖视频/播放列表/URL 到书架空白处 → 自动切到视频导入流程（带上文件/URL），消除
      // 「视频在 books 表面 unsupportedSurface 只提示」的特例（TODO-558 / BUG-326 / TODO-1306）。
      if (files.urls.isNotEmpty) return DropIntent.importVideoUrl;
      if (files.playlists.isNotEmpty) return DropIntent.importNewPlaylist;
      if (files.videos.isNotEmpty) return DropIntent.importNewVideo;
      // 到此：非命中卡的纯字幕/音频 → 音频/字幕必须挂到某本书，提示需要目标卡。
      if (files.subtitles.isNotEmpty || files.audios.isNotEmpty) {
        return DropIntent.needCardTarget;
      }
      if (files.hasAny) return DropIntent.unsupportedSurface;
      return DropIntent.ignore;
    case DropSurface.manga:
      // 漫画库：漫画载体是主业，优先判。
      if (files.mangas.isNotEmpty) return DropIntent.importNewManga;
      if (files.unsupportedMangas.isNotEmpty) {
        return DropIntent.unsupportedMangaArchive;
      }
      // 其余（epub / 视频 / 字幕 / 音频 / URL）**原样沿用 books 表面的既有行为**。
      //
      // 这里曾改成一律回「本页面不支持」，理由是「把 epub 悄悄导进另一个书架，
      // 用户会以为文件丢了」。但漫画库本就是书架页的 `mangaOnly` 壳、共用同一个
      // drop target，改之前拖 epub 进来是**会自动导进普通书架的**——那是一项用户
      // 可能一直在用的既有能力，移除它属于 break userspace。要不要改成「不支持」
      // 是产品决定，在用户拍板前默认保持现状。
      //
      // 委托而不是抄一遍：books 分支后续任何演进（自动切视频导入、URL 流媒体、
      // 拖字幕挂到书卡……）漫画库自动跟上，不会漂成两套。
      return decideDropIntent(
        surface: DropSurface.books,
        files: files,
        cardHit: cardHit,
      );
    case DropSurface.video:
      if (files.urls.isNotEmpty) return DropIntent.importVideoUrl;
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
