import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:path/path.dart' as p;

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

/// host 现取页的缓存根：`<系统临时目录>/fushi_interconnect_manga/<bookKey 摘要>/<章摘要>/`。
Directory onlineMangaPageCacheRoot() =>
    Directory(p.join(Directory.systemTemp.path, 'fushi_interconnect_manga'));

/// 现取页缓存最多保留的章目录数。够覆盖「当前章 + 预取下一章」与来回翻几章；
/// 一章页图通常几 MB 到几十 MB，上限因此是几百 MB 量级而不是随阅读量无限长。
const int kOnlineMangaPageCacheChapters = 16;

/// 按章有界清理 [root] 下的现取页缓存：只留最近写入的 [keepChapters] 个章目录
/// （新近度 = 章目录里最新一个文件的修改时间），[keep] 这一章无论如何不删；删空
/// 的书目录一并删掉。
///
/// Windows 系统临时目录不会被自动回收，不清的话每读一章就永久多留一章页图。
/// 删除失败（典型：该章某页正被 `serveFileWithRange` 打开读）只记日志、不中断取页：
/// 缓存淘汰是尽力而为，下次新开一章时会再试，不影响任何一页的正确性。
void pruneOnlineMangaPageCache(
  Directory root, {
  required Directory keep,
  int keepChapters = kOnlineMangaPageCacheChapters,
}) {
  if (!root.existsSync()) return;
  final List<(Directory, DateTime)> chapters = <(Directory, DateTime)>[];
  final List<Directory> books = <Directory>[];
  for (final FileSystemEntity book in root.listSync()) {
    if (book is! Directory) continue;
    books.add(book);
    for (final FileSystemEntity chapter in book.listSync()) {
      if (chapter is! Directory || p.equals(chapter.path, keep.path)) continue;
      DateTime newest = chapter.statSync().modified;
      for (final FileSystemEntity f in chapter.listSync()) {
        if (f is! File) continue;
        final DateTime modified = f.statSync().modified;
        if (modified.isAfter(newest)) newest = modified;
      }
      chapters.add((chapter, newest));
    }
  }
  // [keep] 本身占一个名额。
  final int others = keepChapters - 1;
  if (chapters.length <= others) return;
  chapters.sort(
    ((Directory, DateTime) a, (Directory, DateTime) b) => b.$2.compareTo(a.$2),
  );
  for (final (Directory dir, DateTime _) in chapters.skip(
    others < 0 ? 0 : others,
  )) {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (e, stack) {
      engineLog.log('pruneOnlineMangaPageCache', e, stack);
    }
  }
  for (final Directory book in books) {
    if (p.equals(book.path, keep.parent.path)) continue;
    try {
      if (book.listSync().isEmpty) book.deleteSync();
    } on FileSystemException catch (e, stack) {
      engineLog.log('pruneOnlineMangaPageCache', e, stack);
    }
  }
}
