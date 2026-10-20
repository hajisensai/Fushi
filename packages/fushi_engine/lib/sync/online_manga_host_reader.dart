import 'dart:typed_data';

/// host 端在线漫画的**按需取页**能力：本机书架上的在线条目（Mihon / 网页漫画）
/// 还没下载的章，由 host 用自己的在线运行时现取、转给对端。
///
/// 修复前互联只供「host 已下载完的章」（BUG-2474 的判据），在线条目一章没下就整条
/// 从对端消失——手机看不见电脑书架上的在线漫画，而 iPhone 本机按 App Store 合规
/// 没有在线源宿主，互联是它读这些漫画的唯一途径。
///
/// 运行时（Mihon 扩展、网页漫画抓取）只在 app 里，引擎够不着，所以这是个注入点：
/// app 构造 `LocalLibraryHostService` 时传实现；无头服务端不传 = 只供已下载章（与
/// 旧行为一致）。实现自行判本平台有没有对应运行时（iOS host 一律 [canServe] false）。
abstract interface class OnlineMangaHostReader {
  /// 该书架条目（`EpubBooks.sourceMetadata`）能否由本机运行时按需取页。必须廉价：
  /// `/api/library/books` 清单对每本漫画都会问一次，不得发网络请求。
  bool canServe(String sourceMetadata);

  /// [chapter]（`EpubBooks.chaptersJson` 里的一项，原样）的页数。
  Future<int> chapterPageCount({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
  });

  /// [chapter] 第 [index] 页（0 基）的图片字节。越界抛 [RangeError]。
  Future<Uint8List> chapterPage({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
    required int index,
  });
}

/// 按魔数定页图扩展名（host 把现取的页落成临时文件，`serveFileWithRange` 按扩展名
/// 给 Content-Type）；认不出的回落 `.bin`，对端解码只看字节。
String onlineMangaPageExtension(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return '.png';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return '.webp';
  }
  if (bytes.length >= 6 && String.fromCharCodes(bytes.sublist(0, 3)) == 'GIF') {
    return '.gif';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return '.jpg';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp' &&
      String.fromCharCodes(bytes.sublist(8, 12)).startsWith('avi')) {
    return '.avif';
  }
  return '.bin';
}
