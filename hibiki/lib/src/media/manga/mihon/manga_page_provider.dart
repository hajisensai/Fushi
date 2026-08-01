import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';

const int kMihonPageMemoryCacheBytes = 96 * 1024 * 1024;
const int kMihonPageDiskCacheBytes = 1024 * 1024 * 1024;
const int kMihonPageDiskCacheFiles = 1024;
const int kMihonPagePrefetchConcurrency = 4;
const int _kMihonMaximumPageBytes = 100 * 1024 * 1024;

String mihonPageCacheIdentity(
  MihonSourceContext context,
  MihonPage page,
) {
  final String identity = <String>[
    context.extension.packageName,
    context.source.id,
    page.index.toString(),
    page.url,
    page.imageUrl ?? '',
  ].join('\u001f');
  return sha256.convert(utf8.encode(identity)).toString();
}

abstract interface class MangaPageProvider {
  Future<MangaReaderSession> open();
}

abstract interface class MangaReaderSession {
  int get pageCount;

  Future<MangaPageBytes> page(int index);

  /// Return a local file containing this page, fetching it first when needed.
  Future<File?> localFile(int index);

  /// Stable identity used by the page and OCR caches.
  String cacheIdentity(int index);

  /// Warm the two pages on each side of [index].
  Future<void> prefetchAround(int index);

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
  Future<void> prefetchAround(int index) async {}

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
    this.maxMemoryCacheBytes = kMihonPageMemoryCacheBytes,
    this.maxDiskCacheBytes = kMihonPageDiskCacheBytes,
    this.maxDiskCacheFiles = kMihonPageDiskCacheFiles,
    this.maxConcurrentRequests = kMihonPagePrefetchConcurrency,
  });

  final MihonRuntime runtime;
  final MihonSourceContext context;
  final List<MihonPage> pages;
  final Directory cacheRoot;
  final int maxMemoryCacheBytes;
  final int maxDiskCacheBytes;
  final int maxDiskCacheFiles;
  final int maxConcurrentRequests;

  @override
  Future<MangaReaderSession> open() async {
    await cacheRoot.create(recursive: true);
    return MihonMangaReaderSession(
      runtime: runtime,
      context: context,
      pages: pages,
      directory: cacheRoot,
      maxMemoryCacheBytes: maxMemoryCacheBytes,
      maxDiskCacheBytes: maxDiskCacheBytes,
      maxDiskCacheFiles: maxDiskCacheFiles,
      maxConcurrentRequests: maxConcurrentRequests,
    );
  }
}

/// Persistent two-level page cache matching Niratan's online reader contract:
/// 96 MiB memory LRU, 1 GiB / 1024-file disk LRU, request de-duplication and a
/// four-request prefetch ceiling.
class MihonMangaReaderSession implements MangaReaderSession {
  MihonMangaReaderSession({
    required this.runtime,
    required this.context,
    required this.pages,
    required this.directory,
    required this.maxMemoryCacheBytes,
    required this.maxDiskCacheBytes,
    required this.maxDiskCacheFiles,
    required int maxConcurrentRequests,
  }) : _requestLimiter = _AsyncPermitPool(maxConcurrentRequests);

  final MihonRuntime runtime;
  final MihonSourceContext context;
  final List<MihonPage> pages;
  final Directory directory;
  final int maxMemoryCacheBytes;
  final int maxDiskCacheBytes;
  final int maxDiskCacheFiles;
  final _AsyncPermitPool _requestLimiter;

  final Map<int, Future<MangaPageBytes>> _pending =
      <int, Future<MangaPageBytes>>{};
  final Map<int, _MangaMemoryEntry> _memory = <int, _MangaMemoryEntry>{};
  final Set<String> _activeRequestIds = <String>{};
  bool _closed = false;
  int _memoryBytes = 0;
  int _requestSequence = 0;

  @override
  int get pageCount => pages.length;

  @override
  Future<MangaPageBytes> page(int index) {
    _validateIndex(index);
    return _pending.putIfAbsent(index, () => _load(index));
  }

  @override
  Future<File?> localFile(int index) async {
    await page(index);
    final File file = _diskFile(index);
    return await file.exists() ? file : null;
  }

  @override
  String cacheIdentity(int index) {
    _validateIndex(index, requireOpen: false);
    return mihonPageCacheIdentity(context, pages[index]);
  }

  @override
  Future<void> prefetchAround(int index) async {
    _validateIndex(index);
    final List<int> indices = <int>[
      for (int candidate = index - 2; candidate <= index + 2; candidate++)
        if (candidate != index && candidate >= 0 && candidate < pages.length)
          candidate,
    ];
    await Future.wait<void>(
      indices.take(4).map(
        (int candidate) async {
          try {
            await page(candidate);
          } on Object {
            // Prefetch failures are retried by the foreground request.
          }
        },
      ),
    );
  }

  Future<MangaPageBytes> _load(int index) async {
    try {
      final _MangaMemoryEntry? memory = _memory[index];
      if (memory != null) {
        memory.lastAccess = DateTime.now();
        return memory.page;
      }

      final File disk = _diskFile(index);
      final Uint8List? diskBytes = await _readDiskCache(disk);
      if (diskBytes != null) {
        final MangaPageBytes page = await _describe(diskBytes);
        _remember(index, page);
        await disk.setLastModified(DateTime.now());
        return page;
      }

      final Uint8List bytes = await _requestLimiter.withPermit(
        () => _fetch(index),
      );
      if (_closed) {
        throw const MihonRuntimeException(
          'SESSION_CLOSED',
          'The online manga reader session was closed while loading',
        );
      }
      if (bytes.isEmpty || bytes.length > _kMihonMaximumPageBytes) {
        throw const MihonRuntimeException(
          'PAGE_TOO_LARGE',
          'The online manga page is empty or too large',
        );
      }
      final MangaPageBytes page = await _describe(bytes);
      await _writeDiskCache(disk, bytes);
      _remember(index, page);
      await _pruneDiskCache(protecting: disk);
      return page;
    } finally {
      _pending.remove(index);
    }
  }

  Future<Uint8List> _fetch(int index) async {
    if (_closed) {
      throw const MihonRuntimeException(
        'SESSION_CLOSED',
        'The online manga reader session is closed',
      );
    }
    final String requestId =
        '${directory.path.hashCode}-${_requestSequence++}-$index';
    _activeRequestIds.add(requestId);
    try {
      final MihonRuntime currentRuntime = runtime;
      return currentRuntime is CancellableMihonRuntime
          ? await (currentRuntime as CancellableMihonRuntime).fetchImageRequest(
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
  }

  Future<MangaPageBytes> _describe(Uint8List bytes) async {
    final ({int width, int height})? dimensions =
        await mangaImageDimensions(bytes);
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
      width: dimensions?.width,
      height: dimensions?.height,
    );
  }

  Future<Uint8List?> _readDiskCache(File file) async {
    if (!await file.exists()) return null;
    try {
      final int size = await file.length();
      if (size <= 0 || size > _kMihonMaximumPageBytes) {
        await file.delete();
        return null;
      }
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeDiskCache(File target, Uint8List bytes) async {
    final File temporary = File(
      '${target.path}.part-${DateTime.now().microsecondsSinceEpoch}-'
      '$_requestSequence',
    );
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      if (await target.exists()) {
        await temporary.delete();
      } else {
        await temporary.rename(target.path);
      }
    } on FileSystemException {
      if (await temporary.exists()) await temporary.delete();
      if (!await target.exists()) rethrow;
    }
  }

  void _remember(int index, MangaPageBytes page) {
    final _MangaMemoryEntry? previous = _memory.remove(index);
    if (previous != null) _memoryBytes -= previous.page.bytes.length;
    _memory[index] = _MangaMemoryEntry(
      page: page,
      lastAccess: DateTime.now(),
    );
    _memoryBytes += page.bytes.length;
    while (_memoryBytes > maxMemoryCacheBytes && _memory.length > 1) {
      final MapEntry<int, _MangaMemoryEntry> oldest = _memory.entries.reduce(
        (
          MapEntry<int, _MangaMemoryEntry> first,
          MapEntry<int, _MangaMemoryEntry> second,
        ) =>
            first.value.lastAccess.isBefore(second.value.lastAccess)
                ? first
                : second,
      );
      _memory.remove(oldest.key);
      _memoryBytes -= oldest.value.page.bytes.length;
    }
  }

  Future<void> _pruneDiskCache({required File protecting}) async {
    final List<FileSystemEntity> entities = await directory.list().toList();
    final List<({File file, int size, DateTime modified})> entries =
        <({File file, int size, DateTime modified})>[];
    for (final FileSystemEntity entity in entities) {
      if (entity is! File || p.extension(entity.path).startsWith('.part-')) {
        continue;
      }
      try {
        final FileStat stat = await entity.stat();
        if (stat.type == FileSystemEntityType.file) {
          entries.add((
            file: entity,
            size: stat.size,
            modified: stat.modified,
          ));
        }
      } on FileSystemException {
        continue;
      }
    }
    entries.sort(
      (
        ({File file, int size, DateTime modified}) a,
        ({File file, int size, DateTime modified}) b,
      ) {
        final int time = a.modified.compareTo(b.modified);
        return time != 0 ? time : a.file.path.compareTo(b.file.path);
      },
    );
    int total = entries.fold<int>(0, (int sum, var item) => sum + item.size);
    while (entries.length > maxDiskCacheFiles || total > maxDiskCacheBytes) {
      final int removal = entries.indexWhere(
        (var item) =>
            p.canonicalize(item.file.path) != p.canonicalize(protecting.path),
      );
      if (removal < 0) return;
      final ({File file, int size, DateTime modified}) entry =
          entries.removeAt(removal);
      try {
        await entry.file.delete();
        total -= entry.size;
      } on FileSystemException {
        continue;
      }
    }
  }

  File _diskFile(int index) => File(
        p.join(directory.path, cacheIdentity(index)),
      );

  void _validateIndex(int index, {bool requireOpen = true}) {
    if (requireOpen && _closed) {
      throw const MihonRuntimeException(
        'SESSION_CLOSED',
        'The online manga reader session is closed',
      );
    }
    if (index < 0 || index >= pages.length) {
      throw RangeError.index(index, pages, 'index');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _requestLimiter.close();
    final MihonRuntime currentRuntime = runtime;
    if (currentRuntime is CancellableMihonRuntime &&
        _activeRequestIds.isNotEmpty) {
      await (currentRuntime as CancellableMihonRuntime).cancelImageRequests(
        _activeRequestIds.toList(growable: false),
      );
    }
    _activeRequestIds.clear();
    _pending.clear();
    _memory.clear();
    _memoryBytes = 0;
  }
}

class _MangaMemoryEntry {
  _MangaMemoryEntry({
    required this.page,
    required this.lastAccess,
  });

  final MangaPageBytes page;
  DateTime lastAccess;
}

class _AsyncPermitPool {
  _AsyncPermitPool(int permits) : _available = permits < 1 ? 1 : permits;

  int _available;
  bool _closed = false;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<T> withPermit<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_closed) {
      return Future<void>.error(
        const MihonRuntimeException(
          'SESSION_CLOSED',
          'The online manga reader session is closed',
        ),
      );
    }
    if (_available > 0) {
      _available -= 1;
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_closed) return;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _available += 1;
    }
  }

  void close() {
    _closed = true;
    const MihonRuntimeException error = MihonRuntimeException(
      'SESSION_CLOSED',
      'The online manga reader session is closed',
    );
    for (final Completer<void> waiter in _waiters) {
      waiter.completeError(error);
    }
    _waiters.clear();
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
