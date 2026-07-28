import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';

abstract interface class MangaPageProvider {
  Future<MangaReaderSession> open();
}

abstract interface class MangaReaderSession {
  int get pageCount;

  Future<MangaPageBytes> page(int index);

  Future<void> close();
}

class MangaPageBytes {
  const MangaPageBytes({
    required this.bytes,
    required this.contentType,
  });

  final Uint8List bytes;
  final String contentType;
}

/// Adapter used by the existing managed local-manga reader. It keeps local
/// filesystem access behind the same session boundary as online chapters while
/// preserving the local reader's progress, OCR, statistics and mining layers.
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
    final File file = File(p.normalize(p.absolute(
      p.join(imagesRoot.path, relativePaths[index]),
    )));
    if (!await file.exists()) {
      throw const MihonRuntimeException(
        'PAGE_MISSING',
        'Local manga page is missing',
      );
    }
    final Uint8List bytes = await file.readAsBytes();
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

class MihonMangaPageProvider implements MangaPageProvider {
  const MihonMangaPageProvider({
    required this.runtime,
    required this.context,
    required this.pages,
    required this.cacheRoot,
    this.maxCacheBytes = 256 * 1024 * 1024,
  });

  final MihonRuntime runtime;
  final MihonSourceContext context;
  final List<MihonPage> pages;
  final Directory cacheRoot;
  final int maxCacheBytes;

  @override
  Future<MangaReaderSession> open() async {
    final String id = '${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32)}';
    final Directory directory = Directory(p.join(cacheRoot.path, id));
    await directory.create(recursive: true);
    return MihonMangaReaderSession(
      runtime: runtime,
      context: context,
      pages: pages,
      directory: directory,
      maxCacheBytes: maxCacheBytes,
    );
  }
}

class MihonMangaReaderSession implements MangaReaderSession {
  MihonMangaReaderSession({
    required this.runtime,
    required this.context,
    required this.pages,
    required this.directory,
    required this.maxCacheBytes,
  });

  final MihonRuntime runtime;
  final MihonSourceContext context;
  final List<MihonPage> pages;
  final Directory directory;
  final int maxCacheBytes;

  final Map<int, Future<MangaPageBytes>> _pending =
      <int, Future<MangaPageBytes>>{};
  final Map<int, _MangaCacheEntry> _entries = <int, _MangaCacheEntry>{};
  final Set<String> _activeRequestIds = <String>{};
  bool _closed = false;
  int _cacheBytes = 0;
  int _requestSequence = 0;

  @override
  int get pageCount => pages.length;

  @override
  Future<MangaPageBytes> page(int index) {
    if (_closed) {
      throw const MihonRuntimeException(
        'SESSION_CLOSED',
        'The online manga reader session is closed',
      );
    }
    if (index < 0 || index >= pages.length) {
      throw RangeError.index(index, pages, 'index');
    }
    return _pending.putIfAbsent(index, () => _load(index));
  }

  Future<MangaPageBytes> _load(int index) async {
    try {
      final _MangaCacheEntry? cached = _entries[index];
      if (cached != null && await cached.file.exists()) {
        cached.lastAccess = DateTime.now();
        return MangaPageBytes(
          bytes: await cached.file.readAsBytes(),
          contentType: cached.contentType,
        );
      }
      final String requestId =
          '${directory.path.hashCode}-${_requestSequence++}-$index';
      _activeRequestIds.add(requestId);
      late final Uint8List bytes;
      try {
        final MihonRuntime currentRuntime = runtime;
        bytes = currentRuntime is CancellableMihonRuntime
            ? await (currentRuntime as CancellableMihonRuntime)
                .fetchImageRequest(
                context.extension,
                context.source,
                pages[index],
                requestId: requestId,
                preferences: context.preferences,
              )
            : await currentRuntime.fetchImage(
                context.extension,
                context.source,
                pages[index],
                preferences: context.preferences,
              );
      } finally {
        _activeRequestIds.remove(requestId);
      }
      if (_closed) {
        throw const MihonRuntimeException(
          'SESSION_CLOSED',
          'The online manga reader session was closed while loading',
        );
      }
      final String contentType = mangaImageContentType(bytes);
      final File part = File(p.join(directory.path, '$index.part'));
      final File file = File(p.join(directory.path, '$index.cache'));
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
      final _MangaCacheEntry entry = _MangaCacheEntry(
        file: file,
        size: bytes.length,
        contentType: contentType,
        lastAccess: DateTime.now(),
      );
      _entries[index] = entry;
      _cacheBytes += entry.size;
      await _trim(except: index);
      return MangaPageBytes(bytes: bytes, contentType: contentType);
    } finally {
      _pending.remove(index);
    }
  }

  Future<void> _trim({required int except}) async {
    while (_cacheBytes > maxCacheBytes && _entries.length > 1) {
      final MapEntry<int, _MangaCacheEntry> oldest = _entries.entries
          .where((MapEntry<int, _MangaCacheEntry> item) => item.key != except)
          .reduce(
            (
              MapEntry<int, _MangaCacheEntry> first,
              MapEntry<int, _MangaCacheEntry> second,
            ) =>
                first.value.lastAccess.isBefore(second.value.lastAccess)
                    ? first
                    : second,
          );
      _entries.remove(oldest.key);
      _cacheBytes -= oldest.value.size;
      if (await oldest.value.file.exists()) {
        await oldest.value.file.delete();
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final MihonRuntime currentRuntime = runtime;
    if (currentRuntime is CancellableMihonRuntime &&
        _activeRequestIds.isNotEmpty) {
      await (currentRuntime as CancellableMihonRuntime).cancelImageRequests(
        _activeRequestIds.toList(growable: false),
      );
    }
    _activeRequestIds.clear();
    _pending.clear();
    _entries.clear();
    _cacheBytes = 0;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class _MangaCacheEntry {
  _MangaCacheEntry({
    required this.file,
    required this.size,
    required this.contentType,
    required this.lastAccess,
  });

  final File file;
  final int size;
  final String contentType;
  DateTime lastAccess;
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
  if (bytes.length >= 6 && String.fromCharCodes(bytes.take(6)) == 'GIF89a') {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
    return 'image/webp';
  }
  return 'application/octet-stream';
}
