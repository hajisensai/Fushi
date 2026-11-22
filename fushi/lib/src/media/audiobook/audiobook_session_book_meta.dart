/// 起 `AudiobookSession` 时 [SessionBookInfo] 要的书目元数据（标题、作者、封面、
/// 格式）的唯一来源。
///
/// 后台入口（`AudiobookSessionLauncher`）与漫画阅读器起播（经
/// `resolveMangaAudioSessionRequest`）都按 bookKey 走这里取，迷你播放条 / 媒体通知
/// 看到的封面与书名才不会因入口不同而分叉（BUG：阅读器起播漫画有声没传封面，迷你
/// 条只能画兜底图标）。
library;

import 'package:fushi/src/media/sources/book_cover_file_resolver.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_core/fushi_core.dart';

/// 一本书在会话里显示用的元数据。
typedef SessionBookMeta = ({
  String title,
  String? author,
  String? coverPath,
  BookFormat format,
});

/// 按 [bookKey] 读书行：标题走与书架同一 override 通道（BUG-1018），封面按书架同一
/// 解析（`coverPath` 相对 `extractDir`、大小写不敏感，兜底 cover.jpg/jpeg/png），
/// 只认真实存在的文件。书不在库里时标题回落 `Fushi`、无作者无封面、按 EPUB 处理。
Future<SessionBookMeta> loadSessionBookMeta(
  FushiDatabase db,
  String bookKey,
) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  final String? overrideTitle = ReaderFushiSource.instance
      .overrideTitleForBookKey(bookKey);
  if (row == null) {
    return (
      title: overrideTitle ?? 'Fushi',
      author: null,
      coverPath: null,
      format: BookFormat.epub,
    );
  }
  return (
    title: overrideTitle ?? row.title,
    author: row.author,
    coverPath: resolveBookCoverFilePath(
      extractDir: row.extractDir,
      coverPath: _stripLeadingSlash(row.coverPath),
    ),
    format: BookFormat.parseOrEpub(row.format),
  );
}

String? _stripLeadingSlash(String? path) =>
    path != null && path.startsWith('/') ? path.substring(1) : path;
