import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

abstract interface class MangaPageProvider {
  Future<MangaReaderSession> open();
}

/// 阅读器的页会话契约。
///
/// 2026-09-12 起在线漫画必须先下载再读（设计稿 §1），阅读器唯一的实现是
/// [LocalMangaReaderSession]：在线章下载完成后就是一份本地 `manga.json + images/`，
/// 与本地导入卷同形。旧的 Mihon / Aidoku / 互联在线会话（两级页缓存、请求限流、
/// Cloudflare 重试）整条删除。
abstract interface class MangaReaderSession {
  int get pageCount;

  Future<MangaPageBytes> page(int index);

  /// Return a local file containing this page.
  Future<File?> localFile(int index);

  /// Stable identity used by the OCR cache.
  String cacheIdentity(int index);

  Future<void> close();
}

class MangaPageBytes {
  const MangaPageBytes({
    required this.bytes,
    required this.contentType,
    this.width,
    this.height,
  });

  final Uint8List bytes;
  final String contentType;
  final int? width;
  final int? height;

  bool get hasDimensions =>
      width != null && height != null && width! > 0 && height! > 0;
}

/// Adapter used by the existing managed local-manga reader.
class LocalMangaPageProvider implements MangaPageProvider {
  const LocalMangaPageProvider({
    required this.imagesRoot,
    required this.relativePaths,
  });

  final Directory imagesRoot;
  final List<String> relativePaths;

  @override
  Future<MangaReaderSession> open() async => LocalMangaReaderSession(
        imagesRoot: imagesRoot,
        relativePaths: List<String>.unmodifiable(relativePaths),
      );
}

class LocalMangaReaderSession implements MangaReaderSession {
  LocalMangaReaderSession({
    required this.imagesRoot,
    required this.relativePaths,
  });

  final Directory imagesRoot;
  final List<String> relativePaths;
  bool _closed = false;

  @override
  int get pageCount => relativePaths.length;

  @override
  Future<MangaPageBytes> page(int index) async {
    final File file = await _validatedFile(index);
    final Uint8List bytes = await file.readAsBytes();
    final ({int width, int height})? dimensions =
        await mangaImageDimensions(bytes);
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
      width: dimensions?.width,
      height: dimensions?.height,
    );
  }

  @override
  Future<File?> localFile(int index) async => _validatedFile(index);

  Future<File> _validatedFile(int index) async {
    if (_closed) {
      throw const MihonRuntimeException(
        'SESSION_CLOSED',
        'The local manga reader session is closed',
      );
    }
    if (index < 0 || index >= relativePaths.length) {
      throw RangeError.index(index, relativePaths, 'index');
    }
    final String root = p.canonicalize(imagesRoot.path);
    final String candidate = p.canonicalize(
      p.join(imagesRoot.path, relativePaths[index]),
    );
    if (!p.isWithin(root, candidate)) {
      throw const MihonRuntimeException(
        'PATH_TRAVERSAL',
        'Local manga page escaped the managed image directory',
      );
    }
    final File file = File(
      p.normalize(p.absolute(p.join(imagesRoot.path, relativePaths[index]))),
    );
    if (!await file.exists()) {
      throw const MihonRuntimeException(
        'PAGE_MISSING',
        'Local manga page is missing',
      );
    }
    return file;
  }

  @override
  String cacheIdentity(int index) {
    if (index < 0 || index >= relativePaths.length) {
      throw RangeError.index(index, relativePaths, 'index');
    }
    return relativePaths[index];
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

Future<({int width, int height})?> mangaImageDimensions(
  Uint8List bytes,
) async {
  if (bytes.isEmpty) return null;
  return Isolate.run<({int width, int height})?>(() {
    try {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final img.Image oriented = img.bakeOrientation(decoded);
      return (width: oriented.width, height: oriented.height);
    } on Object {
      return null;
    }
  });
}

String mangaImageContentType(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      (String.fromCharCodes(bytes.take(6)) == 'GIF89a' ||
          String.fromCharCodes(bytes.take(6)) == 'GIF87a')) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
    return 'image/webp';
  }
  return 'application/octet-stream';
}
