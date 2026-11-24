import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, ProfileMediaKind;

/// 一本书（`book_key`）参与组合解析的媒体类型与内容语言：阅读器开书时进作品会话、书架上的
/// 「作品配置」看生效值都用这一份判据，两处对同一本书解析出同样的绑定层。
///
/// * 媒体类型：[manga] 为 true（漫画阅读器 / 漫画书架）时是漫画；否则有有声书行是有声书，有
///   SRT 书行是字幕书，其余是 EPUB。
/// * 内容语言：`audiobooks` 表没有 language 列——有声书的语言跟着它配对的 srt_books / epub_books
///   行走，所以两张都取、SRT 优先（有声书多数配 SRT）。拿不到就是 null（语言层整层跳过，绝不拿
///   全局默认内容语言来填）。
Future<({ProfileMediaKind mediaType, String? languageTag})>
resolveBookProfileContext(
  FushiDatabase db,
  String bookKey, {
  bool manga = false,
}) async {
  final srtRow = await db.getSrtBookByBookKey(bookKey);
  final epubRow = await db.getEpubBook(bookKey);
  final String? languageTag = srtRow?.language ?? epubRow?.language;
  if (manga) {
    return (mediaType: ProfileMediaKind.manga, languageTag: languageTag);
  }
  final ProfileMediaKind mediaType =
      await db.getAudiobookByBookKey(bookKey) != null
      ? ProfileMediaKind.audiobook
      : srtRow != null
      ? ProfileMediaKind.srtbook
      : ProfileMediaKind.epub;
  return (mediaType: mediaType, languageTag: languageTag);
}
