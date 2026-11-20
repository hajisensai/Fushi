/// 在线取页「字节 → 暂存 → 改名」的共用段（manga-27）。
///
/// 在线直读会话（`OnlineMangaReaderSession`，临时缓存）与章节下载服务
/// （`MangaDownloadService`，章目录）以前各写一套落盘：页名词干、单页上限、暂存后缀
/// 与扩展名表都已经分叉（下载没了 100 MiB 上限、暂存一个 `.tmp` 一个 `.part`、
/// 扩展名表两份）。这里收成一处；两边各自的落盘目录与「嗅不出格式时用什么扩展名」
/// 不变（下载侧落盘名与目录归属不动）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// 单页字节上限（直读与下载同一口径）。
const int kMangaPageMaximumBytes = 100 * 1024 * 1024;

/// 落盘前的暂存后缀：暂存文件写完整再改名，半截文件不会被当成有效页。
const String kMangaPageStagingSuffix = '.part';

/// 字节嗅探出的内容类型（[mangaImageContentType]）→ 页图扩展名。
const Map<String, String> kMangaPageExtensionByContentType = <String, String>{
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/webp': '.webp',
  'image/gif': '.gif',
  'image/avif': '.avif',
};

/// 第 [index] 页（0-based）的文件名词干：`page-000001` 起。
String mangaPageFileStem(int index) =>
    'page-${(index + 1).toString().padLeft(6, '0')}';

/// 第 [index] 页的文件名：词干 + 按字节嗅探的扩展名，嗅不出来用 [unknownExtension]。
String mangaPageFileName(
  int index,
  Uint8List bytes, {
  required String unknownExtension,
}) =>
    '${mangaPageFileStem(index)}'
    '${kMangaPageExtensionByContentType[mangaImageContentType(bytes)] ?? unknownExtension}';

/// [MangaPageBytesRejected] 的错误码：空页。
const String kMangaPageEmptyCode = 'PAGE_EMPTY';

/// [MangaPageBytesRejected] 的错误码：超过 [kMangaPageMaximumBytes]。
const String kMangaPageTooLargeCode = 'PAGE_TOO_LARGE';

/// 页字节不可用：空页（[kMangaPageEmptyCode]）或超过 [kMangaPageMaximumBytes]
/// （[kMangaPageTooLargeCode]）。
class MangaPageBytesRejected extends MihonRuntimeException {
  const MangaPageBytesRejected(super.code, super.message);
}

/// 落盘前的共用校验：空页 / 超上限抛 [MangaPageBytesRejected]。
void checkMangaPageBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const MangaPageBytesRejected(
      kMangaPageEmptyCode,
      'The online manga page is empty',
    );
  }
  if (bytes.length > kMangaPageMaximumBytes) {
    throw const MangaPageBytesRejected(
      kMangaPageTooLargeCode,
      'The online manga page is too large',
    );
  }
}

/// 把 [bytes] 写成 [target]：先写同目录暂存（[kMangaPageStagingSuffix]）并 flush，
/// 再改名。[beforeCommit] 在改名前调一次，抛错则删暂存并原样抛出（调用方借它在
/// 「写暂存期间会话已关」这类情况下放弃落盘）。
Future<File> writeMangaPageFile(
  File target,
  Uint8List bytes, {
  void Function()? beforeCommit,
}) async {
  final File staged = File('${target.path}$kMangaPageStagingSuffix');
  await staged.writeAsBytes(bytes, flush: true);
  if (beforeCommit != null) {
    try {
      beforeCommit();
    } on Object {
      try {
        if (await staged.exists()) await staged.delete();
      } on FileSystemException {
        // 句柄占用等：暂存后缀不会被当成有效页，留给目录清理。
      }
      rethrow;
    }
  }
  return staged.rename(target.path);
}
