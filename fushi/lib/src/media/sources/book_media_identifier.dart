import 'package:fushi_engine/media/media_pref_keys.dart' as pref_keys;

/// 书架条目身份串（`MediaItem.mediaIdentifier`）的编码 / 解码，单独成叶子文件：
/// 纯字符串运算，不碰 AppModel / 阅读器源。`ReaderFushiSource` 的同名静态方法
/// 委托到这里；选书 / 编排这类纯逻辑（`book_continue.dart` 等）直接用它，不必为了
/// 拆一个前缀把整个阅读器源（连带 AppModel）拖进 import 环。

/// EPUB 书的身份前缀（`<prefix><bookKey>`）。
const String kBookMediaIdentifierPrefix = pref_keys.kReaderBookIdentifierPrefix;

/// 独立字幕书的身份前缀（`<prefix><SrtBook.uid>`，BUG-1018 A3）。
const String kSrtBookMediaIdentifierPrefix = 'fushi://srtbook/';

/// 本地漫画条目的 `MediaItem.mediaSourceIdentifier`（`MangaFushiSource.kUniqueKey`）。
const String kMangaMediaSourceKey = 'reader_manga';

/// [bookKey] 的身份串：原样拼接，不做百分号编码（BUG-658），与
/// [parseBookKeyOfMediaIdentifier] 互逆。
String bookMediaIdentifierFor(String bookKey) =>
    '$kBookMediaIdentifierPrefix$bookKey';

/// 身份串里的 bookKey；不是 EPUB 身份串（或 bookKey 为空）返回 null。
String? parseBookKeyOfMediaIdentifier(String identifier) {
  if (!identifier.startsWith(kBookMediaIdentifierPrefix)) return null;
  final String bookKey = identifier.substring(
    kBookMediaIdentifierPrefix.length,
  );
  return bookKey.isEmpty ? null : bookKey;
}

/// 独立字幕书 [uid] 的身份串，与 [parseSrtBookUidOfMediaIdentifier] 互逆。
String srtBookMediaIdentifierFor(String uid) =>
    '$kSrtBookMediaIdentifierPrefix$uid';

/// 身份串里的字幕书 uid；不是字幕书身份串返回 null。
String? parseSrtBookUidOfMediaIdentifier(String identifier) {
  if (!identifier.startsWith(kSrtBookMediaIdentifierPrefix)) return null;
  final String uid = identifier.substring(kSrtBookMediaIdentifierPrefix.length);
  return uid.isEmpty ? null : uid;
}
